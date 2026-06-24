# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Global navigation", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }

  it "サインイン済みホームに機能ナビが出る（休暇申請・月次サマリ・各 path）" do
    user = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in user
    get root_url(host: tenant_host(org))
    expect(response.body).to include("休暇申請").and include("月次サマリ")
    expect(response.body).to include(leave_requests_path)
    expect(response.body).to include(monthly_attendance_summaries_path)
  end

  it "hr_admin は 管理 リンク（/admin/users）が出る" do
    admin = ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) }
    sign_in admin
    get root_url(host: tenant_host(org))
    expect(response.body).to include(admin_users_path)
  end

  it "employee には 管理 リンクが出ない" do
    user = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in user
    get root_url(host: tenant_host(org))
    expect(response.body).not_to include(">管理</a>")
  end
end
