# frozen_string_literal: true

# 社員の打刻変更申請（2-3 設計 §3.2）。requester=current_user 構造固定。
# ★new_clock_* は組織 TZ で parse（config.time_zone 未設定＝UTC ゆえ Time.zone.parse は不可）。
class ClockChangeRequestsController < ApplicationController
  before_action :set_clock_change_request, only: :cancel

  def index
    authorize ClockChangeRequest
    @clock_change_requests = policy_scope(ClockChangeRequest).order(created_at: :desc)
  end

  def new
    authorize ClockChangeRequest
    # 本人の記録に限定（has_many 経由 + acts_as_tenant default_scope ＝テナント+本人。他人は 404）
    @attendance_record = current_user.attendance_records.find(params[:attendance_record_id])
    @clock_change_request = ClockChangeRequest.new(attendance_record: @attendance_record)
  end

  def create
    authorize ClockChangeRequest
    record = current_user.attendance_records.find(create_params[:attendance_record_id])
    @clock_change_request = ClockChangeRequests::Create.call(
      requester: current_user, attendance_record: record,
      change_type: create_params[:change_type],
      new_clock_in: parse_org_time(create_params[:new_clock_in]),
      new_clock_out: parse_org_time(create_params[:new_clock_out]),
      reason: create_params[:reason]
    )
    redirect_to clock_change_requests_path, status: :see_other, notice: "打刻変更を申請しました"
  rescue Approvals::RouteError
    redirect_to clock_change_requests_path, status: :see_other,
                alert: "申請できません。直属上長が未設定です（管理者にご連絡ください）"
  rescue ActiveRecord::RecordInvalid => e
    @clock_change_request = e.record
    @attendance_record = record
    render :new, status: :unprocessable_entity
  end

  def cancel
    authorize @clock_change_request, :cancel?
    Approvals::Cancel.call(approvable: @clock_change_request, by: current_user)
    redirect_to clock_change_requests_path, status: :see_other, notice: "申請を取り消しました"
  rescue AASM::InvalidTransition
    redirect_to clock_change_requests_path, status: :see_other, alert: "この申請は取り消せません"
  end

  private

  def set_clock_change_request
    @clock_change_request = policy_scope(ClockChangeRequest).find(params[:id])
  end

  # attendance_record_id/original_*/approval_status は受けない（サーバ権威）
  def create_params
    params.require(:clock_change_request).permit(:attendance_record_id, :change_type,
                                                 :new_clock_in, :new_clock_out, :reason)
  end

  # ★組織 TZ で parse（UTC 既定の Time.zone.parse は 9h ズレ）
  def parse_org_time(value)
    return nil if value.blank?

    ActiveSupport::TimeZone[current_user.organization.time_zone].parse(value)
  end
end
