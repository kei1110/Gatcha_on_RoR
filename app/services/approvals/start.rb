# frozen_string_literal: true

module Approvals
  # 承認エンジンの明示起動（SPEC §7.7）。route 解決 → pending な ApprovalAssignment を生成。
  # 2-2+ の申請作成サービスが save! と同一 tx で呼ぶ。2-1 は spec が呼ぶ。
  # purpose: :approval（通常承認）/ :withdrawal（撤回承認）で世代を区別し共存可（2-5）。
  class Start
    def self.call(approvable, purpose: :approval) = new(approvable, purpose:).call

    def initialize(approvable, purpose: :approval)
      @approvable = approvable
      @purpose = purpose
    end

    def call
      return @approvable if @approvable.approval_assignments.where(purpose: @purpose).exists?  # 冪等（purpose 毎）

      approvers = RouteResolver.call(requester: @approvable.requester)
      ApprovalAssignment.transaction do
        approvers.each_with_index do |approver, idx|
          @approvable.approval_assignments.create!(
            organization: @approvable.organization,
            approver:,
            position: idx + 1,
            purpose: @purpose,
            decision: :pending
          )
        end
      end
      @approvable
    end
  end
end
