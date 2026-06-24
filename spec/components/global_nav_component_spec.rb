# frozen_string_literal: true

require "rails_helper"

RSpec.describe GlobalNavComponent, type: :component do
  def render_at(path, user)
    with_request_url(path) { render_inline(described_class.new(current_user: user)) }
  end

  it "employee: 申請系リンクは出るが 承認/代理打刻/管理 は出ない" do
    render_at("/", User.new(role: :employee, name: "社員"))
    expect(page).to have_link("休暇申請")
    expect(page).to have_link("月次サマリ")
    expect(page).not_to have_link("承認")
    expect(page).not_to have_link("代理打刻")
    expect(page).not_to have_link("管理")
  end

  it "manager: 承認・代理打刻は出るが 管理 は出ない" do
    render_at("/", User.new(role: :manager, name: "上長"))
    expect(page).to have_link("承認")
    expect(page).to have_link("代理打刻")
    expect(page).not_to have_link("管理")
  end

  it "hr_admin: 管理も出る（承認・代理打刻も）" do
    render_at("/", User.new(role: :hr_admin, name: "管理者"))
    expect(page).to have_link("管理")
    expect(page).to have_link("承認")
    expect(page).to have_link("代理打刻")
  end

  it "現在パスのリンクが active（/leave_requests で 休暇申請 が font-bold・ホームは非 active）" do
    render_at("/leave_requests", User.new(role: :employee, name: "社員"))
    expect(page.find("a", text: "休暇申請")[:class]).to include("font-bold")
    expect(page.find("a", text: "ホーム")[:class]).not_to include("font-bold")
  end
end
