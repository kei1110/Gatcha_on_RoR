require "rails_helper"

RSpec.describe "アカウントロック解除のテナント分離", type: :request do
  let!(:acme)   { create(:organization, subdomain: "acme") }
  let!(:globex) { create(:organization, subdomain: "globex") }
  let!(:acme_user) { ActsAsTenant.with_tenant(acme) { create(:user) } }

  def lock_and_get_token
    ActsAsTenant.with_tenant(acme) do
      acme_user.lock_access!(send_instructions: false)
      acme_user.send_unlock_instructions # raw token を返す
    end
  end

  it "acme で発行した unlock トークンは globex サブドメインで消費できない" do
    raw_token = lock_and_get_token
    get user_unlock_url(host: tenant_host(globex), unlock_token: raw_token)
    expect(acme_user.reload.access_locked?).to be(true) # ロックは解除されない
    # 明示再検証層（reset と同じく RecordNotFound → 404）が働くこと
    expect(response).to have_http_status(:not_found)
  end

  it "正規テナントでは unlock が成功する" do
    raw_token = lock_and_get_token
    get user_unlock_url(host: tenant_host(acme), unlock_token: raw_token)
    expect(acme_user.reload.access_locked?).to be(false)
  end
end
