# frozen_string_literal: true

require "rails_helper"

RSpec.describe "LeaveRequests", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:dept) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role) } }
  let!(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: dept) } }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user, manager:) } }
  let!(:leave_type) { ActsAsTenant.with_tenant(org) { create(:leave_type) } }

  before { sign_in user }

  describe "POST create" do
    it "申請を作成し days_requested はサーバ確定・status=applying（mass-assignment 遮断）" do
      expect {
        post leave_requests_url(host: tenant_host(org)),
             params: { leave_request: { leave_type_id: leave_type.id, start_date: "2026-05-01",
                                        end_date: "2026-05-01", half_day_type: "none", reason: "私用",
                                        days_requested: "99", approval_status: "approved" } }
      }.to change { ActsAsTenant.with_tenant(org) { LeaveRequest.count } }.by(1)
      record = ActsAsTenant.with_tenant(org) { LeaveRequest.last }
      expect(record.days_requested).to eq(BigDecimal("1"))   # client の 99 を無視
      expect(record.approval_status).to eq("applying")        # client の approved を無視
    end

    it "空/不正な日付は 422（500 にしない）" do
      expect {
        post leave_requests_url(host: tenant_host(org)),
             params: { leave_request: { leave_type_id: leave_type.id, start_date: "",
                                        end_date: "", half_day_type: "none", reason: "x" } }
      }.not_to change { ActsAsTenant.with_tenant(org) { LeaveRequest.count } }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "GET index" do
    it "自分の申請のみ表示し他者の申請を漏らさない（index は leave_type 名を描画）" do
      ActsAsTenant.with_tenant(org) do
        mine_type = create(:leave_type, name: "私の有給")
        others_type = create(:leave_type, name: "他人の慶弔")
        create(:leave_request, requester: user, leave_type: mine_type)
        create(:leave_request, requester: manager, leave_type: others_type)
      end
      get leave_requests_url(host: tenant_host(org))
      expect(response.body).to include("私の有給")
      expect(response.body).not_to include("他人の慶弔")
    end
  end

  describe "PATCH cancel" do
    it "本人は取消でき canceled へ" do
      req = ActsAsTenant.with_tenant(org) { create(:leave_request, requester: user) }
      patch cancel_leave_request_url(req, host: tenant_host(org))
      expect(req.reload.approval_status).to eq("canceled")
    end

    it "他人の申請は 404（policy_scope 経由 find）" do
      other_req = ActsAsTenant.with_tenant(org) { create(:leave_request, requester: manager) }
      patch cancel_leave_request_url(other_req, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
    end
  end
end
