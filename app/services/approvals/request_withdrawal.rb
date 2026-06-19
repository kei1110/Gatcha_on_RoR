# frozen_string_literal: true

module Approvals
  # 撤回申請の起票（SPEC §7.6）。本人性 + 状態 + 再撤回ガードを gate し撤回世代を生成。
  # with_lock 内・request_withdrawal! の guard（approved? + no_prior_withdrawal_round?）が
  # AASM::InvalidTransition を構造的に発火（terminal/再撤回防御）。
  class RequestWithdrawal
    def self.call(approvable:, requester:, reason:) = new(approvable:, requester:, reason:).call

    def initialize(approvable:, requester:, reason:)
      @approvable = approvable
      @requester = requester
      @reason = reason
    end

    def call
      raise ArgumentError, "撤回理由が必要です" if @reason.blank?

      @approvable.with_lock do
        raise NotRequester unless @requester.id == @approvable.requester_id
        @approvable.withdrawal_reason = @reason
        @approvable.request_withdrawal!                           # approved → withdrawal_requested（reason 同時 save）
        Approvals::Start.call(@approvable, purpose: :withdrawal)  # 撤回世代の assignment 生成
      end
      @approvable
    end
  end
end
