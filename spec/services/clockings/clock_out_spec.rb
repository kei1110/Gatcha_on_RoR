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
                    clock_in: Time.utc(2026, 6, 1, 0), work_pattern: create(:work_pattern))
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
      expect(record.reload.actual_work_hours).to be_nil # 敗者経路では計算しない
    end
  end

  describe "計算列の保存（1-2 統合）" do
    it "退勤で 8 列が埋まる（日勤 9:00–18:00・JST 18:30 退勤）" do
      pattern = create(:work_pattern) # 9:00–18:00・break 60
      record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                      clock_in: Time.utc(2026, 6, 1, 0), work_pattern: pattern) # JST 9:00
      travel_to Time.utc(2026, 6, 1, 9, 30) do # JST 18:30
        described_class.call(user:)

        record.reload
        expect(record.actual_work_hours).to eq(8.5)        # 570 − 60 = 510 分
        expect(record.legal_overtime_hours).to eq(0.5)     # 510 − 480
        expect(record.scheduled_overtime_hours).to eq(0.5) # 18:30 − 18:00
        expect(record.deep_night_hours).to eq(0)
        expect(record.is_late).to be(false)
        expect(record.is_early_leave).to be(false)
      end
    end

    it "夜勤跨ぎは deep_night_hours まで埋まる（22:00–翌 7:00・按分 46 分控除）" do
      pattern = create(:work_pattern, start_time: "22:00", end_time: "07:00",
                       night_shift: true, break_minutes: 60, standard_work_hours: 8)
      record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                      clock_in: Time.utc(2026, 6, 1, 13), work_pattern: pattern) # JST 22:00
      travel_to Time.utc(2026, 6, 1, 22) do # JST 翌 7:00
        described_class.call(user:)

        # assert は travel_to 内（RAILS_GOTCHAS: 時刻依存の罠）
        record.reload
        expect(record.actual_work_hours).to eq(8.0)     # 540 − 60
        expect(record.deep_night_hours).to eq(6.23)     # overlap 420 − floor(60×420/540)=46 → 374 分
        expect(record.is_early_leave).to be(false)      # 終業ちょうど
      end
    end

    it "未割当は退勤成功 + 全列 NULL のまま" do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 0)) # work_pattern なし
      travel_to Time.utc(2026, 6, 1, 9) do
        result = described_class.call(user:)
        expect(result).to be_success
        expect(result.record.actual_work_hours).to be_nil
      end
    end

    it "Recalculate の例外でも退勤は保全される（R4: rescue + Rails.error.report・8 列 NULL）" do
      record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                      clock_in: Time.utc(2026, 6, 1, 0), work_pattern: create(:work_pattern))
      allow(Clockings::Recalculate).to receive(:call).and_raise(RuntimeError, "calc bug")
      expect(Rails.error).to receive(:report) # kwargs まで縛らない（matcher の kwargs 互換罠を避ける）

      travel_to Time.utc(2026, 6, 1, 9) do
        result = described_class.call(user:)
        expect(result).to be_success
        expect(record.reload).to be_clocked_out
        expect(record.actual_work_hours).to be_nil
      end
    end

    it "打刻はサブ秒を持たない（usec 切り詰め — 9:00:00 ちょうど打刻の偽遅刻防止）" do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 0))
      # travel_to は既定で usec を 0 に切り詰めるため with_usec: true で本物のサブ秒を再現する
      travel_to Time.utc(2026, 6, 1, 9, 0, 0, 123_456), with_usec: true do
        result = described_class.call(user:)
        expect(result.record.clock_out.usec).to eq(0)
      end
    end
  end
end
