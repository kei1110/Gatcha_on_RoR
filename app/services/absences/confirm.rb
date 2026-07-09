# frozen_string_literal: true

module Absences
  # 欠勤確定の副作用本体（SPEC §6.10 step 4-5・設計 §5.2 / §11⑥⑦ / §12①③④⑤）。
  #
  # 権威源は AbsenceCandidate — params 日付を権威にしない（§11②）。呼び出し元 controller が
  # policy_scope で target_user と candidates を解決して渡す（IDOR は解決側で塞ぐ・§12③）。
  #
  # ガード順は意味論上固定:
  #   ① 操作者の組織 → ② 毒入力 reason → ③ 候補不在日 → ④ 候補の所有者不一致
  #   → ⑤ 弁明の行使（AR / 休暇申請が覆う日） → ⑥ 本人未通知 → ⑦ 猶予前 → ⑧ 締め済み（tx 内）
  #   ① を with_tenant の**外**に置くのは、with_tenant がテナント文脈を「切り替える」ため内側では
  #     複合 FK も cross_tenant 検証も越境を検出できないから（この service 単体の唯一の境界）。
  #   ② を先頭近くに置くのは、per-day の rescue（並行打刻の競合吸収）が毒入力を「skip 日」として
  #     握り潰し 422 を返さなくなるのを防ぐため（部分成功にしない）。
  #   ⑥ を ⑦ より前に置くのは next_business_day(nil) を計算させないため。
  #   ⑧ を tx 内で撃つのは、判定と write の間に締め（submitted）が commit する窓を閉じるため。
  class Confirm
    Result = Struct.new(:confirmed_dates, :skipped_dates, keyword_init: true)

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
      guard_actor_same_organization! # with_tenant へ入る前（昇格前）に検証する
      ActsAsTenant.with_tenant(organization) do
        guard_reason!
        guard_candidates_exist!
        guard_candidates_belong_to_target!
        guard_not_covered!
        guard_notified!
        guard_grace_period!
        confirm_all
      end
    end

    private

    def organization = @target_user.organization

    # ① with_tenant(@target_user.organization) は文脈を切り替えるため、内側の複合 FK も
    #    user_must_belong_to_same_organization も越境を検出できない（organization_id が引数 org 由来で
    #    user_id と整合してしまう）。昇格前に actor と target の組織一致を検証するのが唯一の境界
    def guard_actor_same_organization!
      return if @actor.organization_id == @target_user.organization_id

      raise IneligibleError, "操作者と対象社員の組織が一致しません"
    end

    # ② 毒入力（permit する enum ゆえ不正値は 422 に落とす・§11⑩ 同型）
    def guard_reason!
      return if AttendanceRecord.absence_reasons.key?(@absence_reason)

      raise IneligibleError, "欠勤理由が不正です"
    end

    # ③ 候補の無い日付（却下/撤回された休暇日・過去日の捏造）は確定不可。
    #    v1 では「候補に無い日の欠勤確定」を一切認めない（§11②・§12⑨ の plan 判断）
    def guard_candidates_exist!
      raise IneligibleError, "欠勤候補が選択されていません" if @dates.empty?
      return if @candidates.map(&:target_date).sort == @dates

      raise IneligibleError, "欠勤候補に存在しない日付が含まれています"
    end

    # ④ 呼び出し元の契約違反（target_user と candidates の食い違い）を write 前に拒否する。
    #    現行 controller は policy_scope(AbsenceCandidate).where(user_id: target.id) で紐付けるため
    #    到達しないが、食い違えば「他人の候補を destroy して target_user に absent AR を作る」腐敗になる。
    #    サービス単体でも fail-closed に倒す（多層防御）
    def guard_candidates_belong_to_target!
      return if @candidates.all? { |candidate| candidate.user_id == @target_user.id }

      raise IneligibleError, "欠勤候補が対象社員のものではありません"
    end

    # ⑤ 候補の掃除は日次バッチのみ。バッチ実行後〜猶予期限までに本人が休暇申請を出す（＝通知に応じた
    #    弁明そのもの）と、候補行は残ったまま確定できてしまう。write 前に候補の前提を再評価する
    def guard_not_covered!
      covered = @candidates.map(&:target_date).select { |date| covered?(date) }
      return if covered.empty?

      raise IneligibleError, "#{covered.join(', ')} は勤怠記録または休暇申請が存在するため確定できません"
    end

    # AttendanceAnomalies::Detect#covered? と同一条件（AR 実在 or 全 status の covering LR 実在）
    def covered?(date)
      AttendanceRecord.exists?(user_id: @target_user.id, work_date: date) ||
        LeaveRequest.where(requester_id: @target_user.id)
                    .where(start_date: ..date).where(end_date: date..).exists?
    end

    # ⑥ notified_on nil = 本人へ事前通知が届いていない。誤確定は「実労働日の賃金不払い」に直結し
    #    労基法 24 条（賃金全額払い）違反のリスクを生む。事前通知は誤りを本人からの申し出で是正させる
    #    予防措置であって 24 条が予告・弁明を直接命じるものではない（§12①）。
    #    4-2b は本人宛 Notifier 成功後にのみ notified_on を立てるため presence を「通知済」の proxy にできる
    def guard_notified!
      return if @candidates.all? { |candidate| candidate.notified_on.present? }

      raise IneligibleError, "本人へ未通知の欠勤候補は確定できません（次回の日次バッチで通知されます）"
    end

    # ⑦ 猶予 = notified_on の翌営業日 17:00（組織 TZ）。経過前は確定不可。
    #    本人が申し出て誤確定を是正する時間を確保する予防措置（17:00 は運用値・法定値ではない）
    def guard_grace_period!
      now = Time.current
      @candidates.each do |candidate|
        due = grace.deadline(candidate.notified_on)
        raise IneligibleError, "猶予期限を算出できません（稼働日が見つかりません）" if due.nil?
        next if now > due

        raise IneligibleError,
              "猶予期限（#{due.strftime('%Y-%m-%d %H:%M')}）を過ぎるまで #{candidate.target_date} は確定できません"
      end
    end

    def grace = @grace ||= GracePeriod.new(organization:)

    # ⑧ 締め済み月の日付は確定不可（§11⑦）。既存 ClosingLock の LOCKED は submitted を含む＝
    #    設計 §5.2 の「finalized 禁止・deferred 許可」より厳格（§12⑩・本計画で意図的に採用）。
    #    write 前に対象全日を一括評価し、1 日でも locked なら全件拒否
    def guard_closing!
      return unless MonthlySummaries::ClosingLock.locked?(user: @target_user, dates: @dates)

      raise ClosingLockedError, "締め済みの月（提出済 / 確定）の日付は欠勤確定できません"
    end

    def confirm_all
      confirmed = []
      skipped = []
      ActiveRecord::Base.transaction do
        guard_closing! # ⑧ tx 内で評価（判定と write の間に締めが commit する窓を閉じる）
        @candidates.each do |candidate|
          confirm_one(candidate)
          confirmed << candidate.target_date
        rescue ActiveRecord::RecordNotUnique
          # 真の競合（並行 clock_in / CCR 承認が同日 AR を先に作った）。AR に同日 uniqueness の
          # モデル検証は無く unique index が一次防衛ゆえ、この経路の競合は必ず RecordNotUnique。
          # savepoint のみ rollback され親 tx は健全・候補は intact（再確定可能）
          skipped << candidate.target_date
        rescue ActiveRecord::RecordInvalid => e
          # 本物の検証失敗（越境・毒入力・監査行の不備）。「既に勤怠記録があるためスキップ」という
          # 事実と異なる flash に化けさせない。savepoint rollback 後に伝播させ全件やめる（fail-closed）
          Rails.logger.error("[Absences::Confirm] 検証失敗 date=#{candidate.target_date}: #{e.record.errors.full_messages}")
          Rails.error.report(e, handled: true) # controller が 422 に落とす＝handled
          raise
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
          absence_reason: @absence_reason,  # 構造化（翻訳結果を監査へ焼かない）
          note: note_for_reason             # other の自由記述のみ（他は nil）
        )
      end
    end

    # other 選択時のみ note に理由を入れる。other 以外は note=null（SPEC §6.10）
    def note_for_reason = @absence_reason == "other" ? @note.presence : nil
  end
end
