# frozen_string_literal: true

require "rails_helper"

RSpec.describe "MonthlyAttendanceSummaries", type: :request do
  let(:org) { create(:organization) }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  before { sign_in user }

  def host_headers = { "HOST" => tenant_host(org) }

  it "本人が自分の締めを提出できる" do
    summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user:) }
    patch submit_monthly_attendance_summary_path(summary), headers: host_headers
    expect(response).to have_http_status(:see_other)
    expect(summary.reload).to be_submitted
  end

  it "scope 外の summary は 404（IDOR）" do
    other = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: create(:user)) }
    patch submit_monthly_attendance_summary_path(other), headers: host_headers
    expect(response).to have_http_status(:not_found)
  end

  it "上長が部下の締めを確定できる" do
    manager = ActsAsTenant.with_tenant(org) { create(:user, :manager_role) }
    sub = ActsAsTenant.with_tenant(org) { create(:user, manager:) }
    summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: sub, status: :submitted) }
    sign_in manager
    patch finalize_monthly_attendance_summary_path(summary), headers: host_headers
    expect(summary.reload).to be_finalized
  end

  it "差戻しは reason 必須（空なら再描画・遷移しない）" do
    manager = ActsAsTenant.with_tenant(org) { create(:user, :manager_role) }
    sub = ActsAsTenant.with_tenant(org) { create(:user, manager:) }
    summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: sub, status: :submitted) }
    sign_in manager
    patch defer_monthly_attendance_summary_path(summary), params: { deferral_reason: "" }, headers: host_headers
    expect(summary.reload).to be_submitted # 遷移していない
  end

  describe "一括確定" do
    let(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role) } }
    let(:sub) { ActsAsTenant.with_tenant(org) { create(:user, manager:) } }

    before { sign_in manager }

    it "scope 内 id のみで BulkFinalizeJob を enqueue する" do
      mine = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: sub, status: :submitted) }
      foreign = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: create(:user), status: :submitted) }
      expect {
        patch bulk_finalize_monthly_attendance_summaries_path,
              params: { summary_ids: [ mine.id, foreign.id ] }, headers: host_headers
      }.to have_enqueued_job(MonthlySummaries::BulkFinalizeJob)
        .with(organization_id: org.id, summary_ids: [ mine.id ]) # foreign は scope 交差で除外
    end

    it "employee は一括確定できない（403）" do
      sign_in user # 一般社員
      patch bulk_finalize_monthly_attendance_summaries_path,
            params: { summary_ids: [] }, headers: host_headers
      expect(response).to have_http_status(:forbidden)
    end
  end
end
