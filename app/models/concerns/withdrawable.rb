# frozen_string_literal: true

# 撤回フロー（SPEC §7.6・§13.2）を Approvable host に付与する。LR/CCR のみ include。
# HWR は撤回フローを持たない（§4.12/§13.3）ため本 concern を include しない＝撤回イベント非獲得（D7）。
# 実装注記: include Approvable により AS::Concern は Approvable の included（enum + 基底 aasm）を
# 先に評価し、その後 Withdrawable の included（aasm 再オープン）が同一機械へ撤回 state/event を足す。
module Withdrawable
  extend ActiveSupport::Concern
  include Approvable

  included do
    validates :withdrawal_reason, presence: true, if: :withdrawal_requested?

    aasm do  # 基底 Approvable の機械（enum: true, whiny_persistence: true）を再オープン
      state :withdrawal_requested
      state :withdrawn

      event :request_withdrawal do
        transitions from: :approved, to: :withdrawal_requested,
                    guard: %i[no_prior_withdrawal_round? closing_unlocked?] # §6.7 締め制限（3-2）
      end
      event :approve_withdrawal do
        transitions from: :withdrawal_requested, to: :withdrawn, guard: :all_stages_approved?
      end
      event :reject_withdrawal do
        transitions from: :withdrawal_requested, to: :approved   # 副作用なし（§13.6）
      end
    end
  end

  # D6: 撤回世代の assignment が皆無か（再撤回防止）
  def no_prior_withdrawal_round? = !approval_assignments.where(purpose: :withdrawal).exists?
end
