# frozen_string_literal: true

require "rails_helper"

RSpec.describe AttendancePeriod do
  let(:org) { create(:organization) } # fiscal_year_end_month は既定 3

  def period(year_month) = described_class.new(organization: org, year_month:)

  describe "#range（closing_day 尊重）" do
    it "closing_day=31（月末）は暦月に一致" do
      org.setting.update!(closing_day: 31)
      expect(period("2026-03").range).to eq(Date.new(2026, 3, 1)..Date.new(2026, 3, 31))
    end

    it "closing_day=31 は短い月で末日にクランプ（2 月・非うるう/うるう）" do
      org.setting.update!(closing_day: 31)
      expect(period("2026-02").range).to eq(Date.new(2026, 2, 1)..Date.new(2026, 2, 28))
      expect(period("2024-02").range).to eq(Date.new(2024, 2, 1)..Date.new(2024, 2, 29))
    end

    it "closing_day=25 は前月26日〜当月25日" do
      org.setting.update!(closing_day: 25)
      expect(period("2026-03").range).to eq(Date.new(2026, 2, 26)..Date.new(2026, 3, 25))
    end

    it "closing_day=30 は前月末がクランプされても start は連続する" do
      org.setting.update!(closing_day: 30)
      # 前ラベル月 Feb の period_end=2/28(クランプ) → start=3/1、当月 period_end=3/30
      expect(period("2026-03").range).to eq(Date.new(2026, 3, 1)..Date.new(2026, 3, 30))
    end
  end

  describe "#week_window" do
    it "range.first を含む週の日曜から range.last まで" do
      org.setting.update!(closing_day: 31)
      # 2026-03-01 は日曜ゆえ window_start == range.first
      expect(period("2026-03").week_window).to eq(Date.new(2026, 3, 1)..Date.new(2026, 3, 31))
    end

    it "range.first が週中なら前へ遡る（closing_day=25・2/26=木）" do
      org.setting.update!(closing_day: 25)
      # 2026-02-26 は木曜 → 直前日曜 2/22
      expect(period("2026-03").week_window).to eq(Date.new(2026, 2, 22)..Date.new(2026, 3, 25))
    end
  end

  describe "#prev / #next（連続性＝全日が一意に 1 期間へ）" do
    it "prev.range.last + 1 == range.first・range.last + 1 == next.range.first" do
      org.setting.update!(closing_day: 25)
      p = period("2026-03")
      expect(p.prev.range.last + 1).to eq(p.range.first)
      expect(p.range.last + 1).to eq(p.next.range.first)
    end
  end

  describe "#fiscal_year（締め日基準・末日アンカー）" do
    it "fiscal_year_end_month=3 で 3 月締めは前年度、4 月締めは当年度" do
      org.setting.update!(closing_day: 31)
      expect(period("2026-03").fiscal_year).to eq("2025")
      expect(period("2026-04").fiscal_year).to eq("2026")
    end
  end

  describe "不正 year_month" do
    it "月が範囲外なら ArgumentError" do
      expect { period("2026-13") }.to raise_error(ArgumentError)
    end
  end
end
