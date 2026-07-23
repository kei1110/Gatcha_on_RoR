# frozen_string_literal: true

module Absences
  # 欠勤候補の却下(dismiss)（SPEC §6.10・設計 4-2c-3b §4.3・D2）。
  # 現行 controller の candidate.destroy! を service へ移し、候補 destroy と
  # AttendanceHistory(absence_dismissed) の append を **1 tx** で束ねる。分離すると
  # 「候補だけ消えて履歴なし」か「却下履歴だけあって候補が残る」状態が生じる。
  #
  # 却下は候補（ephemeral）を消す操作だが、候補は前日分しか生成されず再生成されないため
  # （ROADMAP 横断 #116）、監査行を残さないと「取消→候補復活→却下」で痕跡ゼロの完全消去が
  # 可能になる（D2）。理由 note は任意（大量・定型ゆえ必須化するとコピペで情報量ゼロに収束・D4）。
  class Dismiss
    def self.call(**) = new(**).call

    def initialize(candidate:, actor:, note: nil)
      @candidate = candidate
      @actor = actor
      @note = note
    end

    def call
      guard_actor_same_organization! # with_tenant へ入る前（昇格前・Confirm/Withdraw 同型）
      ActsAsTenant.with_tenant(@candidate.user.organization) do
        ActiveRecord::Base.transaction do
          AttendanceHistory.create!(
            user_id: @candidate.user_id, actor: @actor,
            event_type: :absence_dismissed, event_date: @candidate.target_date, note: @note
          )
          @candidate.destroy!
        end
      end
      @candidate
    end

    private

    def guard_actor_same_organization!
      return if @actor.organization_id == @candidate.user.organization_id

      raise IneligibleError, "操作者と対象社員の組織が一致しません"
    end
  end
end
