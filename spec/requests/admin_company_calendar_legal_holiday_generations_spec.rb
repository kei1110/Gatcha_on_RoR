require "rails_helper"

RSpec.describe "Admin::CompanyCalendars::LegalHolidayGenerations", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }

  it "未認証はサインインへ・employee は 403 + DB 不変" do
    get new_admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org))
    expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

    employee = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in employee
    get new_admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org))
    expect(response).to have_http_status(:forbidden)
    post admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org)),
         params: { start_date: "2026-06-01", end_date: "2026-06-14", cwday: "7" }
    expect(response).to have_http_status(:forbidden)
    expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.count }).to eq(0)
  end

  describe "hr_admin" do
    before { sign_in admin }

    it "フォーム表示（注意文 — 就業規則整合・週休制専用）" do
      get new_admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org))
      expect(response.body).to include("就業規則").and include("4 週 4 日")
    end

    it "一括登録成功（既存の祝日も legal_holiday で上書き — 労働者有利方向）" do
      ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-06-07", name: "何かの祝日") }
      post admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org)),
           params: { start_date: "2026-06-01", end_date: "2026-06-14", cwday: "7" }

      expect(response).to have_http_status(:see_other)
      ActsAsTenant.with_tenant(org) do
        expect(CompanyCalendar.legal_holiday.pluck(:date)).to contain_exactly(
          Date.new(2026, 6, 7), Date.new(2026, 6, 14))
      end
    end

    it "期間超過・曜日未選択は 422 + DB 不変" do
      post admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org)),
           params: { start_date: "2026-01-01", end_date: "2030-01-01", cwday: "7" }
      expect(response).to have_http_status(:unprocessable_entity)

      post admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org)),
           params: { start_date: "2026-06-01", end_date: "2026-06-14", cwday: "" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.count }).to eq(0)
    end
  end
end
