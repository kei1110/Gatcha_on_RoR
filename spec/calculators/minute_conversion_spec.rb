# frozen_string_literal: true

require "rails_helper"

RSpec.describe MinuteConversion do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }

  describe ".minutes_between" do
    it "差分秒を 60 で整数除算（floor）する" do
      from = zone.local(2026, 6, 1, 9, 0, 30)
      to   = zone.local(2026, 6, 1, 18, 0, 0)
      expect(described_class.minutes_between(from, to)).to eq(539) # 8h59m30s → floor
    end

    it "1 分未満は 0" do
      from = zone.local(2026, 6, 1, 9, 0, 0)
      expect(described_class.minutes_between(from, from + 59)).to eq(0)
    end
  end

  describe ".to_hours" do
    # 整数分 ÷ 60 は第 3 位がちょうど 5 になる値が存在しないため half up/down は判別不能。
    # 検証対象は「切り上げ発火 vs 切り捨て」（1-2 設計 §5・R11）
    it "HALF_UP の切り上げが発火する（truncate との判別値）" do
      expect(described_class.to_hours(10)).to eq(BigDecimal("0.17"))  # truncate なら 0.16
      expect(described_class.to_hours(481)).to eq(BigDecimal("8.02")) # truncate なら 8.01
    end

    it "算術 sanity（非発火値）" do
      expect(described_class.to_hours(0)).to eq(0)
      expect(described_class.to_hours(30)).to eq(BigDecimal("0.5"))
      expect(described_class.to_hours(50)).to eq(BigDecimal("0.83"))
    end
  end
end
