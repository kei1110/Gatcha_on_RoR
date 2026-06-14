# frozen_string_literal: true

require "rails_helper"

# 時刻リテラルはすべて UTC。org の TZ 既定は Asia/Tokyo（= UTC+9）
RSpec.describe Clockings::ClockIn do
  let(:user) { create(:user) }

  it "working レコードを作成し、有効割当のパターンをスナップショットする（SPEC §4.8・§6.1）" do
    pattern = create(:work_pattern)
    create(:user_work_pattern, user:, work_pattern: pattern, start_date: Date.new(2026, 1, 1))

    travel_to Time.utc(2026, 6, 1, 1) do # JST 6/1 10:00
      result = described_class.call(user:)

      expect(result).to be_success
      expect(result.record.work_date).to eq(Date.new(2026, 6, 1))
      expect(result.record.work_pattern_id).to eq(pattern.id)
      expect(result.record).to be_working
      expect(result.record.clock_in).to eq(Time.current)
      expect(result.record.clock_out).to be_nil
    end
  end

  it "打刻はサブ秒を持たない（usec 切り詰め — ClockOut と対・1-2 R2）" do
    # travel_to は既定で usec を 0 に切り詰めるため with_usec: true で本物のサブ秒を再現する
    travel_to Time.utc(2026, 6, 1, 1, 0, 0, 123_456), with_usec: true do
      result = described_class.call(user:)
      expect(result.record.clock_in.usec).to eq(0)
    end
  end

  it "有効割当が無ければ work_pattern_id NULL で保存する（SPEC §5.4 — 打刻はブロックしない）" do
    travel_to Time.utc(2026, 6, 1, 1) do
      result = described_class.call(user:)
      expect(result).to be_success
      expect(result.record.work_pattern_id).to be_nil
    end
  end

  it "TZ 境界: JST 8:59（UTC 前日 23:59）でも work_date は JST 当日（Organization#today 経由の検証）" do
    travel_to Time.utc(2026, 5, 31, 23, 59) do # JST 6/1 08:59
      result = described_class.call(user:)
      expect(result.record.work_date).to eq(Date.new(2026, 6, 1))
    end
  end

  it "同日レコードが既にあれば :already_clocked_in（退勤済みでも同様 = 両ボタン無効の決定）" do
    travel_to Time.utc(2026, 6, 1, 1) do
      described_class.call(user:)
      result = described_class.call(user:)
      expect(result).not_to be_success
      expect(result.error).to eq(:already_clocked_in)
    end
  end

  it "window 内に working が残っていれば :still_working（前日退勤忘れ・夜勤中の再出勤防止）" do
    create(:attendance_record, user:, work_date: Date.new(2026, 5, 31),
           clock_in: Time.utc(2026, 5, 31, 0))
    travel_to Time.utc(2026, 6, 1, 1) do
      expect(described_class.call(user:).error).to eq(:still_working)
    end
  end

  it "window 外（2 日以上前）の取り残し working は出勤を妨げない（4-2 検出対象として温存）" do
    create(:attendance_record, user:, work_date: Date.new(2026, 5, 29),
           clock_in: Time.utc(2026, 5, 29, 0))
    travel_to Time.utc(2026, 6, 1, 1) do
      expect(described_class.call(user:)).to be_success
    end
  end

  it "同一組織の他人の同日行・working には反応しない（user 起点クエリの検証 — セキュリティレビュー）" do
    other = create(:user)
    create(:attendance_record, user: other, work_date: Date.new(2026, 6, 1),
           clock_in: Time.utc(2026, 6, 1, 0))
    travel_to Time.utc(2026, 6, 1, 1) do
      expect(described_class.call(user:)).to be_success
    end
  end

  it "検証レースの敗者は unique index で :already_clocked_in に合流する（SPEC §6.1 サーバー側防衛）" do
    travel_to Time.utc(2026, 6, 1, 1) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1), status: :clocked_out,
             clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 0, 30))
      relation = user.attendance_records
      allow(user).to receive(:attendance_records).and_return(relation)
      allow(relation).to receive(:exists?).and_return(false) # 同日ガードだけ素通りさせ index を実発火させる

      result = described_class.call(user:)
      expect(result).not_to be_success
      expect(result.error).to eq(:already_clocked_in)
    end
  end
end
