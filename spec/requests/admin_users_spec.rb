require "rails_helper"

RSpec.describe "Admin::Users", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }

  describe "GET /admin/users" do
    it "未認証は devise のサインインへリダイレクト（外殻ゲートより前に認証が走る）" do
      get admin_users_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))
    end

    it "hr_admin は一覧を見られる（inactive も並ぶ）" do
      retired = ActsAsTenant.with_tenant(org) { create(:user, name: "退職 済子", active: false) }
      sign_in admin
      get admin_users_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(admin.name).and include(retired.name)
    end

    it "employee は 403（hr_admin なら同一リクエストが 200 になる対照とペア）" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get admin_users_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)
    end

    it "manager も 403" do
      manager = ActsAsTenant.with_tenant(org) { create(:user, :manager_role) }
      sign_in manager
      get admin_users_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)
    end

    it "employee は write 系（PATCH update）も 403" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      target   = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      patch admin_user_url(target, host: tenant_host(org)), params: { user: { name: "x" } }
      expect(response).to have_http_status(:forbidden)
      expect(target.reload.name).not_to eq("x")
    end
  end

  describe "IDOR（他テナント id は 404）" do
    let!(:other_org)  { create(:organization, subdomain: "globex") }
    let!(:other_user) { ActsAsTenant.with_tenant(other_org) { create(:user) } }

    before { sign_in admin }

    it "show / update / deactivate / resend_invitation のすべてで 404" do
      get admin_user_url(other_user, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)

      patch admin_user_url(other_user, host: tenant_host(org)), params: { user: { name: "x" } }
      expect(response).to have_http_status(:not_found)

      patch deactivate_admin_user_url(other_user, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(other_user.reload.active).to be(true) # 書き込み副作用なし

      patch resend_invitation_admin_user_url(other_user, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(other_user.reload.reset_password_token).to be_nil # 書き込み副作用なしまで確認
    end
  end

  describe "POST /admin/users（招待つき作成・0b-1 設計 §2）" do
    before { sign_in admin }

    let(:valid_params) do
      { user: { name: "新人 一郎", email: "newbie@example.com", employee_code: "A-100",
                role: "employee", exempt_from_overtime: "0" } }
    end

    it "パスワードなしで作成され、招待メールが 1 通飛ぶ" do
      expect {
        post admin_users_url(host: tenant_host(org)), params: valid_params
      }.to change { ActionMailer::Base.deliveries.count }.by(1)
        .and change { ActsAsTenant.with_tenant(org) { User.count } }.by(1)
      created = ActsAsTenant.with_tenant(org) { User.order(:id).last }
      expect(response).to redirect_to(admin_user_url(created, host: tenant_host(org)))
    end

    it "招待メールの URL は組織サブドメイン込み" do
      expect {
        post admin_users_url(host: tenant_host(org)), params: valid_params
      }.to change { ActionMailer::Base.deliveries.count }.by(1)
      expect(ActionMailer::Base.deliveries.last.body.encoded).to include("acme.example.com")
    end

    it "バリデーション NG の作成ではメールが飛ばない（送付タイミングの固定）" do
      invalid = { user: valid_params[:user].merge(email: "") }
      expect {
        post admin_users_url(host: tenant_host(org)), params: invalid
      }.not_to change { ActionMailer::Base.deliveries.count }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "メール送信失敗でも登録は完了し、alert で再送へ誘導（500 にしない）" do
      allow_any_instance_of(User).to receive(:send_invitation_instructions)
        .and_raise(Net::SMTPFatalError.new("552"))
      expect {
        post admin_users_url(host: tenant_host(org)), params: valid_params
      }.to change { ActsAsTenant.with_tenant(org) { User.count } }.by(1)
      expect(response).to redirect_to(admin_user_url(
        ActsAsTenant.with_tenant(org) { User.order(:id).last }, host: tenant_host(org)))
      expect(flash[:alert]).to include("再送")
    end
  end

  describe "PATCH /admin/users/:id（0b-1 設計 §0 permit 境界・§2-6）" do
    let!(:member) { ActsAsTenant.with_tenant(org) { create(:user) } }

    before { sign_in admin }

    it "role / manager_id / exempt_from_overtime を変更できる（Admin 限定 permit・redirect は 303）" do
      boss = ActsAsTenant.with_tenant(org) { create(:user, :manager_role) }
      patch admin_user_url(member, host: tenant_host(org)),
            params: { user: { role: "manager", manager_id: boss.id, exempt_from_overtime: "1" } }
      expect(response).to have_http_status(:see_other)
      member.reload
      expect(member.role).to eq("manager")
      expect(member.manager_id).to eq(boss.id)
      expect(member.exempt_from_overtime).to be(true)
    end

    it "active と organization_id は permit されない（無視される）" do
      other_org = create(:organization)
      patch admin_user_url(member, host: tenant_host(org)),
            params: { user: { name: "改名", active: "false", organization_id: other_org.id } }
      member.reload
      expect(member.name).to eq("改名")
      expect(member.active).to be(true)
      expect(member.organization_id).to eq(org.id)
    end

    it "不正な role 値は 422（ArgumentError 500 にしない）" do
      patch admin_user_url(member, host: tenant_host(org)), params: { user: { role: "superadmin" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(member.reload.role).to eq("employee")
    end

    it "未受諾ユーザーのメール変更時は flash で再送を促す" do
      patch admin_user_url(member, host: tenant_host(org)),
            params: { user: { email: "corrected@example.com" } }
      expect(flash[:notice]).to include("再送")
    end

    it "受諾済み（sign_in_count > 0）ユーザーのメール変更では再送を促さない" do
      received = ActsAsTenant.with_tenant(org) { create(:user, sign_in_count: 1) }
      patch admin_user_url(received, host: tenant_host(org)),
            params: { user: { email: "changed@example.com" } }
      expect(flash[:notice]).not_to include("再送")
    end

    it "未受諾ユーザーの name のみ変更では再送を促さない（email_previously_changed? 側の固定）" do
      patch admin_user_url(member, host: tenant_host(org)), params: { user: { name: "改名 のみ" } }
      expect(flash[:notice]).not_to include("再送")
    end

    it "ガード違反（最後の hr_admin 降格）は 422 + 状態不変 + メッセージ表示" do
      patch admin_user_url(admin, host: tenant_host(org)), params: { user: { role: "employee" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(admin.reload.role).to eq("hr_admin")
      expect(response.body).to include("組織最後の管理者は降格・無効化できません")
    end
  end

  describe "PATCH resend_invitation（0b-1 設計 §2-4/2-5）" do
    include ActiveSupport::Testing::TimeHelpers

    let!(:invited) { ActsAsTenant.with_tenant(org) { create(:user) } } # sign_in_count 0

    before { sign_in admin }

    it "未受諾ユーザーへ再送できる（PATCH 後の redirect は 303 — Turbo がメソッドを保持しない）" do
      expect {
        patch resend_invitation_admin_user_url(invited, host: tenant_host(org))
      }.to change { ActionMailer::Base.deliveries.count }.by(1)
      expect(response).to have_http_status(:see_other)
      expect(invited.reload.reset_password_token).to be_present
    end

    it "再送のメール送信失敗は 500 にせず alert + リダイレクト（登録系と同型の救済）" do
      allow_any_instance_of(User).to receive(:send_invitation_instructions)
        .and_raise(Net::SMTPFatalError.new("552"))
      patch resend_invitation_admin_user_url(invited, host: tenant_host(org))
      expect(response).to redirect_to(admin_users_url(host: tenant_host(org)))
      expect(flash[:alert]).to include("再送に失敗")
    end

    it "再送で旧トークンは失効する（旧 raw トークンでのパスワード設定は不変）" do
      old_raw = ActsAsTenant.with_tenant(org) { invited.send_invitation_instructions }
      patch resend_invitation_admin_user_url(invited, host: tenant_host(org))

      # 招待受諾者は未ログインが実態（ログイン済みは require_no_authentication の
      # already_authenticated でリダイレクトされ、トークン消費経路に到達しない）
      sign_out :user
      put user_password_url(host: tenant_host(org)),
          params: { user: { reset_password_token: old_raw,
                            password: "newpassword1!", password_confirmation: "newpassword1!" } }
      expect(invited.reload.valid_password?("newpassword1!")).to be(false)
    end

    it "期限切れ（6 時間超）のトークンは消費できない" do
      raw = ActsAsTenant.with_tenant(org) { invited.send_invitation_instructions }
      sign_out :user # 同上: 招待受諾者は未ログインが実態
      travel 7.hours do
        put user_password_url(host: tenant_host(org)),
            params: { user: { reset_password_token: raw,
                              password: "newpassword1!", password_confirmation: "newpassword1!" } }
        expect(invited.reload.valid_password?("newpassword1!")).to be(false)
      end
    end

    it "ログイン済み（sign_in_count > 0）への直接 PATCH は 403 — トークン強制発行を塞ぐ" do
      received = ActsAsTenant.with_tenant(org) { create(:user, sign_in_count: 1) }
      expect {
        patch resend_invitation_admin_user_url(received, host: tenant_host(org))
      }.not_to change { ActionMailer::Base.deliveries.count }
      expect(response).to have_http_status(:forbidden)
    end

    it "inactive ユーザーへの直接 PATCH は 403・メール 0 通" do
      retired = ActsAsTenant.with_tenant(org) { create(:user, active: false) }
      expect {
        patch resend_invitation_admin_user_url(retired, host: tenant_host(org))
      }.not_to change { ActionMailer::Base.deliveries.count }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "物理削除なし（0b-1 設計 §0 の regression 防止）" do
    it "DELETE はルーティングされない" do
      sign_in admin
      expect {
        delete admin_user_url(admin, host: tenant_host(org))
      }.to raise_error(ActionController::RoutingError)
    end
  end

  describe "PATCH deactivate / activate（0b-1 設計 §3 ガードとの連動）" do
    before { sign_in admin }

    it "部下なし社員は無効化でき、再有効化もできる（PATCH 後の redirect は 303）" do
      member = ActsAsTenant.with_tenant(org) { create(:user) }
      patch deactivate_admin_user_url(member, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(member.reload.active).to be(false)

      patch activate_admin_user_url(member, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(member.reload.active).to be(true)
    end

    it "最後の hr_admin の無効化はガードが拒否し、状態不変 + alert にメッセージ" do
      patch deactivate_admin_user_url(admin, host: tenant_host(org))
      expect(admin.reload.active).to be(true)
      expect(flash[:alert]).to include("組織最後の管理者は降格・無効化できません")
    end

    it "無効化された元・最後の hr_admin も、別のアクティブ hr_admin がいれば成立する（ガード①相互作用）" do
      second = ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) }
      patch deactivate_admin_user_url(admin, host: tenant_host(org))
      expect(admin.reload.active).to be(false) # second がいるので許可

      # admin は inactive になり active_for_authentication? = false → 自分では操作不可。
      # 別のアクティブ hr_admin (second) が代わりに再有効化する（実運用と同じ経路）
      sign_in second
      patch activate_admin_user_url(admin, host: tenant_host(org))
      expect(admin.reload.active).to be(true) # 再有効化にガードはない
    end

    it "非アクティブ上長を持つユーザーの再有効化はガード④が拒否し alert 表示" do
      boss = ActsAsTenant.with_tenant(org) { create(:user, :manager_role) }
      member = ActsAsTenant.with_tenant(org) { create(:user, manager: boss) }
      ActsAsTenant.with_tenant(org) do
        member.update!(active: false)
        boss.update!(active: false)
      end
      patch activate_admin_user_url(member, host: tenant_host(org))
      expect(member.reload.active).to be(false)
      expect(flash[:alert]).to include("在籍中")
    end
  end
end
