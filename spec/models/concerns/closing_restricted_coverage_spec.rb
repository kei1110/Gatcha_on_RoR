# frozen_string_literal: true

require "rails_helper"

# silent-gap 塞ぎ（3-2 設計 §2.4・D3）。
# Approvable を include する本番モデルは ClosingRestricted も include し、
# closing_locked? の実体が ClosingRestricted 由来であることを機械検証する。
RSpec.describe "ClosingRestricted coverage", type: :model do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  before { Rails.application.eager_load! }

  let(:requester) { create(:user, organization: org) }

  it "本番の Approvable host は空でない（列挙ロジックの偽 green 防止）" do
    hosts = ApplicationRecord.descendants.select { |k| k.include?(Approvable) }
    expect(hosts).to include(LeaveRequest, ClockChangeRequest, HolidayWorkRequest)
  end

  it "全 Approvable host が ClosingRestricted を include する" do
    hosts = [ LeaveRequest, ClockChangeRequest, HolidayWorkRequest ]
    hosts.each do |klass|
      expect(klass.include?(ClosingRestricted)).to be(true), "#{klass} must include ClosingRestricted"
    end
  end

  it "closing_locked? の実体が ClosingRestricted 由来（Approvable 既定 false に勝つ）" do
    [ LeaveRequest, ClockChangeRequest, HolidayWorkRequest ].each do |klass|
      owner = klass.instance_method(:closing_locked?).owner
      expect(owner).to eq(ClosingRestricted), "#{klass}#closing_locked? は #{owner} 由来（ClosingRestricted であるべき）"
    end
  end

  it "各 host の closing_target_dates が呼べる（NotImplementedError でない）" do
    lr = build(:leave_request, requester:, start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 3))
    expect(lr.closing_target_dates.to_a).to eq([ Date.new(2026, 5, 1), Date.new(2026, 5, 2), Date.new(2026, 5, 3) ])

    hwr = build(:holiday_work_request, requester:, work_date: Date.new(2026, 6, 7))
    expect(hwr.closing_target_dates).to eq([ Date.new(2026, 6, 7) ])
  end
end
