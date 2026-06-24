# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin::ReasonTemplates", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:template) { ActsAsTenant.with_tenant(org) { create(:reason_template, label: "電車遅延", applies_to: :clock_change) } }

  describe "認可" do
    it "未認証はサインインへ・employee は 403・hr_admin は 200（対照）" do
      get admin_reason_templates_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get admin_reason_templates_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get admin_reason_templates_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "一覧は enum を日本語表示し inactive も並ぶ・生値を露出しない" do
      retired = ActsAsTenant.with_tenant(org) { create(:reason_template, label: "旧テンプレ", active: false) }
      get admin_reason_templates_url(host: tenant_host(org))
      expect(response.body).to include("電車遅延").and include("旧テンプレ").and include("打刻変更")
      # 生 enum 値（applies_to=clock_change）をセル文字として露出しないこと。
      # グローバルナビの href "/clock_change_requests" が部分文字列 "clock_change" を含むため、
      # セル内テキスト（>clock_change<）で判定してナビ由来の偽陽性を避ける
      expect(response.body).not_to include(">clock_change<")
    end

    it "作成できる（303 → show）" do
      post admin_reason_templates_url(host: tenant_host(org)), params: { reason_template: {
        label: "私用", template_text: "私用のため", applies_to: "both" } }
      created = ActsAsTenant.with_tenant(org) { ReasonTemplate.find_by!(label: "私用") }
      expect(response).to redirect_to(admin_reason_template_url(created, host: tenant_host(org)))
      expect(response).to have_http_status(:see_other)
    end

    it "label 重複は 422 + 件数不変" do
      expect {
        post admin_reason_templates_url(host: tenant_host(org)), params: { reason_template: {
          label: "電車遅延", template_text: "x", applies_to: "leave" } }
      }.not_to change { ActsAsTenant.with_tenant(org) { ReasonTemplate.count } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "enum 毒値は 422（500 にならない）" do
      post admin_reason_templates_url(host: tenant_host(org)), params: { reason_template: {
        label: "毒", template_text: "x", applies_to: "superuser" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "更新できる" do
      patch admin_reason_template_url(template, host: tenant_host(org)), params: { reason_template: {
        label: "電車遅延", template_text: "電車遅延のため出社が遅れました", applies_to: "clock_change" } }
      expect(response).to have_http_status(:see_other)
      expect(template.reload.template_text).to eq("電車遅延のため出社が遅れました")
    end

    it "permit 境界: active / organization_id を送っても無視される" do
      other_org = create(:organization)
      patch admin_reason_template_url(template, host: tenant_host(org)), params: { reason_template: {
        label: "電車遅延", template_text: "x", applies_to: "clock_change",
        active: false, organization_id: other_org.id } }
      template.reload
      expect(template.active).to be(true)
      expect(template.organization_id).to eq(org.id)
    end
  end

  describe "IDOR" do
    before { sign_in admin }

    it "他テナント id は 404" do
      foreign = ActsAsTenant.with_tenant(create(:organization)) { create(:reason_template) }
      get admin_reason_template_url(foreign, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "deactivate / activate（Deactivatable + name エイリアス）" do
    before { sign_in admin }

    it "無効化 → flash に label が表示される（record.name 契約の固定）" do
      patch deactivate_admin_reason_template_url(template, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(template.reload.active).to be(false)
      follow_redirect!
      expect(response.body).to include("電車遅延 を無効化しました")
    end

    it "再有効化できる" do
      ActsAsTenant.with_tenant(org) { template.update!(active: false) }
      patch activate_admin_reason_template_url(template, host: tenant_host(org))
      expect(template.reload.active).to be(true)
    end
  end
end
