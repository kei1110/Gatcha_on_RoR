require "rails_helper"

RSpec.describe "テナント分離 E2E", type: :system do
  let!(:acme)   { create(:organization, name: "Acme", subdomain: "acme") }
  let!(:globex) { create(:organization, name: "Globex", subdomain: "globex") }
  let!(:acme_user) do
    ActsAsTenant.with_tenant(acme) do
      create(:user, name: "急須 茶太郎", email: "cha@example.com", password: "password123!")
    end
  end
  let!(:globex_user) do
    ActsAsTenant.with_tenant(globex) do
      create(:user, name: "轟 雷蔵", email: "rai@example.com", password: "different456!")
    end
  end

  def login(email:, password:)
    visit new_user_session_path
    fill_in "メールアドレス", with: email
    fill_in "パスワード", with: password
    click_button "ログイン"
  end

  it "acme のユーザーは acme でログインでき、自分の名前と組織が見える" do
    switch_tenant(acme)
    login(email: "cha@example.com", password: "password123!")
    # 正のアンカー assert（エラーページでも緑になる偽テスト防止）
    expect(page).to have_content("急須 茶太郎")
    expect(page).to have_content("Acme")
    expect(page).not_to have_content("Globex")
  end

  it "globex のフォームに acme の資格情報ではログインできない" do
    switch_tenant(globex)
    login(email: "cha@example.com", password: "password123!")
    expect(page).to have_current_path(new_user_session_path)
    expect(page).not_to have_content("急須 茶太郎")
  end
end
