require "rails_helper"

RSpec.describe OvertimeCalculator do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }
  let(:end_at_1800) { zone.local(2026, 6, 1, 18) }

  def window_stub(end_at)
    Struct.new(:end_at).new(end_at)
  end

  def call(actual:, clock_out:, end_at: end_at_1800)
    described_class.call(actual_work_minutes: actual, clock_out:, window: window_stub(end_at))
  end

  it "legal 境界 3 点: 479/480/481 分 → 0/0/1（労基法 32 条 2 項・480 分固定）" do
    out = zone.local(2026, 6, 1, 18)
    expect(call(actual: 479, clock_out: out).legal_overtime_minutes).to eq(0)
    expect(call(actual: 480, clock_out: out).legal_overtime_minutes).to eq(0)
    expect(call(actual: 481, clock_out: out).legal_overtime_minutes).to eq(1)
  end

  it "legal は window（所定）に依存しない — 同じ actual なら end_at が違っても同値（半休 480 不変の根拠）" do
    out = zone.local(2026, 6, 1, 18)
    early_end = window_stub(zone.local(2026, 6, 1, 13))
    expect(described_class.call(actual_work_minutes: 481, clock_out: out, window: early_end)
             .legal_overtime_minutes).to eq(1)
  end

  it "scheduled 等値・秒境界 3 点: 18:00:00 → 0・18:00:01 → 0（floor）・18:01:00 → 1" do
    expect(call(actual: 0, clock_out: zone.local(2026, 6, 1, 18, 0, 0)).scheduled_overtime_minutes).to eq(0)
    expect(call(actual: 0, clock_out: zone.local(2026, 6, 1, 18, 0, 1)).scheduled_overtime_minutes).to eq(0)
    expect(call(actual: 0, clock_out: zone.local(2026, 6, 1, 18, 1, 0)).scheduled_overtime_minutes).to eq(1)
  end

  it "早帰りの scheduled は max(0)" do
    expect(call(actual: 0, clock_out: zone.local(2026, 6, 1, 17)).scheduled_overtime_minutes).to eq(0)
  end

  it "夜勤は +1.day 換算済み end_at 基準: 翌日 7:30 退勤（end 翌日 7:00）→ 30 分" do
    night_end = zone.local(2026, 6, 2, 7)
    expect(call(actual: 0, clock_out: zone.local(2026, 6, 2, 7, 30), end_at: night_end)
             .scheduled_overtime_minutes).to eq(30)
  end
end
