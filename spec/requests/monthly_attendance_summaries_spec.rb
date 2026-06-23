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

    it "manager は自分の submitted summary を params に含めても enqueue 引数から除外される（self-finalize 不可）" do
      own_summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: manager, status: :submitted) }
      sub_summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: sub, status: :submitted) }
      expect {
        patch bulk_finalize_monthly_attendance_summaries_path,
              params: { summary_ids: [ own_summary.id, sub_summary.id ] }, headers: host_headers
      }.to have_enqueued_job(MonthlySummaries::BulkFinalizeJob)
        .with(organization_id: org.id, summary_ids: [ sub_summary.id ]) # 自分の id は finalize? false で除外
    end

    it "hr_admin は自分の submitted summary を params に含めると enqueue 引数に含まれる" do
      hr = ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) }
      own_summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: hr, status: :submitted) }
      sign_in hr
      expect {
        patch bulk_finalize_monthly_attendance_summaries_path,
              params: { summary_ids: [ own_summary.id ] }, headers: host_headers
      }.to have_enqueued_job(MonthlySummaries::BulkFinalizeJob)
        .with(organization_id: org.id, summary_ids: [ own_summary.id ]) # hr_admin は自己確定可（finalize? true）
    end

    it "employee は一括確定できない（403）" do
      sign_in user # 一般社員
      patch bulk_finalize_monthly_attendance_summaries_path,
            params: { summary_ids: [] }, headers: host_headers
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "CSV エクスポート（3-3b）" do
    def host_headers = { "HOST" => tenant_host(org) }

    describe "summary_csv（collection・scope）" do
      it "manager は自分 + 部下のみ・他は除外（IDOR）" do
        manager = ActsAsTenant.with_tenant(org) { create(:user, :manager_role) }
        sub = ActsAsTenant.with_tenant(org) { create(:user, manager:, employee_code: "E777") }
        outsider = ActsAsTenant.with_tenant(org) { create(:user, employee_code: "E999") }
        ActsAsTenant.with_tenant(org) do
          create(:monthly_attendance_summary, user: sub, year_month: "2026-03")
          create(:monthly_attendance_summary, user: outsider, year_month: "2026-03")
        end
        sign_in manager
        get summary_csv_monthly_attendance_summaries_path, params: { year_month: "2026-03" }, headers: host_headers
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/csv")
        expect(response.body).to start_with("﻿")
        expect(response.body).to include("E777")
        expect(response.body).not_to include("E999")
      end

      it "hr_admin は全社員" do
        admin = ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) }
        ActsAsTenant.with_tenant(org) do
          create(:monthly_attendance_summary, user: create(:user, employee_code: "E001"), year_month: "2026-03")
          create(:monthly_attendance_summary, user: create(:user, employee_code: "E002"), year_month: "2026-03")
        end
        sign_in admin
        get summary_csv_monthly_attendance_summaries_path, params: { year_month: "2026-03" }, headers: host_headers
        expect(response.body).to include("E001").and include("E002")
      end

      it "不正 year_month は 400" do
        get summary_csv_monthly_attendance_summaries_path, params: { year_month: "2026-13" }, headers: host_headers
        expect(response).to have_http_status(:bad_request)
      end
    end

    describe "detail_csv（member）" do
      it "本人が自分の明細を DL（1 行=1 AR）" do
        period_day = Date.new(2026, 3, 5)
        summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user:, year_month: "2026-03") }
        ActsAsTenant.with_tenant(org) { create(:attendance_record, :done, user:, work_date: period_day) }
        get detail_csv_monthly_attendance_summary_path(summary), headers: host_headers
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq("text/csv")
        expect(response.body).to include("2026-03-05")
      end

      it "scope 外 summary は 404（IDOR）" do
        other = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: create(:user), year_month: "2026-03") }
        get detail_csv_monthly_attendance_summary_path(other), headers: host_headers
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
