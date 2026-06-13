require "rails_helper"

RSpec.describe WorkTimeCalculator do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }

  # window は break_minutes_for のみ消費 — day_part が実際に渡ることを fetch で検証する stub
  def window_stub(breaks)
    Struct.new(:breaks) do
      def break_minutes_for(day_part) = breaks.fetch(day_part)
    end.new(breaks)
  end

  def call(clock_in:, clock_out:, breaks: { full: 60 }, day_part: :full)
    described_class.call(clock_in:, clock_out:, window: window_stub(breaks), day_part:)
  end

  it "標準 8h: 540 分在席 − 60 休憩 = 480" do
    expect(call(clock_in: zone.local(2026, 6, 1, 9), clock_out: zone.local(2026, 6, 1, 18))).to eq(480)
  end

  it "秒は floor: 9:00:30〜18:00:00 = 在席 539 分 → 479" do
    expect(call(clock_in: zone.local(2026, 6, 1, 9, 0, 30),
                clock_out: zone.local(2026, 6, 1, 18, 0, 0))).to eq(479)
  end

  it "在席 < 休憩は 0 に clamp" do
    expect(call(clock_in: zone.local(2026, 6, 1, 9), clock_out: zone.local(2026, 6, 1, 9, 30))).to eq(0)
  end

  it "半休は day_part の休憩を適用（morning_half = 30 分）" do
    expect(call(clock_in: zone.local(2026, 6, 1, 13), clock_out: zone.local(2026, 6, 1, 18),
                breaks: { morning_half: 30 }, day_part: :morning_half)).to eq(270)
  end

  it "夜勤跨ぎ: 22:00〜翌 7:00 − 60 = 480（打刻側に翌日換算は不要）" do
    expect(call(clock_in: zone.local(2026, 6, 1, 22), clock_out: zone.local(2026, 6, 2, 7))).to eq(480)
  end

  it "break 0 は素通り" do
    expect(call(clock_in: zone.local(2026, 6, 1, 9), clock_out: zone.local(2026, 6, 1, 18),
                breaks: { full: 0 })).to eq(480 + 60)
  end

  it "clock_in == clock_out は 0" do
    t = zone.local(2026, 6, 1, 9)
    expect(call(clock_in: t, clock_out: t)).to eq(0)
  end
end
