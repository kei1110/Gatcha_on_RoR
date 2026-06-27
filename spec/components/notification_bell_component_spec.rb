# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationBellComponent, type: :component do
  let(:org)  { create(:organization) }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user, name: "本人") } }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  it "未読件数をバッジに出す（既読は数えない）" do
    create(:notification, target_user: user, read_at: nil)
    create(:notification, target_user: user, read_at: Time.current)
    render_inline(described_class.new(current_user: user))
    expect(page).to have_css("#notification_bell_count", text: "1")
  end

  it "未読ゼロはバッジ数字なし（要素は存在＝broadcast 先確保）" do
    render_inline(described_class.new(current_user: user))
    expect(page).to have_css("#notification_bell_count")
    expect(page.find("#notification_bell_count").text.strip).to eq("")
  end

  it "直近通知をドロップダウン list（#notifications）に出す" do
    create(:notification, target_user: user, title: "申請が承認されました")
    render_inline(described_class.new(current_user: user))
    expect(page).to have_css("ul#notifications", visible: :all)
    expect(page).to have_selector("li", text: "申請が承認されました", visible: :all)
  end

  it "通知一覧・通知設定への動線を持つ（§1.4 到達性 — preferences は本リンクが唯一の nav 入口）" do
    render_inline(described_class.new(current_user: user))
    expect(page).to have_link("すべての通知", href: "/notifications", visible: :all)
    expect(page).to have_link("通知設定", href: "/notification_preferences/edit", visible: :all)
  end
end
