require "rails_helper"

RSpec.describe "テナント解決（fail-closed・SPEC §3.1）", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  it "正常: 既知サブドメイン＋ログイン済みでホーム到達" do
    sign_in user
    get root_url(host: tenant_host(org))
    expect(response).to have_http_status(:ok)
  end

  it "未知サブドメインは未ログインでも 404（①解決→②認証の順序固定）" do
    get root_url(host: "unknown.example.com")
    expect(response).to have_http_status(:not_found)
  end

  it "inactive 組織は 404" do
    org.update!(active: false)
    get root_url(host: tenant_host(org))
    expect(response).to have_http_status(:not_found)
  end

  it "apex（サブドメインなし）は 404" do
    get root_url(host: "example.com")
    expect(response).to have_http_status(:not_found)
  end

  it "www は 404（テナントではない）" do
    get root_url(host: "www.example.com")
    expect(response).to have_http_status(:not_found)
  end

  it "大文字サブドメインは downcase されて解決" do
    sign_in user
    get root_url(host: "ACME.example.com")
    expect(response).to have_http_status(:ok)
  end

  it "正常サブドメイン＋未ログインはサインインへ redirect" do
    get root_url(host: tenant_host(org))
    expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))
  end

  it "inactive 化後は既存セッションも遮断される" do
    sign_in user
    get root_url(host: tenant_host(org))
    expect(response).to have_http_status(:ok)
    org.update!(active: false)
    get root_url(host: tenant_host(org))
    expect(response).to have_http_status(:not_found)
  end
end
