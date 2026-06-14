# frozen_string_literal: true

module Approvals
  # 承認（SPEC §7.3）。terminal/pin/自己承認/段階順序を gate し、現段階 assignment を approved に。
  # 最終段階なら host の AASM approve! を発火（2-1 は副作用なし）。with_lock で段階進行を直列化。
  class Approve
    def self.call(approvable:, approver:, acting_user: approver, comment: nil)
      new(approvable:, approver:, acting_user:, comment:).call
    end

    def initialize(approvable:, approver:, acting_user:, comment:)
      @approvable = approvable
      @approver = approver
      @acting_user = acting_user
      @comment = comment
    end

    def call
      @approvable.with_lock do
        guard!
        assignment = current_assignment!
        assignment.update!(decision: :approved, acted_at: Time.current, comment: @comment)
        @approvable.approve! if @approvable.all_stages_approved?
      end
      @approvable
    end

    private

    def guard!
      raise AASM::InvalidTransition.new(@approvable, :approve, :default) unless @approvable.applying?
      raise ProxyNotSupported unless @acting_user.id == @approver.id # 2-1 pin（代理は §7.5）

      return unless SelfApproval.violated?(
        requester_id: @approvable.requester_id,
        approver_id: @approver.id,
        acting_user_id: @acting_user.id
      )

      raise SelfApprovalError
    end

    def current_assignment!
      position = @approvable.current_approval_position
      assignment = @approvable.approval_assignments.find_by(position:, decision: :pending)
      raise NotCurrentApprover unless assignment && assignment.approver_id == @approver.id

      assignment
    end
  end
end
