require "rails_helper"

RSpec.describe "テナント整合突合（Warden 一点防御）", type: :request do
  let!(:acme)   { create(:organization, subdomain: "acme") }
  let!(:globex) { create(:organization, subdomain: "globex") }
  let!(:acme_user) { ActsAsTenant.with_tenant(acme) { create(:user) } }

  it "acme のユーザーで globex にアクセスするとサインインへ戻される" do
    sign_in acme_user
    get root_url(host: tenant_host(globex))
    expect(response).to redirect_to(new_user_session_url(host: tenant_host(globex)))
  end

  it "不一致検出時はセッションが破棄される（401 偽装でなく実破棄）" do
    sign_in acme_user
    get root_url(host: tenant_host(globex)) # ここで突合 → logout
    get root_url(host: tenant_host(acme))   # 正規テナントでも再ログイン要求
    expect(response).to redirect_to(new_user_session_url(host: tenant_host(acme)))
  end

  it "不一致検出時は remember cookie も失効する" do
    # 実ログインで remember を発行（remember_created_at + 署名 cookie）
    post user_session_url(host: tenant_host(acme)),
         params: { user: { email: acme_user.email, password: "password123!", remember_me: "1" } }
    remember_cookie = cookies["remember_user_token"]
    expect(remember_cookie).to be_present
    expect(acme_user.reload.remember_created_at).to be_present

    # cookie 復元経路は default scope で他テナント解決不可（hook 前段で遮断）。
    # hook が働くのは middleware 層で user が set される経路 — sign_in helper で再現。
    # remember cookie は host-only ゆえ jar から globex へは送られない —
    # cookie_jar.delete はリクエストに cookie が無いと no-op のため明示ヘッダで同送する
    sign_in acme_user
    get root_url(host: tenant_host(globex)), # hook 発火 → logout → before_logout(forget_me!)
        headers: { "Cookie" => "remember_user_token=#{Rack::Utils.escape(remember_cookie)}" }

    # 応答で cookie が失効され、サーバ側でも remember トークンが無効化される
    # （expire_all_remember_me_on_sign_out = true → 発行済み cookie は全ホストで死ぬ）
    expect(response.headers["Set-Cookie"].to_s).to match(/remember_user_token=;/)
    expect(response).to redirect_to(new_user_session_url(host: tenant_host(globex)))
    expect(acme_user.reload.remember_created_at).to be_nil
  end

  it "remember cookie はホスト限定で発行される（親ドメインに広がらない）" do
    post user_session_url(host: tenant_host(acme)),
         params: { user: { email: acme_user.email, password: "password123!", remember_me: "1" } }
    set_cookie = response.headers["Set-Cookie"].to_s
    expect(set_cookie).to include("remember_user_token")
    expect(set_cookie.downcase).not_to include("domain=")
  end
end
