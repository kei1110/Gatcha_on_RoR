# frozen_string_literal: true

require "rails_helper"

# 純関数ゆえ DB もテナント文脈も不要（§10③）
RSpec.describe AttendanceAnomalies::Detector do
  describe ".clock_out_missing?" do
    def call(**overrides)
      described_class.clock_out_missing?(
        **{ status: "working", clock_in_present: true, clock_out_present: false, night_shift: false }.merge(overrides)
      )
    end

    it "working・打刻あり・退勤なし・非夜勤 → true" do
      expect(call).to be(true)
    end

    it "morning_half / afternoon_half も対象" do
      expect(call(status: "morning_half")).to be(true)
      expect(call(status: "afternoon_half")).to be(true)
    end

    it "退勤済（clock_out あり）→ false" do
      expect(call(clock_out_present: true)).to be(false)
    end

    it "出勤打刻なし（clock_in なし）→ false（休暇承認のみ等の誤検知防止）" do
      expect(call(clock_in_present: false)).to be(false)
    end

    it "夜勤 → false（勤務中の可能性・翌 run へ deferral・§10⑪）" do
      expect(call(night_shift: true)).to be(false)
    end

    it "clock 対象外 status（clocked_out / on_leave / absent）→ false" do
      expect(call(status: "clocked_out")).to be(false)
      expect(call(status: "on_leave")).to be(false)
      expect(call(status: "absent")).to be(false)
    end
  end

  describe ".no_clock_anomaly" do
    def call(**overrides)
      described_class.no_clock_anomaly(
        **{ covering_leave_applying: false, has_covering_leave_request: false, working_day: true }.merge(overrides)
      )
    end

    it "申請中 LR 有 → :leave_pending_no_clock" do
      expect(call(covering_leave_applying: true, has_covering_leave_request: true)).to eq(:leave_pending_no_clock)
    end

    it "LR 皆無 ∧ 稼働日 → :absence_candidate" do
      expect(call).to eq(:absence_candidate)
    end

    it "非稼働日 → nil（LR 皆無でも候補にしない・判断 E）" do
      expect(call(working_day: false)).to be_nil
    end

    it "LR 有（申請中でない・承認/却下/取消等）∧ 稼働日 → nil（LR 全 status 除外・§10 是認）" do
      expect(call(covering_leave_applying: false, has_covering_leave_request: true)).to be_nil
    end

    it "申請中 LR は非稼働日でも管理者通知（申請中判定が稼働日に優先）" do
      expect(call(covering_leave_applying: true, has_covering_leave_request: true, working_day: false))
        .to eq(:leave_pending_no_clock)
    end
  end
end
