require "rails_helper"

RSpec.describe "パスワードリセットのテナント分離（SPEC §3.2(3)）", type: :request do
  include ActiveJob::TestHelper

  let!(:acme)   { create(:organization, subdomain: "acme") }
  let!(:globex) { create(:organization, subdomain: "globex") }
  let!(:acme_user) do
    ActsAsTenant.with_tenant(acme) { create(:user, email: "shared@example.com") }
  end
  let!(:globex_user) do
    ActsAsTenant.with_tenant(globex) { create(:user, email: "shared@example.com") }
  end

  it "acme での要求は acme ユーザーのみトークン更新・メール 1 通・URL は acme サブドメイン" do
    expect {
      perform_enqueued_jobs do
        post user_password_url(host: tenant_host(acme)),
             params: { user: { email: "shared@example.com" } }
      end
    }.to change { ActionMailer::Base.deliveries.count }.by(1)

    expect(acme_user.reload.reset_password_token).to be_present
    expect(globex_user.reload.reset_password_token).to be_nil

    mail_body = ActionMailer::Base.deliveries.last.body.decoded
    expect(mail_body).to include("acme.example.com")
    expect(mail_body).not_to include("globex.example.com")
  end

  it "acme で発行したトークンは globex サブドメインで消費できない" do
    raw_token = ActsAsTenant.with_tenant(acme) { acme_user.send_reset_password_instructions }

    put user_password_url(host: tenant_host(globex)),
        params: { user: { reset_password_token: raw_token,
                          password: "newpassword1!", password_confirmation: "newpassword1!" } }

    expect(acme_user.reload.valid_password?("newpassword1!")).to be(false)
  end

  it "トークン消費（リセット成功）でセッション ID が再生成される（固定化対策・設計 §5）" do
    # サインインページの GET は test 環境（CSRF 無効）でセッションを書かない →
    # 未認証 root へのアクセス（flash 書込み）で session_id 込みのセッションを確立する
    get root_url(host: tenant_host(acme))
    old_session_cookie = cookies["_gatcha_session"]
    old_session_id     = session["session_id"]
    expect(old_session_cookie).to be_present # nil 同士の比較で空振りしないこと
    expect(old_session_id).to be_present

    raw_token = ActsAsTenant.with_tenant(acme) { acme_user.send_reset_password_instructions }
    put user_password_url(host: tenant_host(acme)),
        params: { user: { reset_password_token: raw_token,
                          password: "newpassword1!", password_confirmation: "newpassword1!" } }

    # CookieStore は書込みごとに暗号文が変わるため cookie 比較は必要条件 —
    # 固定化対策の本体は session_id の付け替え（Warden#set_user の renew）を直接検証する。
    # renew は commit 時に新 sid を cookie へ書く（リクエスト側 session オブジェクトは
    # 旧 sid のまま）ため、後続リクエストで committed な session_id を読む
    expect(cookies["_gatcha_session"]).not_to eq(old_session_cookie)

    get root_url(host: tenant_host(acme)) # auto sign-in 済み → 200（committed cookie を読む）
    expect(response).to have_http_status(:ok)
    expect(session["session_id"]).not_to eq(old_session_id)
  end

  it "正規テナントではトークン消費が成功する" do
    raw_token = ActsAsTenant.with_tenant(acme) { acme_user.send_reset_password_instructions }

    put user_password_url(host: tenant_host(acme)),
        params: { user: { reset_password_token: raw_token,
                          password: "newpassword1!", password_confirmation: "newpassword1!" } }

    expect(acme_user.reload.valid_password?("newpassword1!")).to be(true)
  end
end
