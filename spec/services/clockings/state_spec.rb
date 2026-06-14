# frozen_string_literal: true

require "rails_helper"

# 時刻リテラルはすべて UTC。org の TZ 既定は Asia/Tokyo（= UTC+9）
RSpec.describe Clockings::State do
  let(:user) { create(:user) }

  def state = described_class.new(user:)

  context "レコードなし（未出勤）" do
    it "off_duty・出勤のみ活性・バナーなし" do
      travel_to Time.utc(2026, 6, 1, 1) do
        expect(state.status).to eq(:off_duty)
        expect(state.can_clock_in?).to be(true)
        expect(state.can_clock_out?).to be(false)
        expect(state.stale_working_record).to be_nil
      end
    end
  end

  context "当日 working（出勤中）" do
    before do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 0))
    end

    it "working・退勤のみ活性" do
      travel_to Time.utc(2026, 6, 1, 9) do
        expect(state.status).to eq(:working)
        expect(state.can_clock_in?).to be(false)
        expect(state.can_clock_out?).to be(true)
      end
    end

    it "夜勤の日付跨ぎ後も working（前日レコードを window で拾う）" do
      travel_to Time.utc(2026, 6, 1, 22) do # JST 6/2 07:00
        expect(state.status).to eq(:working)
        expect(state.can_clock_out?).to be(true)
        expect(state.can_clock_in?).to be(false)
      end
    end
  end

  context "当日 clocked_out（退勤済）" do
    before do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1), status: :clocked_out,
             clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 9))
    end

    it "clocked_out・両ボタン無効（ユーザー決定）" do
      travel_to Time.utc(2026, 6, 1, 10) do
        expect(state.status).to eq(:clocked_out)
        expect(state.can_clock_in?).to be(false)
        expect(state.can_clock_out?).to be(false)
      end
    end
  end

  context "window 外の取り残し working（退勤忘れ）" do
    before do
      create(:attendance_record, user:, work_date: Date.new(2026, 5, 29),
             clock_in: Time.utc(2026, 5, 29, 0))
    end

    it "stale_working_record が拾われ、表示は off_duty・出勤は活性（4-2 まで打刻は止めない）" do
      travel_to Time.utc(2026, 6, 1, 1) do
        expect(state.stale_working_record&.work_date).to eq(Date.new(2026, 5, 29))
        expect(state.status).to eq(:off_duty)
        expect(state.can_clock_in?).to be(true)
      end
    end

    it "window 内（前日）の working は stale ではない（still_working ガード側の領分）" do
      create(:attendance_record, user:, work_date: Date.new(2026, 5, 31),
             clock_in: Time.utc(2026, 5, 31, 0))
      travel_to Time.utc(2026, 6, 1, 1) do
        expect(state.stale_working_record&.work_date).to eq(Date.new(2026, 5, 29))
        expect(state.working_record.work_date).to eq(Date.new(2026, 5, 31))
      end
    end
  end

  describe "#unassigned_pattern?" do
    it "有効割当が無ければ true・あれば false" do
      travel_to Time.utc(2026, 6, 1, 1) do
        expect(state.unassigned_pattern?).to be(true)
      end

      create(:user_work_pattern, user:, start_date: Date.new(2026, 1, 1))
      travel_to Time.utc(2026, 6, 1, 1) do
        expect(state.unassigned_pattern?).to be(false)
      end
    end
  end
end
