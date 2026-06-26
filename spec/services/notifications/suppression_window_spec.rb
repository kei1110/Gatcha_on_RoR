# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::SuppressionWindow do
  # now_local は組織ローカル時刻（注入）。JST で固定（PORO は zone を値から読む）。
  def jst(hour, min = 0, day = 26)
    Time.find_zone!("Asia/Tokyo").local(2026, 6, day, hour, min, 0)
  end

  def window(now_local:, quiet_enabled: true, quiet_start: 19, quiet_end: 8,
             holiday_block: false, holiday: false)
    described_class.new(now_local:, quiet_enabled:, quiet_start:, quiet_end:,
                        holiday_block:, holiday:)
  end

  describe "#suppressed? — 日跨ぎ窓（start=19, end=8・既定）" do
    it "18:59 は非抑制（start 排他前）" do
      expect(window(now_local: jst(18, 59))).not_to be_suppressed
    end

    it "19:00 は抑制（start 包含）" do
      expect(window(now_local: jst(19, 0))).to be_suppressed
    end

    it "07:59 は抑制（end 排他前）" do
      expect(window(now_local: jst(7, 59))).to be_suppressed
    end

    it "08:00 は非抑制（end 排他）" do
      expect(window(now_local: jst(8, 0))).not_to be_suppressed
    end
  end

  describe "#suppressed? — 非日跨ぎ窓（start=8, end=19）" do
    it "07:59 は非抑制" do
      expect(window(now_local: jst(7, 59), quiet_start: 8, quiet_end: 19)).not_to be_suppressed
    end

    it "08:00 は抑制" do
      expect(window(now_local: jst(8, 0), quiet_start: 8, quiet_end: 19)).to be_suppressed
    end

    it "18:59 は抑制" do
      expect(window(now_local: jst(18, 59), quiet_start: 8, quiet_end: 19)).to be_suppressed
    end

    it "19:00 は非抑制" do
      expect(window(now_local: jst(19, 0), quiet_start: 8, quiet_end: 19)).not_to be_suppressed
    end
  end

  describe "#suppressed? — start==end 縮退（空窓）" do
    it "どの時刻でも非抑制" do
      expect(window(now_local: jst(19, 0), quiet_start: 19, quiet_end: 19)).not_to be_suppressed
      expect(window(now_local: jst(3, 0), quiet_start: 19, quiet_end: 19)).not_to be_suppressed
    end
  end

  describe "#suppressed? — quiet 無効" do
    it "quiet_enabled=false なら quiet 帯でも非抑制" do
      expect(window(now_local: jst(20, 0), quiet_enabled: false)).not_to be_suppressed
    end
  end

  describe "#suppressed? — 休日ブロック" do
    it "holiday_block ∧ holiday なら抑制（quiet 帯外でも）" do
      expect(window(now_local: jst(12, 0), holiday_block: true, holiday: true)).to be_suppressed
    end

    it "holiday_block=false なら休日でも非抑制" do
      expect(window(now_local: jst(12, 0), holiday_block: false, holiday: true)).not_to be_suppressed
    end

    it "holiday=false なら holiday_block でも非抑制" do
      expect(window(now_local: jst(12, 0), holiday_block: true, holiday: false)).not_to be_suppressed
    end
  end

  describe "#next_allowed_at" do
    it "非抑制なら now_local をそのまま返す" do
      now = jst(12, 0)
      expect(window(now_local: now).next_allowed_at).to eq(now)
    end

    it "夜間(20:00)抑制 → 翌朝 08:00 JST" do
      result = window(now_local: jst(20, 0)).next_allowed_at
      expect(result).to eq(jst(8, 0, 27))
    end

    it "早朝(03:00)抑制 → 当日 08:00 JST" do
      result = window(now_local: jst(3, 0)).next_allowed_at
      expect(result).to eq(jst(8, 0, 26))
    end

    it "休日ブロック抑制 → 翌日 0:00 JST" do
      result = window(now_local: jst(12, 0), quiet_enabled: false,
                      holiday_block: true, holiday: true).next_allowed_at
      expect(result).to eq(jst(0, 0, 27))
    end

    it "quiet と休日が両方抑制中なら遅い方まで待つ" do
      # 20:00 抑制(→翌08:00) かつ 休日(→翌00:00) → max = 翌08:00
      result = window(now_local: jst(20, 0), holiday_block: true, holiday: true).next_allowed_at
      expect(result).to eq(jst(8, 0, 27))
    end
  end
end
