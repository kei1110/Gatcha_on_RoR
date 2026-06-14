# frozen_string_literal: true

# 自己承認防止の認可層（SPEC §7.3・サービス層と独立した二層の片側）。
# 自己承認規則の定義は Approvals::SelfApproval に一元化（enforce のみ二層）。
class ApprovalAssignmentPolicy < ApplicationPolicy
  def approve? = actionable?
  def reject?  = actionable?

  private

  def actionable?
    record.pending? &&
      record.approvable.applying? &&                                    # terminal は不可
      record.approver_id == user.id &&                                  # 現段階の担当者本人（§7.5 で delegate 緩和）
      record.position == record.approvable.current_approval_position && # 段階順序
      !Approvals::SelfApproval.violated?(
        requester_id: record.approvable.requester_id,
        approver_id: record.approver_id,
        acting_user_id: user.id
      )
  end
end
