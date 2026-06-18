# frozen_string_literal: true

# 承認インボックス（SPEC §6.2・§7・2-2b 設計 §4）。actionable な ApprovalAssignment を一覧し、
# 承認/却下を Approvals::Approve / Reject へ委譲。over-balance 等は rescue して flash 再描画。
class ApprovalAssignmentsController < ApplicationController
  before_action :set_assignment, only: %i[approve reject]

  def index
    authorize ApprovalAssignment
    # approvable は polymorphic ゆえ nested preload 不可（型混在で AssociationNotFoundError）。
    # 表示 N+1 は §16.1 許容・型別 preload は 2-3 で（ROADMAP backlog）
    @assignments = policy_scope(ApprovalAssignment)
                   .includes(:approvable)
                   .select { |assignment| policy(assignment).approve? }   # 現段階の actionable のみ
  end

  def approve
    authorize @assignment, :approve?
    Approvals::Approve.call(approvable: @assignment.approvable, approver: current_user,
                            comment: params[:comment])
    redirect_to approval_assignments_path, status: :see_other, notice: "承認しました"
  rescue Approvals::OverBalanceError
    redirect_to approval_assignments_path, status: :see_other,
                alert: "残高不足で承認できません（人事へ残高の付与をご依頼ください）"
  rescue Approvals::ConflictError
    redirect_to approval_assignments_path, status: :see_other,
                alert: "変更前時刻が現在の記録と一致しません（申請者へ再申請をご依頼ください）"
  rescue AASM::InvalidTransition, Approvals::NotCurrentApprover
    redirect_to approval_assignments_path, status: :see_other, alert: "この申請は既に処理されています"
  end

  def reject
    authorize @assignment, :reject?
    Approvals::Reject.call(approvable: @assignment.approvable, approver: current_user,
                           comment: params[:comment])
    redirect_to approval_assignments_path, status: :see_other, notice: "却下しました"
  rescue ArgumentError
    redirect_to approval_assignments_path, status: :see_other, alert: "却下理由を入力してください"
  rescue AASM::InvalidTransition, Approvals::NotCurrentApprover
    redirect_to approval_assignments_path, status: :see_other, alert: "この申請は既に処理されています"
  end

  private

  # 他人/他テナントの assignment は policy_scope 経由 find で 404（scope + policy の二層）
  def set_assignment
    @assignment = policy_scope(ApprovalAssignment).find(params[:id])
  end
end
