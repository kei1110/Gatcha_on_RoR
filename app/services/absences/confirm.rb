# frozen_string_literal: true

module Absences
  # 欠勤確定の副作用本体（SPEC §6.10 step 4-5・設計 §5.2 / §11⑥⑦ / §12①③④⑤）。
  #
  # 権威源は AbsenceCandidate — params 日付を権威にしない（§11②）。呼び出し元 controller が
  # policy_scope で target_user と candidates を解決して渡す（IDOR は解決側で塞ぐ・§12③）。
  #
  # ガード順は意味論上固定:
  #   ① 毒入力 reason → ② 候補不在日 → ③ target_user 不一致 → ④ notified_on nil
  #     → ⑤ 猶予前 → ⑥ 締め済み
  #   ① を先頭に置くのは、per-day の rescue RecordInvalid（並行打刻の競合吸収）が毒入力を
  #     「skip 日」として握り潰し 422 を返さなくなるのを防ぐため（部分成功にしない）。
  #   ④ を ⑤ より前に置くのは next_business_day(nil) を計算させないため（§12①）。
  class Confirm
    Result = Struct.new(:confirmed_dates, :skipped_dates, keyword_init: true)

    # 猶予期限の時刻（組織 TZ）。SPEC §6.8「猶予: 翌営業日 17:00」
    GRACE_DEADLINE_HOUR = 17

    def self.call(**) = new(**).call

    def initialize(target_user:, dates:, candidates:, absence_reason:, note:, actor:)
      @target_user = target_user
      @dates = Array(dates).uniq.sort
      @candidates = candidates.to_a.sort_by(&:target_date)
      @absence_reason = absence_reason.to_s
      @note = note
      @actor = actor
    end

    def call
      guard_reason!
      guard_candidates_exist!
      guard_candidates_belong_to_target!
      guard_notified!
      guard_grace_period!
      guard_closing!
      confirm_all
    end

    private

    def organization = @target_user.organization

    # ① 毒入力（permit する enum ゆえ不正値は 422 に落とす・§11⑩ 同型）
    def guard_reason!
      return if AttendanceRecord.absence_reasons.key?(@absence_reason)

      raise IneligibleError, "欠勤理由が不正です"
    end

    # ② 候補の無い日付（却下/撤回された休暇日・過去日の捏造）は確定不可。
    #    v1 では「候補に無い日の欠勤確定」を一切認めない（§11②・§12⑨ の plan 判断）
    def guard_candidates_exist!
      raise IneligibleError, "欠勤候補が選択されていません" if @dates.empty?
      return if @candidates.map(&:target_date).sort == @dates

      raise IneligibleError, "欠勤候補に存在しない日付が含まれています"
    end

    # ③ 呼び出し元の契約違反（target_user と candidates の食い違い）を write 前に拒否する。
    #    現行 controller は policy_scope(AbsenceCandidate).where(user_id: target.id) で紐付けるため
    #    到達しないが、食い違えば「他人の候補を destroy して target_user に absent AR を作る」腐敗になる。
    #    サービス単体でも fail-closed に倒す（多層防御）
    def guard_candidates_belong_to_target!
      return if @candidates.all? { |candidate| candidate.user_id == @target_user.id }

      raise IneligibleError, "欠勤候補が対象社員のものではありません"
    end

    # ④ notified_on nil = 本人へ事前通知が届いていない → 弁明機会ゼロ（労基法 24 条・§12①）。
    #    4-2b は本人宛 Notifier 成功後にのみ notified_on を立てるため presence を弁明機会の proxy にできる
    def guard_notified!
      return if @candidates.all? { |candidate| candidate.notified_on.present? }

      raise IneligibleError, "本人へ未通知の欠勤候補は確定できません（次回の日次バッチで通知されます）"
    end

    # ⑤ 猶予 = notified_on の翌営業日 17:00（組織 TZ）。経過前は確定不可（§10⑤ 適正手続き）
    def guard_grace_period!
      now = Time.current
      @candidates.each do |candidate|
        deadline = grace_deadline(candidate.notified_on)
        raise IneligibleError, "猶予期限を算出できません（稼働日が見つかりません）" if deadline.nil?
        next if now > deadline

        raise IneligibleError,
              "猶予期限（#{deadline.strftime('%Y-%m-%d %H:%M')}）を過ぎるまで #{candidate.target_date} は確定できません"
      end
    end

    def grace_deadline(notified_on)
      next_day = resolver.next_business_day(notified_on)
      return nil if next_day.nil?

      ActiveSupport::TimeZone[organization.time_zone]
        .local(next_day.year, next_day.month, next_day.day, GRACE_DEADLINE_HOUR)
    end

    # ⑥ 締め済み月の日付は確定不可（§11⑦）。既存 ClosingLock の LOCKED は submitted を含む＝
    #    設計 §5.2 の「finalized 禁止・deferred 許可」より厳格（§12⑩・本計画で意図的に採用）。
    #    write 前に対象全日を一括評価し、1 日でも locked なら全件拒否
    def guard_closing!
      return unless MonthlySummaries::ClosingLock.locked?(user: @target_user, dates: @dates)

      raise ClosingLockedError, "締め済みの月（提出済 / 確定）の日付は欠勤確定できません"
    end

    def confirm_all
      confirmed = []
      skipped = []
      # request 文脈前提だが ApplyApproval 同型で明示ラップ（文脈喪失・将来バッチ化に fail-closed）
      ActsAsTenant.with_tenant(organization) do
        ActiveRecord::Base.transaction do
          @candidates.each do |candidate|
            confirm_one(candidate)
            confirmed << candidate.target_date
          rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
            # 並行 clock_in / CCR 承認が同日 AR を先に作った等。savepoint のみ rollback され
            # 親 tx は健全・候補は intact（再確定可能）。1 日の競合が確定バッチ全体を殺さない（§12⑤）
            skipped << candidate.target_date
          end
        end
      end
      Result.new(confirmed_dates: confirmed, skipped_dates: skipped)
    end

    # 1 日 = {AR create → 候補 destroy → history create} を 1 savepoint に束ねる（§12⑤）。
    # insert_all/upsert_all は使わない — belongs_to presence（IDOR 防御）と
    # absence_reason_only_on_absent（毒入力防御）の 2 検証を skip するため（§12④）
    def confirm_one(candidate)
      ActiveRecord::Base.transaction(requires_new: true) do
        AttendanceRecord.create!(
          user: @target_user, work_date: candidate.target_date,
          status: :absent, absence_reason: @absence_reason, note: note_for_reason
        )
        candidate.destroy!
        AttendanceHistory.create!(
          user: @target_user, actor: @actor,
          event_type: :absence_confirmed, event_date: candidate.target_date,
          new_status: AttendanceRecord.statuses[:absent],
          # AR.absence_reason は事後有給（absent→on_leave）でクリアされるため、確定時点の理由を監査へ焼く。
          # 書式は AttendanceRecord が単一源（ApplyApproval の absence_to_paid と同一書式・Task 2）
          note: AttendanceRecord.absence_reason_note(@absence_reason)
        )
      end
    end

    # other 選択時のみ note に理由を入れる。other 以外は note=null（SPEC §6.10）
    def note_for_reason = @absence_reason == "other" ? @note.presence : nil

    def resolver = @resolver ||= CompanyCalendarResolver.new(organization:)
  end
end
