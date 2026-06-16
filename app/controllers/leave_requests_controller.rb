# frozen_string_literal: true

# 社員の休暇申請（Phase 2-2a 設計 §4）。requester=current_user 構造固定 — params から
# requester_id/user_id を一切受けない（MPR C3・残高漏洩の唯一の壁）。
class LeaveRequestsController < ApplicationController
  before_action :set_leave_request, only: :cancel

  def index
    authorize LeaveRequest
    @leave_requests = policy_scope(LeaveRequest).order(start_date: :desc)
  end

  def new
    authorize LeaveRequest
    @leave_request = LeaveRequest.new(start_date: current_user.organization.today)
    @leave_types = LeaveType.where(active: true)
  end

  def create
    authorize LeaveRequest
    @leave_request = LeaveRequests::Create.call(
      requester: current_user, leave_type: LeaveType.find(create_params[:leave_type_id]),
      start_date: Date.parse(create_params[:start_date]),
      end_date: Date.parse(create_params[:end_date]),
      half_day_type: create_params[:half_day_type], reason: create_params[:reason]
    )
    redirect_to leave_requests_path, status: :see_other, notice: "休暇を申請しました"
  rescue Approvals::RouteError
    redirect_to leave_requests_path, status: :see_other,
                alert: "申請できません。直属上長が未設定です（管理者にご連絡ください）"
  rescue ActiveRecord::RecordInvalid => e
    @leave_request = e.record
    @leave_types = LeaveType.where(active: true)
    render :new, status: :unprocessable_entity
  rescue ArgumentError, Date::Error, TypeError
    @leave_request = LeaveRequest.new(create_params.except(:start_date, :end_date))
    @leave_types = LeaveType.where(active: true)
    @leave_request.errors.add(:base, "申請内容が正しくありません（日付・期間・半休をご確認ください）")
    render :new, status: :unprocessable_entity
  end

  def cancel
    authorize @leave_request, :cancel?
    Approvals::Cancel.call(approvable: @leave_request, by: current_user)
    redirect_to leave_requests_path, status: :see_other, notice: "申請を取り消しました"
  end

  private

  # 他人の申請 id は policy_scope 経由 find で 404（scope + policy の二層・MPR セキュリティ）
  def set_leave_request
    @leave_request = policy_scope(LeaveRequest).find(params[:id])
  end

  # requester_id/user_id/days_requested/approval_status は受けない（サーバ権威）
  def create_params
    params.require(:leave_request).permit(:leave_type_id, :start_date, :end_date, :half_day_type, :reason)
  end
end
