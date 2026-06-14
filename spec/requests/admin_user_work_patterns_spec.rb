# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin::UserWorkPatterns", type: :request do
  let!(:org)     { create(:organization, subdomain: "acme") }
  let!(:admin)   { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:target)  { ActsAsTenant.with_tenant(org) { create(:user, name: "田中太郎") } }
  let!(:pattern) { ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "日勤") } }

  def create_assignment(**attrs)
    ActsAsTenant.with_tenant(org) do
      create(:user_work_pattern, { user: target, work_pattern: pattern,
                                   start_date: Date.new(2026, 4, 1) }.merge(attrs))
    end
  end

  describe "認可（403 対照ペア・未認証）" do
    it "未認証はサインインへリダイレクト" do
      get new_admin_user_user_work_pattern_url(target, host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))
    end

    it "employee は 403・hr_admin は同一リクエストが 200（対照）" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get new_admin_user_user_work_pattern_url(target, host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get new_admin_user_user_work_pattern_url(target, host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end

    it "employee は write 系（POST create）も 403・件数不変" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      expect {
        post admin_user_user_work_patterns_url(target, host: tenant_host(org)),
             params: { user_work_pattern: { work_pattern_id: pattern.id, start_date: "2026-04-01" } }
      }.not_to change { ActsAsTenant.with_tenant(org) { UserWorkPattern.count } }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "IDOR（policy_scope 経由 find の一本道）" do
    before { sign_in admin }

    it "他テナントの user_id は 404" do
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:user) }
      get new_admin_user_user_work_pattern_url(outsider, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
    end

    it "他テナントの割当 id は 404" do
      other_assignment = ActsAsTenant.with_tenant(create(:organization)) { create(:user_work_pattern) }
      patch admin_user_user_work_pattern_url(target, other_assignment, host: tenant_host(org)),
            params: { user_work_pattern: { start_date: "2026-01-01" } }
      expect(response).to have_http_status(:not_found)
    end

    it "自テナントでも別ユーザーの割当 id は 404（user ネストの絞り）" do
      other_user_assignment = ActsAsTenant.with_tenant(org) { create(:user_work_pattern) }
      patch admin_user_user_work_pattern_url(target, other_user_assignment, host: tenant_host(org)),
            params: { user_work_pattern: { start_date: "2026-01-01" } }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "作成できる（303 → 社員詳細）" do
      post admin_user_user_work_patterns_url(target, host: tenant_host(org)),
           params: { user_work_pattern: { work_pattern_id: pattern.id, start_date: "2026-04-01" } }
      expect(response).to redirect_to(admin_user_url(target, host: tenant_host(org)))
      expect(response).to have_http_status(:see_other)
      created = ActsAsTenant.with_tenant(org) { UserWorkPattern.order(:id).last }
      expect(created.user_id).to eq(target.id)
      expect(created.end_date).to be_nil
    end

    it "重複期間は 422 + 衝突相手期間入り文言で再描画" do
      create_assignment(end_date: Date.new(2026, 6, 30))
      post admin_user_user_work_patterns_url(target, host: tenant_host(org)),
           params: { user_work_pattern: { work_pattern_id: pattern.id, start_date: "2026-05-01" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("重複しています").and include("2026-04-01")
    end

    it "更新できる（303）" do
      assignment = create_assignment(end_date: Date.new(2026, 6, 30))
      patch admin_user_user_work_pattern_url(target, assignment, host: tenant_host(org)),
            params: { user_work_pattern: { work_pattern_id: pattern.id,
                                           start_date: "2026-04-01", end_date: "2026-05-31" } }
      expect(response).to have_http_status(:see_other)
      expect(assignment.reload.end_date).to eq(Date.new(2026, 5, 31))
    end

    it "日付逆転は 422" do
      assignment = create_assignment(end_date: Date.new(2026, 6, 30))
      patch admin_user_user_work_pattern_url(target, assignment, host: tenant_host(org)),
            params: { user_work_pattern: { work_pattern_id: pattern.id,
                                           start_date: "2026-04-01", end_date: "2026-03-01" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "permit 境界: user_id / active / organization_id を送っても無視される" do
      other_user = ActsAsTenant.with_tenant(org) { create(:user) }
      post admin_user_user_work_patterns_url(target, host: tenant_host(org)),
           params: { user_work_pattern: { work_pattern_id: pattern.id, start_date: "2026-04-01",
                                          user_id: other_user.id, active: false, organization_id: 0 } }
      created = ActsAsTenant.with_tenant(org) { UserWorkPattern.order(:id).last }
      expect(created.user_id).to eq(target.id)
      expect(created.active).to be(true)
      expect(created.organization_id).to eq(org.id)
    end

    it "パターン未選択は 422（プロンプト空値 → presence）" do
      post admin_user_user_work_patterns_url(target, host: tenant_host(org)),
           params: { user_work_pattern: { work_pattern_id: "", start_date: "2026-04-01" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "exclusion 競合（TOCTOU）は 422 + 競合文言で再描画" do
      allow_any_instance_of(UserWorkPattern).to receive(:save)
        .and_raise(ActiveRecord::ExclusionViolation)
      post admin_user_user_work_patterns_url(target, host: tenant_host(org)),
           params: { user_work_pattern: { work_pattern_id: pattern.id, start_date: "2026-04-01" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("他の操作と競合しました")
    end
  end

  describe "deactivate / activate" do
    before { sign_in admin }

    it "無効化できる（303 → 社員詳細）" do
      assignment = create_assignment
      patch deactivate_admin_user_user_work_pattern_url(target, assignment, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(assignment.reload.active).to be(false)
    end

    it "再有効化できる" do
      assignment = create_assignment(active: false)
      patch activate_admin_user_user_work_pattern_url(target, assignment, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(assignment.reload.active).to be(true)
    end

    it "重複する割当の再有効化は 303 + alert（衝突相手期間入り文言）・active のまま不変" do
      inactive = create_assignment(end_date: Date.new(2026, 5, 31), active: false)
      create_assignment(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 12, 31))
      patch activate_admin_user_user_work_pattern_url(target, inactive, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(inactive.reload.active).to be(false)
      follow_redirect!
      expect(response.body).to include("重複しています")
    end
  end

  describe "社員詳細の割当セクション（0b-4 設計 §5）" do
    before { sign_in admin }

    it "未割当なら警告バナー・有効割当があれば消える（対照ペア）" do
      get admin_user_url(target, host: tenant_host(org))
      expect(response.body).to include("現在有効な勤務パターン割当がありません")

      create_assignment(start_date: org.today - 30) # 今日をカバーする有効割当
      get admin_user_url(target, host: tenant_host(org))
      expect(response.body).not_to include("現在有効な勤務パターン割当がありません")
    end

    it "過去割当のみではバナーが出る（述語は effective_on — 「割当行ゼロ」ではない）" do
      create_assignment(start_date: Date.new(2020, 1, 1), end_date: Date.new(2020, 12, 31))
      get admin_user_url(target, host: tenant_host(org))
      expect(response.body).to include("現在有効な勤務パターン割当がありません")
    end

    it "一覧は状態バッジ・無期限表示・無効パターン名の（無効）付記を出す" do
      create_assignment(start_date: org.today - 30) # 有効・無期限
      retired = ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "旧早番") }
      ActsAsTenant.with_tenant(org) do
        create(:user_work_pattern, user: target, work_pattern: retired,
               start_date: Date.new(2020, 1, 1), end_date: Date.new(2020, 12, 31))
        retired.update!(active: false) # 過去のみの割当ゆえガードを通る
      end
      get admin_user_url(target, host: tenant_host(org))
      expect(response.body).to include("有効").and include("過去")
        .and include("（無期限）").and include("旧早番（無効）")
    end

    it "未来割当は「未来」バッジで表示される" do
      create_assignment(start_date: org.today + 30)
      get admin_user_url(target, host: tenant_host(org))
      expect(response.body).to include("未来")
    end

    it "new フォームの選択肢に inactive パターンは出ない" do
      ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "旧夜勤", active: false) }
      get new_admin_user_user_work_pattern_url(target, host: tenant_host(org))
      expect(response.body).to include("日勤")
      expect(response.body).not_to include("旧夜勤")
    end

    it "edit フォームは無効パターン参照中のみ現在値を（無効）付きで選択肢に含める" do
      retired = ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "旧早番") }
      assignment = ActsAsTenant.with_tenant(org) do
        a = create(:user_work_pattern, user: target, work_pattern: retired,
                   start_date: Date.new(2020, 1, 1), end_date: Date.new(2020, 12, 31))
        retired.update!(active: false)
        a
      end
      get edit_admin_user_user_work_pattern_url(target, assignment, host: tenant_host(org))
      expect(response.body).to include("旧早番（無効）")
    end
  end
end
