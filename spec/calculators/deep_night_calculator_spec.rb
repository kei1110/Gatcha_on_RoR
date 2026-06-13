require "rails_helper"

RSpec.describe DeepNightCalculator do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }
  let(:work_date) { Date.new(2026, 6, 1) }

  def call(clock_in:, clock_out:, break_minutes: 0)
    described_class.call(clock_in:, clock_out:, break_minutes:, work_date:, zone:)
  end

  describe "22:00 側境界（含まない開始点・SPEC §5.3）" do
    let(:clock_in) { zone.local(2026, 6, 1, 13) }

    it "22:00:00 ちょうど退勤 = 0（重複 0 秒）" do
      expect(call(clock_in:, clock_out: zone.local(2026, 6, 1, 22, 0, 0))).to eq(0)
    end

    it "22:00:01 退勤 = 0（重複 1 秒 → floor）" do
      expect(call(clock_in:, clock_out: zone.local(2026, 6, 1, 22, 0, 1))).to eq(0)
    end

    it "22:01:00 退勤 = 1 分" do
      expect(call(clock_in:, clock_out: zone.local(2026, 6, 1, 22, 1, 0))).to eq(1)
    end
  end

  describe "5:00 側境界（出勤側・対称）" do
    let(:clock_out) { zone.local(2026, 6, 1, 14) }

    it "5:00:00 ちょうど出勤 = 0" do
      expect(call(clock_in: zone.local(2026, 6, 1, 5, 0, 0), clock_out:)).to eq(0)
    end

    it "4:59:59 出勤 = 0（1 秒 → floor）" do
      expect(call(clock_in: zone.local(2026, 6, 1, 4, 59, 59), clock_out:)).to eq(0)
    end

    it "4:59:00 出勤 = 1 分" do
      expect(call(clock_in: zone.local(2026, 6, 1, 4, 59, 0), clock_out:)).to eq(1)
    end
  end

  it "早朝シフトは前日窓 [D−1 22:00, D 5:00] を捕捉する（4:00 出勤 → 60 分・§5.3 隣接 2 窓の消費）" do
    expect(call(clock_in: zone.local(2026, 6, 1, 4), clock_out: zone.local(2026, 6, 1, 13))).to eq(60)
  end

  it "夜勤通し 22:00〜翌 5:00（break 0）= 420 分" do
    expect(call(clock_in: zone.local(2026, 6, 1, 22), clock_out: zone.local(2026, 6, 2, 5))).to eq(420)
  end

  it "2 窓同時寄与 + 按分: 03:00〜23:30・break 60 → overlap 210・按分 floor(60×210/1230)=10 → 200 分" do
    expect(call(clock_in: zone.local(2026, 6, 1, 3), clock_out: zone.local(2026, 6, 1, 23, 30),
                break_minutes: 60)).to eq(200)
  end

  it "按分 FLOOR 判別値: 20:00〜翌 5:00・break 60 → 60×420/540 = 46.67 → 46（HALF_UP なら 47）→ 374 分" do
    expect(call(clock_in: zone.local(2026, 6, 1, 20), clock_out: zone.local(2026, 6, 2, 5),
                break_minutes: 60)).to eq(374)
  end

  it "秒は 2 窓合算後に 1 回だけ floor（R1）: 各窓 30 秒ずつ → 合算 60 秒 = 1 分（窓ごと floor なら 0）" do
    expect(call(clock_in: zone.local(2026, 6, 1, 4, 59, 30),
                clock_out: zone.local(2026, 6, 1, 22, 0, 30))).to eq(1)
  end

  it "presence 0（in == out）は 0 ガード" do
    t = zone.local(2026, 6, 1, 23)
    expect(call(clock_in: t, clock_out: t)).to eq(0)
  end

  it "控除後は max(0) で clamp: 21:45〜22:15・break 60 → overlap 15 − 按分 30 = −15 → 0（負値を流さない）" do
    # 品質レビュー①の生存ミュータント対応 — 非 clamp だと負値が Recalculate の numericality で
    # update! 失敗 → R4 rescue の「退勤成功 + 列 NULL」という分かりにくい経路に落ちる
    expect(call(clock_in: zone.local(2026, 6, 1, 21, 45), clock_out: zone.local(2026, 6, 1, 22, 15),
                break_minutes: 60)).to eq(0)
  end

  it "第 3 窓は数えない（定義域 pin）: D 4:00 〜 D+1 23:00 → 前日窓 60 + 当日窓 420 = 480 分" do
    expect(call(clock_in: zone.local(2026, 6, 1, 4), clock_out: zone.local(2026, 6, 2, 23))).to eq(480)
  end
end
