# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveDaysCalculator do
  # classifications = { Date => { day_type:, counts_as_paid_leave: } }
  def cls(map) = map.transform_values { |dt| { day_type: dt, counts_as_paid_leave: false } }

  describe ".call（全休）" do
    it "weekday のみ計上し合計を BigDecimal で返す" do
      c = cls(Date.new(2026, 5, 1) => :weekday, Date.new(2026, 5, 2) => :saturday)
      expect(described_class.call(classifications: c, half_day_type: :none)).to eq(BigDecimal("1"))
    end

    it "土日祝・法定休日は除外する" do
      c = cls(
        Date.new(2026, 5, 4) => :holiday, Date.new(2026, 5, 5) => :legal_holiday,
        Date.new(2026, 5, 6) => :weekday
      )
      expect(described_class.call(classifications: c, half_day_type: :none)).to eq(BigDecimal("1"))
    end

    it "全日が除外なら BigDecimal('0')（型を保つ）" do
      c = cls(Date.new(2026, 5, 2) => :saturday, Date.new(2026, 5, 3) => :sunday)
      result = described_class.call(classifications: c, half_day_type: :none)
      expect(result).to eql(BigDecimal("0"))
    end

    it "company_holiday は counts_as_paid_leave で分岐（true=計上 / false=除外）" do
      paid = { Date.new(2026, 5, 1) => { day_type: :company_holiday, counts_as_paid_leave: true } }
      unpaid = { Date.new(2026, 5, 1) => { day_type: :company_holiday, counts_as_paid_leave: false } }
      expect(described_class.call(classifications: paid, half_day_type: :none)).to eq(BigDecimal("1"))
      expect(described_class.call(classifications: unpaid, half_day_type: :none)).to eq(BigDecimal("0"))
    end
  end

  describe ".call（半休）" do
    it "計上対象の単日は 0.5" do
      c = cls(Date.new(2026, 5, 1) => :weekday)
      expect(described_class.call(classifications: c, half_day_type: :morning)).to eq(BigDecimal("0.5"))
    end

    it "除外日の半休は 0" do
      c = cls(Date.new(2026, 5, 2) => :saturday)
      expect(described_class.call(classifications: c, half_day_type: :afternoon)).to eq(BigDecimal("0"))
    end

    it "複数日 × 半休は防御 assert で ArgumentError（純関数の入力契約）" do
      c = cls(Date.new(2026, 5, 1) => :weekday, Date.new(2026, 5, 7) => :weekday)
      expect { described_class.call(classifications: c, half_day_type: :morning) }
        .to raise_error(ArgumentError)
    end
  end
end
