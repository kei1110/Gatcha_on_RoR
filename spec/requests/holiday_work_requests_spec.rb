# frozen_string_literal: true

require "rails_helper"

RSpec.describe "HolidayWorkRequests", type: :request do
  let(:org) { create(:organization, subdomain: "acme") }
  let(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, organization: org) } }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user, organization: org, manager:) } }
  let(:comp) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :compensatory_leave, organization: org) } }

  before { sign_in user }

  def valid_params(**overrides)
    { holiday_work_request: { work_date: "2026-06-07", compensation_leave_type_id: comp.id,
                              reason: "休日対応", **overrides } }
  end

  describe "POST /holiday_work_requests" do
    it "成功すると申請が作られインボックスへ承認待ちが積まれる" do
      expect {
        post holiday_work_requests_url(host: tenant_host(org)), params: valid_params
      }.to change { ActsAsTenant.with_tenant(org) { HolidayWorkRequest.count } }.by(1)
      expect(response).to redirect_to(holiday_work_requests_url(host: tenant_host(org)))
    end

    it "平日は 422" do
      post holiday_work_requests_url(host: tenant_host(org)), params: valid_params(work_date: "2026-06-08") # 月曜
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "代休以外の種別は 422" do
      annual = ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :annual, organization: org) }
      post holiday_work_requests_url(host: tenant_host(org)), params: valid_params(compensation_leave_type_id: annual.id)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "無効化済みの代休種別は 422（停止した種別の再利用を防ぐ）" do
      inactive = ActsAsTenant.with_tenant(org) do
        create(:leave_type, system_type: :compensatory_leave, active: false, organization: org)
      end
      expect {
        post holiday_work_requests_url(host: tenant_host(org)),
             params: valid_params(compensation_leave_type_id: inactive.id)
      }.not_to(change { ActsAsTenant.with_tenant(org) { HolidayWorkRequest.count } })
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "代休種別 未選択（blank）は 404 でなく 422" do
      post holiday_work_requests_url(host: tenant_host(org)),
           params: valid_params(compensation_leave_type_id: "")
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "manager 未設定なら alert で一覧へ" do
      ActsAsTenant.with_tenant(org) { user.update!(manager: nil) }
      post holiday_work_requests_url(host: tenant_host(org)), params: valid_params
      expect(response).to redirect_to(holiday_work_requests_url(host: tenant_host(org)))
      follow_redirect!
      expect(response.body).to include("直属上長")
    end
  end

  describe "PATCH /holiday_work_requests/:id/cancel" do
    it "本人の applying を取消" do
      hwr = ActsAsTenant.with_tenant(org) do
        HolidayWorkRequests::Create.call(requester: user, work_date: Date.new(2026, 6, 7),
                                         compensation_leave_type: comp, reason: "x")
      end
      patch cancel_holiday_work_request_url(hwr, host: tenant_host(org))
      expect(hwr.reload).to be_canceled
    end
  end
end
