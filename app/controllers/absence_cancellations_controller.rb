# frozen_string_literal: true

# 欠勤確定の取消（SPEC §6.10・設計 4-2c-3b §4.6）。誤確定した absent AR を取り消す唯一の出口。
# 認可は二層: ① role ゲート（authorize）② 対象ゲート（roster.find → 404）。
# 対象社員を policy_scope(User) 経由で解決することが同一テナントの他部下を塞ぐ壁（IDOR）。
class AbsenceCancellationsController < ApplicationController
  def create
    authorize :absence_cancellation, :create?
    # roster.find は create の method-level rescue の**外**に置く必要がある — 同じ create 内で
    # rescue ActiveRecord::RecordNotFound を持つと、由来を問わず全ての RecordNotFound（roster 外の
    # IDOR も含む）をここで握ってしまい ApplicationController#render_not_found（404）に届かなくなる。
    # cancel を別メソッドへ切り出し、rescue の対象を「AR 消失の競合」だけに絞る
    target = roster.find(params[:user_id])
    cancel(target)
  rescue Date::Error, TypeError
    render_failure("日付の指定が正しくありません")
  end

  private

  def cancel(target)
    record = target_absent_record(target)
    Absences::Cancel.call(target_user: target, record:, note: params[:note], actor: current_user)
    notify_canceled(target, record.work_date)
    redirect_to absence_confirmations_path, status: :see_other, notice: "#{record.work_date} の欠勤確定を取り消しました"
  rescue ActiveRecord::RecordNotFound
    # target_absent_record が投げる（対象日に absent AR が無い）か、Absences::Cancel の with_lock
    # 内 reload が投げる（fetch 後に別操作が先に destroy した競合）。区別せず see_other + alert で戻す
    render_failure("対象の欠勤は既に取り消されているか、存在しません")
  rescue Absences::IneligibleError, Absences::ClosingLockedError => e
    render_failure(e.message)
  end

  # roster.find は params[:user_id] が scope 外なら RecordNotFound（404）。確定済み AR は
  # target スコープで引く（work_date 一意・absent 限定）。無ければ RecordNotFound → see_other + alert
  def target_absent_record(target)
    AttendanceRecord.absent.find_by!(user_id: target.id, work_date: Date.iso8601(params[:work_date].to_s))
  end

  # policy_scope(User) は top-level UserPolicy 不在で NotDefinedError ゆえ scope class 明示（RAILS_GOTCHAS）
  def roster = policy_scope(User, policy_scope_class: AbsenceCancellationPolicy::Scope)

  # 確定画面（index）は本 controller に無いため、失敗は redirect + alert で確定画面へ戻す
  # （Task 7 で確定画面に取消 UI が載っても redirect+alert の一貫性は保たれる）
  def render_failure(message)
    redirect_to absence_confirmations_path, status: :see_other, alert: message
  end

  # 取消の commit 後に発火（§4.5）。取消は本人へ informational（有利な情報・二重 opt-in 時のみ email）。
  # 「欠勤が確定されました」（action_required）を残したまま黙って AR を消すと本人は取消を知れない。
  def notify_canceled(target, date)
    Notifier.call(
      target_user: target, subject_user: target,
      priority: :informational, source_type: :absence_canceled,
      title: "欠勤確定が取り消されました",
      body: "#{date} の欠勤確定が取り消されました。賃金控除の対象からも除外されます。ご不明な点は管理者へお問い合わせください。"
    )
  rescue StandardError => e
    # 通知は取消（commit 済）の副次効果。失敗しても主操作の応答を覆さない（§9.5・producer 同型）
    Rails.logger.error(
      "[Notifier] producer 通知失敗 source_type=absence_canceled user=#{target.id}: #{e.class}: #{e.message}"
    )
  end
end
