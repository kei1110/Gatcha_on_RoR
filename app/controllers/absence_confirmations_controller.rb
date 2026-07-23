# frozen_string_literal: true

# 欠勤確定（SPEC §6.10・設計 §5 / §11⑥ / §12③⑧）。管理者が欠勤候補を確認し、確定 or 却下する。
# 認可は二層: ① role ゲート（authorize）② 対象ゲート（policy_scope.find → 404）。
# 対象社員を policy_scope(User) 経由で解決することが、**同一テナントの他部下**を塞ぐ唯一の壁（§12③）。
class AbsenceConfirmationsController < ApplicationController
  def index
    authorize :absence_confirmation, :index?
    load_candidates
    load_confirmed_absences
  end

  # 1 社員 × N 日付の一括確定（§6.10 step 3-5）。日付の権威は候補テーブル（params ではない）
  def create
    authorize :absence_confirmation, :create?
    target = roster.find(params[:user_id])
    dates = parse_dates(params[:dates])
    result = Absences::Confirm.call(
      target_user: target, dates:,
      candidates: policy_scope(AbsenceCandidate).where(user_id: target.id, target_date: dates),
      absence_reason: params[:absence_reason], note: params[:note], actor: current_user
    )
    notify_confirmed(target, result.confirmed_dates) if result.confirmed_dates.any?
    redirect_to absence_confirmations_path, status: :see_other, notice: confirm_notice(result)
  rescue Date::Error, TypeError
    render_ineligible("日付の指定が正しくありません")
  rescue Absences::IneligibleError, Absences::ClosingLockedError => e
    render_ineligible(e.message)
  rescue ActiveRecord::RecordInvalid
    # Absences::Confirm が握り潰さず伝播させた本物の検証失敗。500 でなく 422 で再描画する
    render_ineligible("欠勤確定に失敗しました（記録の整合性エラー）。管理者へご連絡ください")
  end

  # 却下(dismiss)＝候補を削除し absence_dismissed 監査行を残す（§11④・§12⑧・4-2c-3b D2）。
  # 候補は再生成されないため監査を残さないと痕跡ゼロの完全消去が可能になる。
  # 不利益処分でないため猶予期限の制約は掛けない
  def destroy
    authorize AbsenceCandidate, :destroy?             # ① role ゲート（一般社員は 403）
    candidate = policy_scope(AbsenceCandidate).find(params[:id]) # ② 対象ゲート（scope 外は 404）
    Absences::Dismiss.call(candidate:, actor: current_user)
    redirect_to absence_confirmations_path, status: :see_other, notice: "欠勤候補を却下しました"
  end

  private

  def load_candidates
    @candidates = policy_scope(AbsenceCandidate).includes(:user).order(:user_id, :target_date)
    @grace = Absences::GracePeriod.new(organization: current_user.organization)
  end

  # policy_scope(User) は top-level UserPolicy 不在で NotDefinedError ゆえ scope class 明示（RAILS_GOTCHAS）
  def roster = policy_scope(User, policy_scope_class: AbsenceConfirmationPolicy::Scope)

  # 確定済み欠勤の一覧（roster × absent × 直近 92 日 ≒ 3 締め期間）。締め状態は 1 クエリ先読みし
  # メモリで突き合わせる（N+1 を作らない・設計 §4.7）。取消は AbsenceCancellationPolicy が認可する
  def load_confirmed_absences
    return unless AbsenceCancellationPolicy.new(current_user, :absence_cancellation).create?

    window = (current_user.organization.today - 92)..current_user.organization.today
    @confirmed_absences = AttendanceRecord.absent
                                          .where(user_id: cancellation_roster.select(:id), work_date: window)
                                          .includes(:user).order(:user_id, work_date: :desc).to_a
    @locked_summary_keys = locked_summary_keys(@confirmed_absences)
  end

  def cancellation_roster = policy_scope(User, policy_scope_class: AbsenceCancellationPolicy::Scope)

  # (user_id, year_month) の締めロック集合を 1 クエリで作る。view は absence_closed? で判定する
  def locked_summary_keys(records)
    return Set.new if records.empty?

    MonthlyAttendanceSummary
      .where(user_id: records.map(&:user_id).uniq, status: MonthlySummaries::ClosingLock::LOCKED)
      .pluck(:user_id, :year_month).to_set
  end

  # その確定済み欠勤が締め済み期間に属するか（純計算・DB を叩かない）
  helper_method :absence_closed?
  def absence_closed?(record)
    label = AttendancePeriod.containing(organization: record.user.organization, date: record.work_date).label
    @locked_summary_keys.include?([ record.user_id, label ])
  end

  # 厳格 ISO8601。Date.parse は "2026-13-99" 等のゴミを黙認し得る（RAILS_GOTCHAS）
  def parse_dates(raw) = Array(raw).map { |value| Date.iso8601(value.to_s) }

  def render_ineligible(message)
    load_candidates
    flash.now[:alert] = message
    render :index, status: :unprocessable_entity
  end

  def confirm_notice(result)
    notice = "#{result.confirmed_dates.size} 日を欠勤確定しました"
    return notice if result.skipped_dates.empty?

    # guard_not_covered! が「既に勤怠記録がある日」を write 前に 422 で弾くため、ここへ落ちるのは
    # ガード通過後〜create! までの真の並行競合のみ（4-2c-2 labor-law レビュー W-e）
    "#{notice}（#{result.skipped_dates.join(', ')} は他の操作と競合したため確定できませんでした。再実行してください）"
  end

  # 確定 tx の commit 後に発火（§9③ 幻通知の防止）。1 社員 × N 日付を 1 件に集約（§6.10 step 5）。
  # priority は action_required — 賃金控除に直結する不利益処分の告知で、本人に「事後の有給申請」
  # という action がある（SPEC §9.1 の「月次差戻し」と同格）。
  # 4-2c-1（PR #32）で absent→on_leave の事後有給パスが live 化したため有給申請を案内できる（§11③）。
  # 打刻変更申請は CCR new_entry が拒否のまま（#48）ゆえ約束しない。
  def notify_confirmed(target, dates)
    Notifier.call(
      target_user: target, subject_user: target,
      priority: :action_required, source_type: :absence_confirmed,
      title: "欠勤が確定されました",
      body: "#{dates.join(', ')}（計 #{dates.size} 日）の欠勤が確定されました。" \
            "事後に有給休暇の申請ができます。ご不明な点は管理者へお問い合わせください。"
    )
  rescue StandardError => e
    # 通知は確定（commit 済）の副次効果。失敗しても主操作の応答を覆さない（§9.5・4-1c producer 同型）
    Rails.logger.error(
      "[Notifier] producer 通知失敗 source_type=absence_confirmed user=#{target.id}: #{e.class}: #{e.message}"
    )
  end
end
