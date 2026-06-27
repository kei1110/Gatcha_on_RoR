# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Notifications", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:owner) { ActsAsTenant.with_tenant(org) { create(:user, name: "本人") } }
  let!(:other) { ActsAsTenant.with_tenant(org) { create(:user, name: "他人") } }

  describe "GET index" do
    it "自分宛のみ一覧する（他人宛は出さない）" do
      ActsAsTenant.with_tenant(org) do
        create(:notification, target_user: owner, title: "自分の通知")
        create(:notification, target_user: other, title: "他人の通知")
      end
      sign_in owner
      get notifications_url(host: tenant_host(org))
      expect(response.body).to include("自分の通知")
      expect(response.body).not_to include("他人の通知")
    end
  end

  describe "PATCH update（既読化）" do
    it "自分宛の通知を既読にする" do
      n = ActsAsTenant.with_tenant(org) { create(:notification, target_user: owner) }
      sign_in owner
      patch notification_url(n, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(ActsAsTenant.with_tenant(org) { n.reload.read_at }).to be_present
    end

    it "他人宛の既読化は 404・read_at 不変（IDOR）" do
      n = ActsAsTenant.with_tenant(org) { create(:notification, target_user: other) }
      sign_in owner
      patch notification_url(n, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(ActsAsTenant.with_tenant(org) { n.reload.read_at }).to be_nil
    end

    it "他テナントの通知の既読化は 404（acts_as_tenant default_scope）" do
      other_org = create(:organization)
      n = ActsAsTenant.with_tenant(other_org) { create(:notification) }
      sign_in owner
      patch notification_url(n, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
    end
  end
end
