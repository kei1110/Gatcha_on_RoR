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
    acme_user.update!(active: false)
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
end
