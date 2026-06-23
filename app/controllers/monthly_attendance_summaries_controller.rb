# frozen_string_literal: true

# 月次締め（SPEC §6.6・3-2 設計 §4.2）。本人=提出、上長/hr_admin=確定/差戻し。
class MonthlyAttendanceSummariesController < ApplicationController
  before_action :set_summary, only: %i[show submit finalize defer detail_csv]

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
    # 一括対象は per-record の finalize? で絞る（単一確定と同じ認可境界＝
    # manager の自己確定を除外・hr_admin の自己確定は許可・横断 divergence を構造的に消す）
    ids = policy_scope(MonthlyAttendanceSummary)
            .where(id: params[:summary_ids])
            .select { |s| policy(s).finalize? }
            .map(&:id)
    MonthlySummaries::BulkFinalizeJob.perform_later(organization_id: current_tenant.id, summary_ids: ids)
    redirect_to monthly_attendance_summaries_path, status: :see_other, notice: "#{ids.size} 件の確定を受け付けました"
  end

  def summary_csv
    authorize MonthlyAttendanceSummary, :summary_csv?
    period = AttendancePeriod.new(organization: current_tenant, year_month: params[:year_month])
    summaries = policy_scope(MonthlyAttendanceSummary)
                  .where(year_month: period.label).includes(:user).order(:user_id).to_a
    stream_csv(MonthlySummaries::Csv::SummaryExporter.call(summaries:),
               "monthly_summary_#{period.label}.csv")
  rescue ArgumentError
    head :bad_request
  end

  def detail_csv
    authorize @summary, :detail_csv?
    period = AttendancePeriod.new(organization: current_tenant, year_month: @summary.year_month)
    records = AttendanceRecord.where(user_id: @summary.user_id, work_date: period.range).order(:work_date).to_a
    stream_csv(MonthlySummaries::Csv::DailyDetailExporter.call(records:, time_zone: current_tenant.time_zone),
               "daily_detail_#{@summary.user.employee_code}_#{period.label}.csv")
  end

  private

  # 行は呼び出し側で .to_a 事前確定済（テナント文脈下）ゆえ body は文字列整形のみ＝DB 非依存・テナント安全（D7）
  def stream_csv(enumerator, filename)
    response.headers["Content-Type"] = "text/csv; charset=utf-8"
    response.headers["Content-Disposition"] = %(attachment; filename="#{filename}")
    self.response_body = enumerator
  end

  def current_tenant = ActsAsTenant.current_tenant

  def set_summary
    @summary = policy_scope(MonthlyAttendanceSummary).find(params[:id])
  end
end
