# frozen_string_literal: true

# 社員の休日出勤申請（2-4 設計 §3.1・ClockChangeRequestsController 同型）。requester=current_user 構造固定。
class HolidayWorkRequestsController < ApplicationController
  before_action :set_holiday_work_request, only: :cancel

  def index
    authorize HolidayWorkRequest
    @holiday_work_requests = policy_scope(HolidayWorkRequest).order(work_date: :desc)
  end

  def new
    authorize HolidayWorkRequest
    @holiday_work_request = HolidayWorkRequest.new
    @compensation_leave_types = LeaveType.where(system_type: :compensatory_leave)
  end

  def create
    authorize HolidayWorkRequest
    @holiday_work_request = HolidayWorkRequests::Create.call(
      requester: current_user,
      work_date: create_params[:work_date],
      compensation_leave_type: LeaveType.find(create_params[:compensation_leave_type_id]),
      reason: create_params[:reason]
    )
    redirect_to holiday_work_requests_path, status: :see_other, notice: "休日出勤を申請しました"
  rescue Approvals::RouteError
    redirect_to holiday_work_requests_path, status: :see_other,
                alert: "申請できません。直属上長が未設定です（管理者にご連絡ください）"
  rescue ActiveRecord::RecordInvalid => e
    @holiday_work_request = e.record
    @compensation_leave_types = LeaveType.where(system_type: :compensatory_leave)
    render :new, status: :unprocessable_entity
  end

  def cancel
    authorize @holiday_work_request, :cancel?
    Approvals::Cancel.call(approvable: @holiday_work_request, by: current_user)
    redirect_to holiday_work_requests_path, status: :see_other, notice: "申請を取り消しました"
  rescue AASM::InvalidTransition
    redirect_to holiday_work_requests_path, status: :see_other, alert: "この申請は取り消せません"
  end

  private

  def set_holiday_work_request
    @holiday_work_request = policy_scope(HolidayWorkRequest).find(params[:id])
  end

  # requester_id/approval_status は受けない（サーバ権威）
  def create_params
    params.require(:holiday_work_request).permit(:work_date, :compensation_leave_type_id, :reason)
  end
end
