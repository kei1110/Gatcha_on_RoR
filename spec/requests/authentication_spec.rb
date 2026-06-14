# frozen_string_literal: true

require "rails_helper"

RSpec.describe "認証のテナントスコープ（SPEC §3.2）", type: :request do
  let!(:acme)   { create(:organization, subdomain: "acme") }
  let!(:globex) { create(:organization, subdomain: "globex") }
  let!(:acme_user) do
    ActsAsTenant.with_tenant(acme) { create(:user, email: "shared@example.com", password: "password123!") }
  end
  let!(:globex_user) do
    ActsAsTenant.with_tenant(globex) { create(:user, email: "shared@example.com", password: "different456!") }
  end

  def sign_in_via_form(host:, email:, password:)
    post user_session_url(host: host),
         params: { user: { email: email, password: password } }
  end

  it "globex のフォームに acme の資格情報では認証できない" do
    sign_in_via_form(host: tenant_host(globex), email: "shared@example.com", password: "password123!")
    # 認証失敗 = サインイン画面の再描画（422）であり、root への redirect ではない
    expect(response).not_to redirect_to(root_url(host: tenant_host(globex)))
  end

  it "同一 email でも各テナントで正しい本人として認証される" do
    sign_in_via_form(host: tenant_host(globex), email: "shared@example.com", password: "different456!")
    expect(response).to redirect_to(root_url(host: tenant_host(globex)))
  end

  it "lockable の failed_attempts はテナント間で独立" do
    3.times do
      sign_in_via_form(host: tenant_host(acme), email: "shared@example.com", password: "wrong!")
    end
    expect(acme_user.reload.failed_attempts).to eq(3)
    expect(globex_user.reload.failed_attempts).to eq(0)
  end

  it "退職者（active=false）はログインできない" do
    # ガード②（部下持ち無効化ブロック）がテナントスコープのクエリを発火するため、
    # 裸のモデル更新は NoTenantSet になる（fail-closed の規約どおり）— テナント文脈で包む
    ActsAsTenant.with_tenant(acme) { acme_user.update!(active: false) }
    sign_in_via_form(host: tenant_host(acme), email: "shared@example.com", password: "password123!")
    expect(response).not_to redirect_to(root_url(host: tenant_host(acme)))
  end

  it "paranoid: 失敗応答がユーザー存在に依存しない（列挙耐性）" do
    sign_in_via_form(host: tenant_host(acme), email: "nobody@example.com", password: "x")
    status_unknown = response.status
    # フォームは入力した email をそのまま再表示する（存在有無とは無関係なエコーバック）ため
    # 入力値を正規化したうえで応答全体を比較する。それ以外の差分は全て失敗になる
    body_unknown = response.body.gsub("nobody@example.com", "EMAIL")
    sign_in_via_form(host: tenant_host(acme), email: "shared@example.com", password: "wrong!")
    expect(response.status).to eq(status_unknown)
    expect(response.body.gsub("shared@example.com", "EMAIL")).to eq(body_unknown)
  end

  describe "ログイン済みユーザーと devise 公開画面（serialize_from_session の NoTenantSet 回帰防止）" do
    let!(:user) { ActsAsTenant.with_tenant(acme) { create(:user) } }

    before do
      sign_in user
      get root_url(host: tenant_host(acme)) # 1 リクエスト目: セッション cookie を確立
    end

    it "パスワード再設定画面は 500 にならず already_authenticated でリダイレクト" do
      get new_user_password_url(host: tenant_host(acme))
      expect(response).to redirect_to(root_url(host: tenant_host(acme)))
    end

    it "ログイン画面も同様" do
      get new_user_session_url(host: tenant_host(acme))
      expect(response).to redirect_to(root_url(host: tenant_host(acme)))
    end

    it "acme のセッション cookie を globex サブドメインへ送ると、復元されずログインへ戻される（deserialize 経路の遮断）" do
      session_cookie = cookies["_gatcha_session"]
      expect(session_cookie).to be_present

      get root_url(host: tenant_host(globex)),
          headers: { "Cookie" => "_gatcha_session=#{session_cookie}" }
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(globex)))
    end

    it "remember cookie のみでの devise 公開画面アクセスも 500 にならない（serialize_from_cookie）" do
      # before ブロックの sign_in 状態をリセットし、フォームログインで remember cookie を発行
      sign_out :user
      post user_session_url(host: tenant_host(acme)),
           params: { user: { email: user.email, password: "password123!", remember_me: "1" } }
      remember_cookie = cookies["remember_user_token"]
      expect(remember_cookie).to be_present

      # セッション cookie を送らず remember cookie だけで devise 公開画面（ログイン画面）へアクセス。
      # serialize_from_cookie が without_tenant ガードなしだと NoTenantSet 500 になる
      get new_user_session_url(host: tenant_host(acme)),
          headers: { "Cookie" => "remember_user_token=#{Rack::Utils.escape(remember_cookie)}" }
      # ログイン状態が remember cookie で復元される → already_authenticated でルートへリダイレクト
      expect(response).not_to have_http_status(:internal_server_error)
      expect(response).to redirect_to(root_url(host: tenant_host(acme)))
    end
  end
end
