# frozen_string_literal: true

# 月次締め（SPEC §6.6・3-2 設計 §4.2）。本人=提出、上長/hr_admin=確定/差戻し。
class MonthlyAttendanceSummariesController < ApplicationController
  before_action :set_summary, only: %i[show submit finalize defer]

  def index
    authorize MonthlyAttendanceSummary
    @summaries = policy_scope(MonthlyAttendanceSummary).order(year_month: :desc)
  end

  def show
    authorize @summary
    @period = AttendancePeriod.new(organization: current_tenant, year_month: @summary.year_month)
    @pending = MonthlySummaries::PendingRequests.new(user: @summary.user, period: @period)
  end

  def submit
    authorize @summary, :submit?
    period = AttendancePeriod.new(organization: current_tenant, year_month: @summary.year_month)
    MonthlySummaries::Submit.call(user: @summary.user, period:)
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, notice: "締めを提出しました"
  rescue Approvals::ConflictError
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other,
                alert: "承認手続き中の申請があります。完了またはキャンセル後に提出してください"
  rescue AASM::InvalidTransition
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, alert: "この締めは提出できません"
  end

  def finalize
    authorize @summary, :finalize?
    MonthlySummaries::Finalize.call(summary: @summary)
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, notice: "締めを確定しました"
  rescue AASM::InvalidTransition
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, alert: "この締めは確定できません"
  end

  def defer
    authorize @summary, :defer?
    MonthlySummaries::Defer.call(summary: @summary, reason: params[:deferral_reason])
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, notice: "差戻しました"
  rescue ActiveRecord::RecordInvalid
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, alert: "差戻し理由を入力してください"
  rescue AASM::InvalidTransition
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, alert: "この締めは差戻しできません"
  end

  def bulk_finalize
    authorize MonthlyAttendanceSummary, :bulk_finalize?
    ids = policy_scope(MonthlyAttendanceSummary).where(id: params[:summary_ids]).pluck(:id) # IDOR 交差（§3.3）
    MonthlySummaries::BulkFinalizeJob.perform_later(organization_id: current_tenant.id, summary_ids: ids)
    redirect_to monthly_attendance_summaries_path, status: :see_other, notice: "#{ids.size} 件の確定を受け付けました"
  end

  private

  def current_tenant = ActsAsTenant.current_tenant

  def set_summary
    @summary = policy_scope(MonthlyAttendanceSummary).find(params[:id])
  end
end
