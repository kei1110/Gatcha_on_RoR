# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin::LeaveTypes", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:leave_type) { ActsAsTenant.with_tenant(org) { create(:leave_type, name: "有給休暇", system_type: :annual) } }

  describe "認可" do
    it "未認証はサインインへ・employee は 403・hr_admin は 200（対照）" do
      get admin_leave_types_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get admin_leave_types_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get admin_leave_types_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "一覧は enum を日本語表示し inactive も並ぶ" do
      retired = ActsAsTenant.with_tenant(org) { create(:leave_type, name: "旧夏季休暇", active: false) }
      get admin_leave_types_url(host: tenant_host(org))
      expect(response.body).to include("有給休暇").and include("旧夏季休暇")
      expect(response.body).not_to include("annual") # enum 生値を露出しない（i18n 表示ヘルパ）
    end

    it "作成できる" do
      post admin_leave_types_url(host: tenant_host(org)), params: { leave_type: {
        name: "夏季休暇", system_type: "other", allow_half_day: "1" } }
      created = ActsAsTenant.with_tenant(org) { LeaveType.find_by!(name: "夏季休暇") }
      expect(response).to redirect_to(admin_leave_type_url(created, host: tenant_host(org)))
    end

    it "enum 不正値は 422（ArgumentError 500 にしない）" do
      patch admin_leave_type_url(leave_type, host: tenant_host(org)),
            params: { leave_type: { system_type: "bogus" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(leave_type.reload.system_type).to eq("annual")
    end

    it "permit 境界: active と organization_id は無視される" do
      other_org = create(:organization)
      patch admin_leave_type_url(leave_type, host: tenant_host(org)),
            params: { leave_type: { name: "改名", active: "false", organization_id: other_org.id } }
      leave_type.reload
      expect(leave_type.name).to eq("改名")
      expect(leave_type.active).to be(true)
      expect(leave_type.organization_id).to eq(org.id)
    end

    it "無効化 → 再有効化（303・location）" do
      patch deactivate_admin_leave_type_url(leave_type, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_leave_type_url(leave_type, host: tenant_host(org)))
      expect(leave_type.reload.active).to be(false)

      patch activate_admin_leave_type_url(leave_type, host: tenant_host(org))
      expect(leave_type.reload.active).to be(true)
    end
  end

  describe "IDOR（全 member アクション 404）" do
    let!(:other) { ActsAsTenant.with_tenant(create(:organization, subdomain: "globex")) { create(:leave_type) } }

    before { sign_in admin }

    it "show / edit / update / deactivate / activate すべて 404・副作用なし" do
      get admin_leave_type_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      get edit_admin_leave_type_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      patch admin_leave_type_url(other, host: tenant_host(org)), params: { leave_type: { name: "x" } }
      expect(response).to have_http_status(:not_found)
      patch deactivate_admin_leave_type_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      patch activate_admin_leave_type_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(other.reload.active).to be(true)
    end
  end

  describe "物理削除なし" do
    it "DELETE はルーティングされない" do
      sign_in admin
      expect {
        delete admin_leave_type_url(leave_type, host: tenant_host(org))
      }.to raise_error(ActionController::RoutingError)
    end
  end
end
