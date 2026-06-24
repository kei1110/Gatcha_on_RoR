# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ClockChangeRequests", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:boss) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role) } }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user, manager: boss) } }
  let!(:record) do
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, :done, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 1), clock_out: Time.utc(2026, 6, 1, 9))
    end
  end

  before { sign_in user }

  describe "GET new" do
    it "自分の記録には新規申請フォームを表示" do
      get new_clock_change_request_url(host: tenant_host(org), attendance_record_id: record.id)
      expect(response).to have_http_status(:ok)
    end

    it "他人の記録は 404" do
      other = ActsAsTenant.with_tenant(org) { create(:user) }
      others_record = ActsAsTenant.with_tenant(org) { create(:attendance_record, :done, user: other) }
      get new_clock_change_request_url(host: tenant_host(org), attendance_record_id: others_record.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET index" do
    it "新規申請リンクが出る（new への動線・LR/HWR と対称）" do
      get clock_change_requests_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(new_clock_change_request_path)
      expect(response.body).to include("新規申請")
    end
  end

  describe "POST create" do
    it "申請を作成し original_* をサーバ snapshot（client 値を無視）" do
      expect {
        post clock_change_requests_url(host: tenant_host(org)),
             params: { clock_change_request: { attendance_record_id: record.id, change_type: "clock_in",
                                               new_clock_in: "2026-06-01T09:00", reason: "修正",
                                               original_clock_in: "1999-01-01T00:00" } }
      }.to change { ActsAsTenant.with_tenant(org) { ClockChangeRequest.count } }.by(1)
      ccr = ActsAsTenant.with_tenant(org) { ClockChangeRequest.last }
      expect(ccr.original_clock_in).to eq(record.clock_in)   # client の 1999 を無視
      expect(ccr.new_clock_in.in_time_zone(org.time_zone).strftime("%H:%M")).to eq("09:00")  # 組織 TZ parse
    end
  end

  describe "PATCH cancel" do
    it "本人申請を取り消す" do
      ccr = ActsAsTenant.with_tenant(org) do
        ClockChangeRequests::Create.call(requester: user, attendance_record: record, change_type: "clock_in",
                                         new_clock_in: Time.utc(2026, 6, 1, 0), new_clock_out: nil, reason: "x")
      end
      patch cancel_clock_change_request_url(ccr, host: tenant_host(org))
      ActsAsTenant.with_tenant(org) { expect(ccr.reload.approval_status).to eq("canceled") }
    end
  end
end
