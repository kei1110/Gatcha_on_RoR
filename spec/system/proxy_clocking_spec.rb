# frozen_string_literal: true

require "rails_helper"

RSpec.describe "代理打刻", type: :system do
  let(:org) { create(:organization, subdomain: "acme") }
  # manager と sub は名前を分ける（バナーの actor.name 検証が本人ヘッダーの自名で素通りしないように）
  let!(:manager) do
    ActsAsTenant.with_tenant(org) do
      create(:user, :manager_role, organization: org, name: "上司 花子", password: "password123!")
    end
  end
  let!(:sub) do
    ActsAsTenant.with_tenant(org) do
      create(:user, organization: org, manager: manager, name: "部下 太郎", password: "password123!")
    end
  end

  before { switch_tenant(org) }

  def login(user)
    visit new_user_session_path
    fill_in "メールアドレス", with: user.email
    fill_in "パスワード", with: "password123!"
    click_button "ログイン"
  end

  it "manager がロスターから部下に代理出勤でき、部下へ通知が届く（暫定バナーは撤去済み・§13③）" do
    login(manager)
    click_link "代理打刻"
    expect(page).to have_content(sub.name)
    within("tr", text: sub.name) do
      select "打刻忘れ", from: "proxy_clock_reason"
      click_button "代理出勤"
    end
    expect(page).to have_content("代理出勤を記録しました")

    # ログアウトボタンはホームにのみ存在（ロスター画面には無い）
    visit root_path
    click_button "ログアウト"
    login(sub)
    # 暫定バナーが無いこと（恒久解決 = 通知への一本化）
    expect(page).not_to have_content("代理打刻です")
    # 通知一覧に proxy_clocked 通知が届いていること
    visit notifications_path
    expect(page).to have_content("勤怠が代理で打刻されました")
    expect(page).to have_content(manager.name)
  end
end
