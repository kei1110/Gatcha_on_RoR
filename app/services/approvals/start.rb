# frozen_string_literal: true

module Approvals
  # 承認エンジンの明示起動（SPEC §7.7）。route 解決 → pending な ApprovalAssignment を生成。
  # 2-2+ の申請作成サービスが save! と同一 tx で呼ぶ。2-1 は spec が呼ぶ。
  class Start
    def self.call(approvable) = new(approvable).call

    def initialize(approvable)
      @approvable = approvable
    end

    def call
      return @approvable if @approvable.approval_assignments.exists? # 冪等

      approvers = RouteResolver.call(requester: @approvable.requester)
      ApprovalAssignment.transaction do
        approvers.each_with_index do |approver, idx|
          @approvable.approval_assignments.create!(
            organization: @approvable.organization,
            approver:,
            position: idx + 1,
            decision: :pending
          )
        end
      end
      @approvable
    end
  end
end
