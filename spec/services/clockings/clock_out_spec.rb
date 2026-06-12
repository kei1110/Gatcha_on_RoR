require "rails_helper"

# 時刻リテラルはすべて UTC。org の TZ 既定は Asia/Tokyo（= UTC+9）
RSpec.describe Clockings::ClockOut do
  let(:user) { create(:user) }

  it "当日の working を退勤させる" do
    record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                    clock_in: Time.utc(2026, 6, 1, 0))
    travel_to Time.utc(2026, 6, 1, 9) do # JST 18:00
      result = described_class.call(user:)

      expect(result).to be_success
      expect(record.reload).to be_clocked_out
      expect(record.clock_out).to eq(Time.current)
    end
  end

  it "夜勤跨ぎ: 前日の working に翌日の退勤が合流し work_date は前日のまま（SPEC §4.8 出勤日統一）" do
    record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                    clock_in: Time.utc(2026, 6, 1, 13)) # JST 6/1 22:00 出勤
    travel_to Time.utc(2026, 6, 1, 22) do # JST 6/2 07:00
      result = described_class.call(user:)

      expect(result).to be_success
      expect(record.reload.work_date).to eq(Date.new(2026, 6, 1))
      expect(record.clock_out).to eq(Time.current)
    end
  end

  it "working が無ければ :not_working" do
    travel_to Time.utc(2026, 6, 1, 9) do
      result = described_class.call(user:)
      expect(result).not_to be_success
      expect(result.error).to eq(:not_working)
    end
  end

  it "退勤済みの後は :not_working（両ボタン無効の決定 — 証跡なし上書き経路を作らない）" do
    create(:attendance_record, user:, work_date: Date.new(2026, 6, 1), status: :clocked_out,
           clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 8))
    travel_to Time.utc(2026, 6, 1, 9) do
      expect(described_class.call(user:).error).to eq(:not_working)
    end
  end

  it "window 外（2 日以上前）の working は退勤対象にしない（4-2 温存・誤った当日退勤の混入防止）" do
    create(:attendance_record, user:, work_date: Date.new(2026, 5, 29),
           clock_in: Time.utc(2026, 5, 29, 0))
    travel_to Time.utc(2026, 6, 1, 9) do
      expect(described_class.call(user:).error).to eq(:not_working)
    end
  end

  it "同僚の working しか無ければ :not_working（user 起点クエリの検証 — セキュリティレビュー）" do
    other = create(:user)
    create(:attendance_record, user: other, work_date: Date.new(2026, 6, 1),
           clock_in: Time.utc(2026, 6, 1, 0))
    travel_to Time.utc(2026, 6, 1, 9) do
      expect(described_class.call(user:).error).to eq(:not_working)
    end
  end

  it "window 内に working が 2 件あれば新しい work_date を退勤させる（防御的 — 通常はガードで発生しない）" do
    old_record = create(:attendance_record, user:, work_date: Date.new(2026, 5, 31),
                        clock_in: Time.utc(2026, 5, 31, 0))
    new_record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                        clock_in: Time.utc(2026, 6, 1, 0))
    travel_to Time.utc(2026, 6, 1, 9) do
      described_class.call(user:)

      expect(new_record.reload).to be_clocked_out
      expect(old_record.reload).to be_working
    end
  end

  it "ロック取得待ちの間に他方が退勤済みへ変えていたら :not_working（同時タブ race の敗者）" do
    record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                    clock_in: Time.utc(2026, 6, 1, 0))
    # with_lock の reload 後に「他タブが勝った」状況を再現する（lock 機構そのものは AR を信頼）
    allow_any_instance_of(AttendanceRecord).to receive(:with_lock) do |rec, &block|
      rec.update_columns(status: AttendanceRecord.statuses[:clocked_out],
                         clock_out: Time.utc(2026, 6, 1, 8))
      block.call
    end

    travel_to Time.utc(2026, 6, 1, 9) do
      result = described_class.call(user:)
      expect(result).not_to be_success
      expect(result.error).to eq(:not_working)
      expect(record.reload.clock_out).to eq(Time.utc(2026, 6, 1, 8)) # 先勝ちの時刻が保持される
    end
  end
end
