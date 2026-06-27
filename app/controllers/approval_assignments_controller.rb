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
    approvable = @assignment.approvable
    Approvals::Approve.call(approvable:, approver: current_user, comment: params[:comment])
    notify_decision(approvable, :request_approved) if approvable.approved? # 終端のみ（中間/取下げ承認は不発火）
    redirect_to approval_assignments_path, status: :see_other, notice: "承認しました"
  rescue Approvals::OverBalanceError
    redirect_to approval_assignments_path, status: :see_other,
                alert: "残高不足で承認できません（人事へ残高の付与をご依頼ください）"
  rescue Approvals::ClosingLockedError
    redirect_to approval_assignments_path, status: :see_other,
                alert: "対象月は締め済みのため承認できません（管理者へ差戻し依頼をご検討ください）"
  rescue Approvals::ConflictError
    msg = @assignment.purpose_withdrawal? ? "対象記録が変更されているため撤回できません" :
                                            "変更前時刻が現在の記録と一致しません（申請者へ再申請をご依頼ください）"
    redirect_to approval_assignments_path, status: :see_other, alert: msg
  rescue ActiveRecord::RecordInvalid
    redirect_to approval_assignments_path, status: :see_other,
                alert: "承認できませんでした（記録の整合性エラー）"
  rescue AASM::InvalidTransition, Approvals::NotCurrentApprover
    redirect_to approval_assignments_path, status: :see_other, alert: "この申請は既に処理されています"
  end

  def reject
    authorize @assignment, :reject?
    approvable = @assignment.approvable
    Approvals::Reject.call(approvable:, approver: current_user, comment: params[:comment])
    notify_decision(approvable, :request_rejected) if approvable.rejected? # 取下げ却下（approved 復帰）は不発火
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

  # 承認/却下の終端でのみ requester へ通知（§5.4・informational・既定ベル）。
  # service 戻り後ゆえ承認 tx は commit 済 → Notifier が最外 tx（§9③ / ROADMAP 申し送り）。
  # テナント文脈は ApplicationController の resolve_tenant_from_subdomain で確立済。
  def notify_decision(approvable, source_type)
    verb = source_type == :request_approved ? "承認" : "却下"
    Notifier.call(
      target_user: approvable.requester,
      title: "申請が#{verb}されました",
      body: "あなたの申請が#{verb}されました。",
      priority: :informational,
      source_type:,
      subject_user: approvable.requester
    )
  end
end
