# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin::WorkPatterns", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:pattern) { ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "日勤") } }

  describe "認可（403 対照ペア・未認証）" do
    it "未認証はサインインへリダイレクト" do
      get admin_work_patterns_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))
    end

    it "employee は 403・hr_admin は同一リクエストが 200（対照）" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get admin_work_patterns_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get admin_work_patterns_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end

    it "employee は write 系（PATCH update）も 403・状態不変" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      patch admin_work_pattern_url(pattern, host: tenant_host(org)), params: { work_pattern: { name: "x" } }
      expect(response).to have_http_status(:forbidden)
      expect(pattern.reload.name).to eq("日勤")
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "一覧は inactive も並び、conflict パターンに警告文言を出す（対照ペア）" do
      retired  = ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "旧夜勤", active: false) }
      conflict = ActsAsTenant.with_tenant(org) do
        create(:work_pattern, name: "夜勤フレックス", night_shift: true, flextime: true,
               start_time: "22:00", end_time: "07:00", core_time_start: "23:00", core_time_end: "03:00")
      end
      get admin_work_patterns_url(host: tenant_host(org))
      expect(response.body).to include("日勤").and include("旧夜勤")
      expect(response.body).to include("夜勤・フレックス併用")          # conflict 警告
      expect(response.body.scan("夜勤・フレックス併用").size).to eq(1)  # 非 conflict 行には出ない
    end

    it "作成できる（時刻は HH:MM 表示）" do
      post admin_work_patterns_url(host: tenant_host(org)), params: { work_pattern: {
        name: "早番", start_time: "07:00", end_time: "16:00",
        break_minutes: 60, standard_work_hours: 8 } }
      created = ActsAsTenant.with_tenant(org) { WorkPattern.find_by!(name: "早番") }
      expect(response).to redirect_to(admin_work_pattern_url(created, host: tenant_host(org)))
      follow_redirect!
      expect(response.body).to include("07:00").and include("16:00")
    end

    it "法定休憩違反は 422 + :base 文言表示 + 未作成" do
      expect {
        post admin_work_patterns_url(host: tenant_host(org)), params: { work_pattern: {
          name: "違反", start_time: "09:00", end_time: "19:00",
          break_minutes: 30, standard_work_hours: 9 } }
      }.not_to change { ActsAsTenant.with_tenant(org) { WorkPattern.count } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("8 時間超の勤務には 60 分以上の休憩が必要です（労基法 34 条）")
    end

    it "permit 境界: active と organization_id を送っても無視される" do
      other_org = create(:organization)
      patch admin_work_pattern_url(pattern, host: tenant_host(org)),
            params: { work_pattern: { name: "改名", active: "false", organization_id: other_org.id } }
      pattern.reload
      expect(pattern.name).to eq("改名")
      expect(pattern.active).to be(true)
      expect(pattern.organization_id).to eq(org.id)
    end

    it "無効化 → 再有効化（303・location・concern 経由）" do
      patch deactivate_admin_work_pattern_url(pattern, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_work_pattern_url(pattern, host: tenant_host(org)))
      expect(pattern.reload.active).to be(false)

      patch activate_admin_work_pattern_url(pattern, host: tenant_host(org))
      expect(pattern.reload.active).to be(true)
    end
  end

  describe "IDOR（他テナント id は全 member アクションで 404）" do
    let!(:other) { ActsAsTenant.with_tenant(create(:organization, subdomain: "globex")) { create(:work_pattern) } }

    before { sign_in admin }

    it "show / edit / update / deactivate / activate すべて 404・副作用なし" do
      get admin_work_pattern_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      get edit_admin_work_pattern_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      patch admin_work_pattern_url(other, host: tenant_host(org)), params: { work_pattern: { name: "x" } }
      expect(response).to have_http_status(:not_found)
      patch deactivate_admin_work_pattern_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      patch activate_admin_work_pattern_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(other.reload.active).to be(true)
    end
  end

  describe "物理削除なし" do
    it "DELETE はルーティングされない" do
      sign_in admin
      expect {
        delete admin_work_pattern_url(pattern, host: tenant_host(org))
      }.to raise_error(ActionController::RoutingError)
    end
  end
end
