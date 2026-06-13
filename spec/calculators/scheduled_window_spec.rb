require "rails_helper"

# DB 不要 — pattern は Struct duck（night_shift? / flextime? の述語名に応答させること）
RSpec.describe ScheduledWindow do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }
  let(:work_date) { Date.new(2026, 6, 1) }
  let(:duck_class) do
    Struct.new(:start_time, :end_time, :night_shift, :flextime,
               :core_time_start, :core_time_end, :break_minutes,
               :effective_morning_half_break_minutes, :effective_afternoon_half_break_minutes,
               keyword_init: true) do
      def night_shift? = night_shift
      def flextime? = flextime
    end
  end

  # time 型カラムは 2000-01-01 基準の Time — AR の挙動を Time.utc(2000,1,1,...) で再現
  def window(**attrs)
    defaults = {
      start_time: Time.utc(2000, 1, 1, 9), end_time: Time.utc(2000, 1, 1, 18),
      night_shift: false, flextime: false, core_time_start: nil, core_time_end: nil,
      break_minutes: 60,
      effective_morning_half_break_minutes: 30, effective_afternoon_half_break_minutes: 45
    }
    described_class.for(pattern: duck_class.new(**defaults.merge(attrs)), work_date:, zone:)
  end

  it "通常日勤を work_date + 組織 TZ で合成する（コアは nil）" do
    w = window
    expect(w.start_at).to eq(zone.local(2026, 6, 1, 9, 0, 0))
    expect(w.end_at).to eq(zone.local(2026, 6, 1, 18, 0, 0))
    expect(w.core_start_at).to be_nil
    expect(w.core_end_at).to be_nil
  end

  it "夜勤（start > end）は end_at を +1.day 翌日換算する（SPEC §5 入力契約）" do
    w = window(start_time: Time.utc(2000, 1, 1, 22), end_time: Time.utc(2000, 1, 1, 7),
               night_shift: true)
    expect(w.start_at).to eq(zone.local(2026, 6, 1, 22, 0, 0))
    expect(w.end_at).to eq(zone.local(2026, 6, 2, 7, 0, 0))
  end

  it "夜勤フレックスの日跨ぎコア（start > end）は core_end_at のみ翌日換算（R7）" do
    w = window(night_shift: true, flextime: true,
               start_time: Time.utc(2000, 1, 1, 22), end_time: Time.utc(2000, 1, 1, 7),
               core_time_start: Time.utc(2000, 1, 1, 23), core_time_end: Time.utc(2000, 1, 1, 3))
    expect(w.core_start_at).to eq(zone.local(2026, 6, 1, 23, 0, 0))
    expect(w.core_end_at).to eq(zone.local(2026, 6, 2, 3, 0, 0))
  end

  it "break_minutes_for は day_part ごとに委譲する（effective フォールバックの実装は work_pattern_spec が担保）" do
    w = window
    expect(w.break_minutes_for(:full)).to eq(60)
    expect(w.break_minutes_for(:morning_half)).to eq(30)
    expect(w.break_minutes_for(:afternoon_half)).to eq(45)
  end

  it "不正 day_part は KeyError（fail-fast）" do
    expect { window.break_minutes_for(:bogus) }.to raise_error(KeyError)
  end
end
