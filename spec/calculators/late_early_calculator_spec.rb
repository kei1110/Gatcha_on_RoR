require "rails_helper"

RSpec.describe LateEarlyCalculator do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }
  let(:window_class) { Struct.new(:start_at, :end_at, :core_start_at, :core_end_at, keyword_init: true) }
  let(:fixed_window) do
    window_class.new(start_at: zone.local(2026, 6, 1, 9), end_at: zone.local(2026, 6, 1, 18),
                     core_start_at: nil, core_end_at: nil)
  end
  let(:flex_window) do
    window_class.new(start_at: zone.local(2026, 6, 1, 9), end_at: zone.local(2026, 6, 1, 18),
                     core_start_at: zone.local(2026, 6, 1, 10), core_end_at: zone.local(2026, 6, 1, 15))
  end

  def call(clock_in:, clock_out:, window: fixed_window, flextime: false, day_part: :full)
    described_class.call(clock_in:, clock_out:, window:, flextime:, day_part:)
  end

  describe "固定時間制" do
    it "等値は遅刻・早退でない（負例 — > と >= の mutation を殺す）" do
      r = call(clock_in: zone.local(2026, 6, 1, 9, 0, 0), clock_out: zone.local(2026, 6, 1, 18, 0, 0))
      expect(r.is_late).to be(false)
      expect(r.is_early_leave).to be(false)
      expect(r.late_minutes).to eq(0)
      expect(r.early_leave_minutes).to eq(0)
    end

    it "1 分未満の遅刻は is_late=true + late_minutes=0（判定は秒厳密・分数は floor）" do
      r = call(clock_in: zone.local(2026, 6, 1, 9, 0, 30), clock_out: zone.local(2026, 6, 1, 18))
      expect(r.is_late).to be(true)
      expect(r.late_minutes).to eq(0)
    end

    it "遅刻と早退は同時成立する（in 10:00 / out 17:00 → 各 60 分）" do
      r = call(clock_in: zone.local(2026, 6, 1, 10), clock_out: zone.local(2026, 6, 1, 17))
      expect(r).to eq(described_class::Result.new(
        is_late: true, late_minutes: 60, is_early_leave: true, early_leave_minutes: 60))
    end

    it "夜勤の日跨ぎ退勤は早退でない（end_at は +1.day 換算済み前提）" do
      night = window_class.new(start_at: zone.local(2026, 6, 1, 22), end_at: zone.local(2026, 6, 2, 7),
                               core_start_at: nil, core_end_at: nil)
      r = call(clock_in: zone.local(2026, 6, 1, 22), clock_out: zone.local(2026, 6, 2, 7), window: night)
      expect(r.is_early_leave).to be(false)
    end
  end

  describe "フレックス（コア基準・分数 0 固定）" do
    it "コア開始後の出勤は遅刻（true・0 分）・等値は false" do
      late = call(clock_in: zone.local(2026, 6, 1, 10, 0, 1), clock_out: zone.local(2026, 6, 1, 16),
                  window: flex_window, flextime: true)
      expect(late.is_late).to be(true)
      expect(late.late_minutes).to eq(0) # §5.4 二値管理

      on_time = call(clock_in: zone.local(2026, 6, 1, 10, 0, 0), clock_out: zone.local(2026, 6, 1, 16),
                     window: flex_window, flextime: true)
      expect(on_time.is_late).to be(false)
    end

    it "コア終了前の退勤は早退（true・0 分）" do
      r = call(clock_in: zone.local(2026, 6, 1, 9), clock_out: zone.local(2026, 6, 1, 14, 59),
               window: flex_window, flextime: true)
      expect(r.is_early_leave).to be(true)
      expect(r.early_leave_minutes).to eq(0)
    end
  end

  describe "半休の片側免除（両制度共通・SPEC §5.4）" do
    it "morning_half は遅刻免除・早退のみ判定" do
      r = call(clock_in: zone.local(2026, 6, 1, 13), clock_out: zone.local(2026, 6, 1, 17),
               day_part: :morning_half)
      expect(r.is_late).to be(false)
      expect(r.late_minutes).to eq(0)
      expect(r.is_early_leave).to be(true)
      expect(r.early_leave_minutes).to eq(60)
    end

    it "afternoon_half は早退免除・遅刻のみ判定" do
      r = call(clock_in: zone.local(2026, 6, 1, 9, 30), clock_out: zone.local(2026, 6, 1, 13),
               day_part: :afternoon_half)
      expect(r.is_late).to be(true)
      expect(r.late_minutes).to eq(30)
      expect(r.is_early_leave).to be(false)
    end

    it "半休 × フレックス複合: morning_half は遅刻 skip + コア終了基準の早退のみ（0 分固定）" do
      r = call(clock_in: zone.local(2026, 6, 1, 11), clock_out: zone.local(2026, 6, 1, 14),
               window: flex_window, flextime: true, day_part: :morning_half)
      expect(r.is_late).to be(false)
      expect(r.is_early_leave).to be(true)
      expect(r.early_leave_minutes).to eq(0)
    end
  end

  it "mode_conflict は flex のコア判定が優先（日跨ぎコアは window 側で換算済み）" do
    night_flex = window_class.new(
      start_at: zone.local(2026, 6, 1, 22), end_at: zone.local(2026, 6, 2, 7),
      core_start_at: zone.local(2026, 6, 1, 23), core_end_at: zone.local(2026, 6, 2, 3))
    r = call(clock_in: zone.local(2026, 6, 1, 22, 30), clock_out: zone.local(2026, 6, 2, 2),
             window: night_flex, flextime: true)
    expect(r.is_late).to be(false)        # コア開始 23:00 前に在席
    expect(r.is_early_leave).to be(true)  # コア終了翌 3:00 前に退勤
  end

  it "不正 day_part は ArgumentError（fail-fast）" do
    expect {
      call(clock_in: zone.local(2026, 6, 1, 9), clock_out: zone.local(2026, 6, 1, 18), day_part: :bogus)
    }.to raise_error(ArgumentError, /day_part/)
  end
end
