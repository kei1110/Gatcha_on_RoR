# frozen_string_literal: true

module Approvals
  # 却下（SPEC §7.3）。どの段階でも全体却下。terminal/pin/自己承認/段階順序を gate。
  # 2-5: withdrawal_requested 状態では reject_withdrawal! を撃ち分け（approved へ復帰・副作用なし）。
  class Reject
    def self.call(approvable:, approver:, comment:, acting_user: approver)
      new(approvable:, approver:, acting_user:, comment:).call
    end

    def initialize(approvable:, approver:, acting_user:, comment:)
      @approvable = approvable
      @approver = approver
      @acting_user = acting_user
      @comment = comment
    end

    def call
      raise ArgumentError, "却下理由が必要です" if @comment.blank?

      @approvable.with_lock do
        guard!
        assignment = current_assignment!
        assignment.update!(decision: :rejected, acted_at: Time.current, comment: @comment)
        @approvable.withdrawal_requested? ? @approvable.reject_withdrawal! : @approvable.reject!
      end
      @approvable
    end

    private

    def guard!
      raise AASM::InvalidTransition.new(@approvable, :reject, :default) unless @approvable.awaiting_decision?
      raise ProxyNotSupported unless @acting_user.id == @approver.id

      return unless SelfApproval.violated?(
        requester_id: @approvable.requester_id,
        approver_id: @approver.id,
        acting_user_id: @acting_user.id
      )

      raise SelfApprovalError
    end

    def current_assignment!
      position = @approvable.current_approval_position
      assignment = @approvable.approval_assignments.find_by(
        purpose: @approvable.active_purpose, position:, decision: :pending
      )
      raise NotCurrentApprover unless assignment && assignment.approver_id == @approver.id

      assignment
    end
  end
end
