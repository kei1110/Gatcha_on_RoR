# frozen_string_literal: true

require "rails_helper"

RSpec.describe WeeklyOvertimeCalculator do
  # 2026-03-01(日)〜03-07(土) を 1 週として使う。period_range は 3 月（土 3/7 を含む）。
  let(:march) { Date.new(2026, 3, 1)..Date.new(2026, 3, 31) }

  # Mon..Sat（3/2〜3/7）に同一属性の日を hours で並べる helper
  def week_days(hours, daily_ot: 0, legal_holiday_work: false, flextime: false)
    (2..7).map do |d|
      { date: Date.new(2026, 3, d), actual_hours: BigDecimal(hours.to_s),
        daily_legal_overtime_hours: BigDecimal(daily_ot.to_s),
        legal_holiday_work:, flextime: }
    end
  end

  def call(days, period_range: march) = described_class.call(period_range:, days:)

  it "40h 境界 3 点（日次 OT 0）: 週実労働 39.99/40.00/40.01 → 0/0/0.01" do
    expect(call([ { date: Date.new(2026, 3, 7), actual_hours: BigDecimal("39.99"),
                   daily_legal_overtime_hours: BigDecimal("0"), legal_holiday_work: false, flextime: false } ]))
      .to eq(BigDecimal("0"))
    expect(call([ { date: Date.new(2026, 3, 7), actual_hours: BigDecimal("40.00"),
                   daily_legal_overtime_hours: BigDecimal("0"), legal_holiday_work: false, flextime: false } ]))
      .to eq(BigDecimal("0"))
    expect(call([ { date: Date.new(2026, 3, 7), actual_hours: BigDecimal("40.01"),
                   daily_legal_overtime_hours: BigDecimal("0"), legal_holiday_work: false, flextime: false } ]))
      .to eq(BigDecimal("0.01"))
  end

  it "所定 7h×6 日=42h・日次 OT 0 → extra 2.00" do
    expect(call(week_days(7))).to eq(BigDecimal("2"))
  end

  it "重複控除: 週実労働 50h・日次 OT 合計 6h → max(0, 50−40−6)=4.00" do
    # 6 日 × actual ~8.333 で 50h、日次 OT 合計 6（1 日 1h）
    days = (2..7).map do |d|
      { date: Date.new(2026, 3, d), actual_hours: BigDecimal("50") / 6,
        daily_legal_overtime_hours: BigDecimal("1"), legal_holiday_work: false, flextime: false }
    end
    expect(call(days)).to eq(BigDecimal("4"))
  end

  it "負クランプ: 週 50h・日次 OT 15h → max(0, 50−40−15)=0" do
    days = (2..7).map do |d|
      { date: Date.new(2026, 3, d), actual_hours: BigDecimal("50") / 6,
        daily_legal_overtime_hours: BigDecimal("2.5"), legal_holiday_work: false, flextime: false }
    end
    expect(call(days)).to eq(BigDecimal("0"))
  end

  it "空配列 → 0（nil/ゼロ除算なし）" do
    expect(call([])).to eq(BigDecimal("0"))
  end

  it "期間帰属: 同一 days でも period_range が土曜を含まなければ 0 寄与" do
    feb = Date.new(2026, 2, 1)..Date.new(2026, 2, 28) # 3/7 を含まない
    expect(call(week_days(7), period_range: feb)).to eq(BigDecimal("0"))
  end

  it "法定休日労働日は母数から除外（35% 側へ）" do
    # 5 日は 7h、1 日は法定休日 20h → countable は 35h で 40h 未満 → 0
    days = week_days(7)
    days[0] = days[0].merge(actual_hours: BigDecimal("20"), legal_holiday_work: true)
    expect(call(days)).to eq(BigDecimal("0"))
  end

  it "flextime 日は週 40h 母数から除外（清算期間ベース・D7）" do
    days = week_days(7)
    days[0] = days[0].merge(actual_hours: BigDecimal("20"), flextime: true)
    expect(call(days)).to eq(BigDecimal("0"))
  end
end
