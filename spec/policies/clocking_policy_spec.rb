require "rails_helper"

RSpec.describe ClockingPolicy do
  it "ログイン済みなら全ロールで打刻可（管理監督者も記録対象 — SPEC §8.3 の整理と整合）" do
    [ create(:user), create(:user, :manager_role), create(:user, :hr_admin) ].each do |user|
      policy = described_class.new(user, :clocking)
      expect(policy.clock_in?).to be(true)
      expect(policy.clock_out?).to be(true)
    end
  end

  it "未ログイン（user nil）は不可（literal true にしない深層防御）" do
    policy = described_class.new(nil, :clocking)
    expect(policy.clock_in?).to be(false)
    expect(policy.clock_out?).to be(false)
  end
end
