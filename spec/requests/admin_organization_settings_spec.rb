require "rails_helper"

RSpec.describe "Admin::OrganizationSettings", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") } # fiscal_year_end_month 既定 3
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }

  describe "認可" do
    it "未認証はサインインへ・employee は 403・hr_admin は 200（対照）" do
      get edit_admin_organization_setting_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get edit_admin_organization_setting_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get edit_admin_organization_setting_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end
  end

  describe "lazy 生成（Organization#setting 経由）" do
    before { sign_in admin }

    it "初回 edit で設定行が生成され、2 回目は増えない（対照）" do
      expect {
        get edit_admin_organization_setting_url(host: tenant_host(org))
      }.to change { OrganizationSetting.unscoped.where(organization: org).count }.from(0).to(1)

      expect {
        get edit_admin_organization_setting_url(host: tenant_host(org))
      }.not_to change { OrganizationSetting.unscoped.count }
    end
  end

  describe "更新（hr_admin）" do
    before { sign_in admin }

    it "決算月変更で既存カレンダーの fiscal_year の値が実際に変わる + 実変更数 flash（Pragma Critical の唯一の網）" do
      calendar = ActsAsTenant.with_tenant(org) { create(:company_calendar, date: Date.new(2026, 1, 15)) }
      expect(calendar.fiscal_year).to eq("2025")

      patch admin_organization_setting_url(host: tenant_host(org)), params: {
        organization: { fiscal_year_end_month: 12 },
        organization_setting: { closing_day: 31, submit_deadline_days: 5 }
      }
      expect(response).to redirect_to(edit_admin_organization_setting_url(host: tenant_host(org)))
      expect(response).to have_http_status(:see_other)
      expect(calendar.reload.fiscal_year).to eq("2026")
      follow_redirect!
      expect(response.body).to include("会社カレンダー 1 件の年度を再計算しました")
    end

    it "決算月が変わらない保存は再計算文言を出さない（対照）" do
      calendar = ActsAsTenant.with_tenant(org) { create(:company_calendar, date: Date.new(2026, 1, 15)) }

      patch admin_organization_setting_url(host: tenant_host(org)), params: {
        organization: { fiscal_year_end_month: 3 },
        organization_setting: { closing_day: 25, submit_deadline_days: 5 }
      }
      expect(calendar.reload.fiscal_year).to eq("2025")
      follow_redirect!
      expect(response.body).to include("設定を保存しました")
      expect(response.body).not_to include("再計算しました")
    end

    it "失敗 422: 両モデルのエラーが表示され入力保持" do
      patch admin_organization_setting_url(host: tenant_host(org)), params: {
        organization: { fiscal_year_end_month: 13 },
        organization_setting: { closing_day: 0, submit_deadline_days: 5 }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("年度終了月").and include("締め日")
      expect(org.reload.fiscal_year_end_month).to eq(3) # 未保存
    end

    it "permit 境界（allowlist）: 編集可 3 項目以外は全て無視される" do
      patch admin_organization_setting_url(host: tenant_host(org)), params: {
        organization: { fiscal_year_end_month: 12, subdomain: "evil", active: false,
                        time_zone: "UTC", name: "乗っ取り" },
        organization_setting: { closing_day: 25, submit_deadline_days: 5, organization_id: 0 }
      }
      expect(response).to have_http_status(:see_other)
      org.reload
      expect(org.subdomain).to eq("acme")
      expect(org.active).to be(true)
      expect(org.time_zone).to eq("Asia/Tokyo")
      expect(org.fiscal_year_end_month).to eq(12) # 許可項目だけ通る
      setting = OrganizationSetting.unscoped.find_by!(organization: org)
      expect(setting.closing_day).to eq(25)
      expect(setting.organization_id).to eq(org.id)
    end

    it "422 再描画でも設定タブのハイライトが維持される（singular の PATCH パス対策）" do
      patch admin_organization_setting_url(host: tenant_host(org)), params: {
        organization: { fiscal_year_end_month: 13 },
        organization_setting: { closing_day: 31, submit_deadline_days: 5 }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include(%(border-b-2 border-gray-800 font-bold" href="/admin/organization_setting/edit"))
    end
  end
end
