# frozen_string_literal: true

module Approvals
  # 承認（SPEC §7.3）。terminal/pin/自己承認/段階順序を gate し、現段階 assignment を approved に。
  # 最終段階なら host の AASM approve! を発火（2-1 は副作用なし）。with_lock で段階進行を直列化。
  # 2-5: withdrawal_requested 状態では approve_withdrawal! を撃ち分け（finalize! が判定）。
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
        finalize! if @approvable.all_stages_approved?
      end
      @approvable
    end

    private

    def guard!
      raise ClosingLockedError if @approvable.closing_locked? # 締め再チェック（§6.6・3-2・入口で fail-closed）
      raise AASM::InvalidTransition.new(@approvable, :approve, :default) unless @approvable.awaiting_decision?
      raise ProxyNotSupported unless @acting_user.id == @approver.id # 2-1 pin（代理は §7.5）

      return unless SelfApproval.violated?(
        requester_id: @approvable.requester_id,
        approver_id: @approver.id,
        acting_user_id: @acting_user.id
      )

      raise SelfApprovalError
    end

    # host 状態で確定イベント + 副作用を撃ち分け（§13.6）。判定は遷移前に行う
    def finalize!
      if @approvable.withdrawal_requested?
        @approvable.approve_withdrawal!
        @approvable.apply_withdrawal_effects!(acting_user: @acting_user)
      else
        @approvable.approve!
        @approvable.apply_approval_effects!(acting_user: @acting_user)  # 副作用（§13.6・2-2b）
      end
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
