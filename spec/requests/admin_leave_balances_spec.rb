# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin::LeaveBalances", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:target) { ActsAsTenant.with_tenant(org) { create(:user, name: "田中太郎") } }
  let!(:annual) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :annual, paid_leave: true) } }

  describe "認可" do
    it "employee は new が 403・hr_admin は 200（対照）" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get new_admin_user_leave_balance_url(target, host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get new_admin_user_leave_balance_url(target, host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end

    it "他テナントの user_id は 404（IDOR）" do
      sign_in admin
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:user) }
      get new_admin_user_leave_balance_url(outsider, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "残高を付与できる（granted_on 同梱）" do
      expect {
        post admin_user_leave_balances_url(target, host: tenant_host(org)),
             params: { leave_balance: { leave_type_id: annual.id, fiscal_year: "2026",
                                        granted_days: "10", carry_over_days: "0",
                                        granted_on: "2026-04-01" } }
      }.to change { ActsAsTenant.with_tenant(org) { LeaveBalance.count } }.by(1)
    end

    it "used_days は permit されない（改竄無視）" do
      post admin_user_leave_balances_url(target, host: tenant_host(org)),
           params: { leave_balance: { leave_type_id: annual.id, fiscal_year: "2026",
                                      granted_days: "10", granted_on: "2026-04-01", used_days: "99" } }
      balance = ActsAsTenant.with_tenant(org) { LeaveBalance.last }
      expect(balance.used_days).to eq(0)
    end
  end
end
