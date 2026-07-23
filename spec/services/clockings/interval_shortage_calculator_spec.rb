# frozen_string_literal: true

require "rails_helper"

# DB 非依存の純関数（設計 §10③/§13④）。境界は §10⑧: 11h ちょうど = 非違反・下回れば違反。
RSpec.describe Clockings::IntervalShortageCalculator do
  def call(prev:, at:, threshold: 11)
    described_class.call(prev_clock_out: prev, clock_in: at, threshold_hours: threshold)
  end

  it "閾値ちょうど（11h）は非違反 = nil（`<` 境界・§10⑧）" do
    prev = Time.utc(2026, 6, 1, 9, 0)
    expect(call(prev: prev, at: prev + 11.hours)).to be_nil
  end

  it "閾値を 1 分下回れば違反 = 不足 1 分" do
    prev = Time.utc(2026, 6, 1, 9, 0)
    expect(call(prev: prev, at: prev + 10.hours + 59.minutes)).to eq(1)
  end

  it "秒以下は floor（10:59:59 の休息は 659 分 = 違反・不足 1 分）" do
    prev = Time.utc(2026, 6, 1, 9, 0)
    expect(call(prev: prev, at: prev + 10.hours + 59.minutes + 59.seconds)).to eq(1)
  end

  it "閾値を 30 秒上回る（11h00m30s）は非違反 = nil（floor は違反側に倒れない）" do
    prev = Time.utc(2026, 6, 1, 9, 0)
    expect(call(prev: prev, at: prev + 11.hours + 30.seconds)).to be_nil
  end

  it "prev_clock_out が nil（初回出勤・退勤記録なし）は nil" do
    expect(call(prev: nil, at: Time.utc(2026, 6, 1, 9))).to be_nil
  end

  it "夜勤明け 9h は違反 = 不足 120 分（§10⑧ 夜勤両方向の違反側）" do
    prev = Time.utc(2026, 6, 1, 22, 0)
    expect(call(prev: prev, at: prev + 9.hours)).to eq(120)
  end

  it "夜勤明け 12h は非違反（§10⑧ 夜勤両方向の非違反側）" do
    prev = Time.utc(2026, 6, 1, 22, 0)
    expect(call(prev: prev, at: prev + 12.hours)).to be_nil
  end

  it "threshold は org 設定値を尊重する（threshold=8 なら 7h59m で不足 1 分・8h で nil）" do
    prev = Time.utc(2026, 6, 1, 9, 0)
    expect(call(prev: prev, at: prev + 7.hours + 59.minutes, threshold: 8)).to eq(1)
    expect(call(prev: prev, at: prev + 8.hours, threshold: 8)).to be_nil
  end
end
