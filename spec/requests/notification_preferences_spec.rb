# frozen_string_literal: true

require "rails_helper"

RSpec.describe "NotificationPreferences", type: :request do
  let!(:org)  { create(:organization, subdomain: "acme") }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user, email_enabled: false) } }

  describe "GET edit" do
    it "設定画面を表示する（UNP 未作成でも組織既定で描画）" do
      sign_in user
      get edit_notification_preferences_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH update" do
    it "User.email_enabled と UNP 抑制設定を同時に更新する" do
      sign_in user
      patch notification_preferences_url(host: tenant_host(org)), params: {
        user: { email_enabled: "1" },
        notification_preference: {
          quiet_hours_enabled: "1", quiet_hours_start: "22", quiet_hours_end: "7", holiday_block_enabled: "0"
        }
      }
      expect(response).to have_http_status(:see_other)
      ActsAsTenant.with_tenant(org) do
        expect(user.reload.email_enabled).to be(true)
        pref = user.notification_preference
        expect(pref.quiet_hours_enabled).to be(true)
        expect(pref.quiet_hours_start).to eq(22)
        expect(pref.quiet_hours_end).to eq(7)
        expect(pref.holiday_block_enabled).to be(false)
        expect(pref.user_id).to eq(user.id)           # サーバ権威
        expect(pref.organization_id).to eq(org.id)    # サーバ権威
      end
    end

    it "UNP の user_id/organization_id は params で乗っ取れない（サーバ権威）" do
      other = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in user
      patch notification_preferences_url(host: tenant_host(org)), params: {
        user: { email_enabled: "0" },
        notification_preference: { user_id: other.id, organization_id: 999_999,
                                   quiet_hours_enabled: "1", quiet_hours_start: "19",
                                   quiet_hours_end: "8", holiday_block_enabled: "1" }
      }
      expect(response).to have_http_status(:see_other)
      ActsAsTenant.with_tenant(org) do
        expect(user.notification_preference.user_id).to eq(user.id)
        expect(user.notification_preference.organization_id).to eq(org.id)
      end
    end

    it "不正値（quiet_hours_start 範囲外）は部分更新せず再描画" do
      sign_in user
      patch notification_preferences_url(host: tenant_host(org)), params: {
        user: { email_enabled: "1" },
        notification_preference: { quiet_hours_enabled: "1", quiet_hours_start: "99",
                                   quiet_hours_end: "8", holiday_block_enabled: "1" }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(ActsAsTenant.with_tenant(org) { user.reload.email_enabled }).to be(false) # User も巻き戻る（単一 tx）
    end
  end
end
