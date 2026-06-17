# frozen_string_literal: true

require "rails_helper"

RSpec.describe "休暇申請フォーム", type: :system do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:dept) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, password: "password123!") } }
  let!(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: dept, password: "password123!") } }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user, manager:, password: "password123!") } }
  let!(:paid) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :annual, paid_leave: true, name: "有給") } }

  before do
    ActsAsTenant.with_tenant(org) do
      create(:leave_balance, user:, leave_type: paid, fiscal_year: "2026",
             granted_days: 10, granted_on: Date.new(2026, 4, 1))
    end
    switch_tenant(org)
    visit new_user_session_path
    fill_in "メールアドレス", with: user.email
    fill_in "パスワード", with: "password123!"
    click_button "ログイン"
  end

  it "新規申請フォームが表示され送信できる" do
    visit new_leave_request_path
    select "有給", from: "休暇種別"
    fill_in "開始日", with: "2026-05-01"
    fill_in "終了日", with: "2026-05-01"
    click_button "申請する"
    expect(page).to have_text("休暇を申請しました")
  end
end
