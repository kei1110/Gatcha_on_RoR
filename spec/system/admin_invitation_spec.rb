require "rails_helper"

RSpec.describe "社員招待の E2E（0b-1 設計 §4 system）", type: :system do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) do
    ActsAsTenant.with_tenant(org) { create(:user, :hr_admin, password: "adminpass1!") }
  end

  it "招待 → メールリンク → パスワード設定 → 当該テナントでログイン成功" do
    switch_tenant(org)

    # hr_admin でログインし社員を招待
    visit new_user_session_path
    fill_in "Email", with: admin.email
    fill_in "Password", with: "adminpass1!"
    click_button "Log in"

    visit new_admin_user_path
    fill_in "氏名", with: "新人 一郎"
    fill_in "メールアドレス", with: "newbie@example.com"
    fill_in "社員番号", with: "A-100"
    click_button "登録して招待メールを送る"
    expect(page).to have_content("招待メールを送信しました")

    # 招待リンクは require_no_authentication のため先にログアウト（設計 §2-3 既知事項）
    visit root_path
    click_button "ログアウト"

    # メールから設定 URL を取り出して受諾（deliver_now ゆえ deliveries に直接届く）
    mail_body = ActionMailer::Base.deliveries.last.body.decoded
    invite_url = mail_body[%r{https?://acme\.example\.com[^"]*reset_password_token=[^"]+}]
    expect(invite_url).to be_present

    visit invite_url
    fill_in "新しいパスワード", with: "firstpassword1!"
    fill_in "新しいパスワード（確認）", with: "firstpassword1!"
    click_button "パスワードを設定する"

    # sign_in_after_reset_password 既定 true → そのままサインイン済み（正のアンカー assert）
    expect(page).to have_content("新人 一郎 としてログイン中")
    expect(page).to have_content(org.name)
  end
end
