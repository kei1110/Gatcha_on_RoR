# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::Aggregate do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:user) { create(:user, organization: org) }

  def period(year_month) = AttendancePeriod.new(organization: org, year_month:)

  # 計算済み（clocked_out）の出勤日を 1 件作る helper。calc 8 列を明示。
  def worked(date, actual:, legal_ot: 0, deep_night: 0, late: false, early: false, holiday_work: false, status: :clocked_out)
    create(:attendance_record, user:, work_date: date, status:,
           clock_in: Time.utc(date.year, date.month, date.day, 0),
           clock_out: Time.utc(date.year, date.month, date.day, 9),
           is_holiday_work: holiday_work,
           actual_work_hours: actual, legal_overtime_hours: legal_ot, scheduled_overtime_hours: 0,
           deep_night_hours: deep_night, is_late: late, late_minutes: 0,
           is_early_leave: early, early_leave_minutes: 0)
  end

  describe "締め期間（closing_day≠31）" do
    it "closing_day=25 は前月26日〜当月25日のみ集計（暦月ハードコードなら落ちる）" do
      org.setting.update!(closing_day: 25)
      worked(Date.new(2026, 2, 26), actual: 8)
      worked(Date.new(2026, 3, 25), actual: 8)
      worked(Date.new(2026, 3, 26), actual: 8) # 翌期
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.work_days).to eq(2)
      expect(summary.total_work_hours).to eq(8 + 8)
    end
  end

  describe "日次集計の基本列" do
    it "total_work_hours / total_deep_night_hours / late_days / early_leave_days を集計" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 2), actual: 8, deep_night: 1.5, late: true)
      worked(Date.new(2026, 3, 3), actual: 7, deep_night: 0, early: true)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary).to have_attributes(
        work_days: 2, total_work_hours: 15, total_deep_night_hours: 1.5,
        late_days: 1, early_leave_days: 1
      )
    end
  end

  describe "出勤系 status ゲート（D10・#104 stale 行の除外）" do
    it "on_leave（計算列 stale 残留）は work_days/total_work_hours に乗らない" do
      org.setting.update!(closing_day: 31)
      # #104: 打刻済(clocked_out・計算列 non-NULL)の日が全休承認で on_leave へ上書き＋stale 残留
      worked(Date.new(2026, 3, 2), actual: 9, status: :on_leave)
      worked(Date.new(2026, 3, 3), actual: 8) # 正常な出勤日
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.work_days).to eq(1)
      expect(summary.total_work_hours).to eq(8) # on_leave の 9h は除外
    end
  end

  describe "未計算行の除外（計算 8 列 NULL の出勤行を母数に乗せない・P2 回帰）" do
    it "未退勤の working 行は work_days/total_work_hours に乗らない" do
      org.setting.update!(closing_day: 31)
      # 未退勤 working = 計算 8 列 NULL（Recalculate は working に呼ばない・recalculate.rb:9）。
      # 母数に乗ると「出勤日 +1・労働時間 0」の水増しが永久サマリへ焼き付く。
      create(:attendance_record, user:, work_date: Date.new(2026, 3, 2), status: :working,
             clock_in: Time.utc(2026, 3, 2, 0)) # 計算列なし
      worked(Date.new(2026, 3, 3), actual: 8) # 正常な計算済み出勤日
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.work_days).to eq(1)
      expect(summary.total_work_hours).to eq(8)
    end

    it "打刻前の半休 morning_half（休暇承認の副作用・8 列 NULL）も母数に乗らない" do
      org.setting.update!(closing_day: 31)
      # 半休承認だけで打刻が無い → leave_status ゆえ clock_in nil 可・計算列 NULL（2-2b）。
      create(:attendance_record, user:, work_date: Date.new(2026, 3, 2), status: :morning_half,
             clock_in: nil)
      worked(Date.new(2026, 3, 3), actual: 8)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.work_days).to eq(1)
      expect(summary.total_work_hours).to eq(8)
    end
  end

  describe "scheduled_work_days（暦由来・AR 非依存）" do
    it "period.range 内の weekday 日数（出勤実態と独立）" do
      org.setting.update!(closing_day: 31)
      # 2026-03 の平日数（resolver フォールバック weekday）。土日と登録祝日を除く。
      summary = described_class.call(user:, period: period("2026-03"))
      weekday_count = (Date.new(2026, 3, 1)..Date.new(2026, 3, 31)).count { |d| (1..5).cover?(d.cwday) }
      expect(summary.scheduled_work_days).to eq(weekday_count)
    end
  end

  describe "day_types 注入（③ 一括の共有経路）" do
    it "day_types を渡すと resolver を呼ばない" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 2), actual: 8)
      injected = (Date.new(2026, 2, 22)..Date.new(2026, 3, 31)).index_with { :weekday }
      expect(CompanyCalendarResolver).not_to receive(:new)
      described_class.call(user:, period: period("2026-03"), day_types: injected)
    end
  end

  describe "テナント分離 / 防御ラップ" do
    it "他社の同期間 AR を集計に混ぜない" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 2), actual: 8)
      other = create(:organization)
      ActsAsTenant.with_tenant(other) do
        ou = create(:user, organization: other)
        create(:attendance_record, :done, user: ou, work_date: Date.new(2026, 3, 2),
               actual_work_hours: 99, legal_overtime_hours: 0, scheduled_overtime_hours: 0,
               deep_night_hours: 0, is_late: false, late_minutes: 0, is_early_leave: false, early_leave_minutes: 0)
      end
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.total_work_hours).to eq(8)
    end

    it "current_tenant 未設定の素文脈からでも自己完結（防御ラップ回帰）" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 2), actual: 8)
      p = period("2026-03")
      ActsAsTenant.without_tenant do
        expect { described_class.call(user:, period: p) }.not_to raise_error
      end
    end
  end

  describe "2 系統分離（本スライスの存在意義・#108）" do
    it "法定休日労働は holiday_work へ・total_overtime に寄与しない（日次/週次 2 経路の除外）" do
      org.setting.update!(closing_day: 31)
      d = Date.new(2026, 3, 1) # 日曜
      create(:company_calendar, date: d, day_type: :legal_holiday)
      worked(d, actual: 10, legal_ot: 2, holiday_work: true)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.holiday_work_hours).to eq(10)
      expect(summary.total_overtime_hours).to eq(0)
    end

    it "holiday_work 負例: is_holiday_work でも day_type≠legal_holiday（sunday フォールバック）は holiday_work=0" do
      org.setting.update!(closing_day: 31)
      d = Date.new(2026, 3, 1) # 日曜・CompanyCalendar 未登録 → resolver は :sunday
      worked(d, actual: 8, holiday_work: true)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.holiday_work_hours).to eq(0)
    end

    it "所定休日土曜の出勤は holiday_work に入らない" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 7), actual: 8, holiday_work: false) # 土曜
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.holiday_work_hours).to eq(0)
    end
  end

  describe "週 40h 統合" do
    it "所定 7h×6 日(月〜土)=42h・日次 OT 0 → total_overtime 2h（週次のみ）" do
      org.setting.update!(closing_day: 31)
      (2..7).each { |d| worked(Date.new(2026, 3, d), actual: 7, legal_ot: 0) } # Mon..Sat
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.total_overtime_hours).to eq(2)
    end

    it "末尾週が翌期へ（月末≠土曜）: その週の週次 OT は当期に乗らない" do
      org.setting.update!(closing_day: 31)
      # 2026-03-31 は火曜。週 3/29(日)〜4/4(土) は土曜 4/4 が 4 月 → 当期(3月)に計上しない。
      # 3/29(日)・3/30・3/31 を各 14h（週 42h）。誤って当期へ計上されれば extra=2h になる強い負例。
      (29..31).each { |d| worked(Date.new(2026, 3, d), actual: 14, legal_ot: 0) }
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.total_overtime_hours).to eq(0)
    end
  end

  describe "60h 境界 3 点" do
    it "total_overtime 59.99/60.00/60.01 → over_60 0/0/0.01" do
      org.setting.update!(closing_day: 31)
      # 日次 legal OT のみで total_overtime を作る（平日 1 日に集約・週 40h は跨がない値）
      { "59.99" => "0", "60.00" => "0", "60.01" => "0.01" }.each do |total, expected_over|
        MonthlyAttendanceSummary.delete_all
        AttendanceRecord.where(user:).delete_all
        worked(Date.new(2026, 3, 3), actual: BigDecimal("8") + BigDecimal(total), legal_ot: BigDecimal(total))
        summary = described_class.call(user:, period: period("2026-03"))
        expect(summary.total_overtime_hours).to eq(BigDecimal(total))
        expect(summary.overtime_hours_over_60).to eq(BigDecimal(expected_over))
      end
    end
  end

  describe "管理監督者(exempt)×深夜（ゼロ化バグを殺す）" do
    it "exempt でも深夜・残業を生値で保存（D5・§8.3）" do
      org.setting.update!(closing_day: 31)
      exempt = create(:user, organization: org, exempt_from_overtime: true)
      create(:attendance_record, user: exempt, work_date: Date.new(2026, 3, 3), status: :clocked_out,
             clock_in: Time.utc(2026, 3, 3, 0), clock_out: Time.utc(2026, 3, 3, 12),
             is_holiday_work: false, actual_work_hours: 10, legal_overtime_hours: 2, scheduled_overtime_hours: 0,
             deep_night_hours: 1.5, is_late: false, late_minutes: 0, is_early_leave: false, early_leave_minutes: 0)
      summary = described_class.call(user: exempt, period: period("2026-03"))
      expect(summary.total_deep_night_hours).to eq(1.5)
      expect(summary.total_overtime_hours).to eq(2)
    end
  end

  describe "冪等性（行数不変 + 追従）" do
    it "2 回 call で count 不変・id 不変、AR 追加で値が追従" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 3), actual: 8)
      first = described_class.call(user:, period: period("2026-03"))
      expect { described_class.call(user:, period: period("2026-03")) }
        .not_to change { MonthlyAttendanceSummary.count }
      again = described_class.call(user:, period: period("2026-03"))
      expect(again.id).to eq(first.id)

      worked(Date.new(2026, 3, 4), actual: 5)
      updated = described_class.call(user:, period: period("2026-03"))
      expect(updated.total_work_hours).to eq(8 + 5) # 古い値が残らずフル上書き
    end
  end

  describe "期初週が前期 tail を週次母数に含む（F2 前方カップリングの seam・closing_day=25）" do
    it "前期 tail 日を含む週で週40h超を当期へ計上（range 外日も週の母数に効く）" do
      org.setting.update!(closing_day: 25)
      # period "2026-03" = 2/26..3/25。第1週 2/22(日)..2/28(土)、土曜 2/28 ∈ range ゆえ当期へ帰属。
      # 2/22..2/25 は前期 tail（range 外）、2/26..2/28 は range 内。全 7 日 × 6h = 42h → 週次 extra 2h。
      (22..28).each { |d| worked(Date.new(2026, 2, d), actual: 6, legal_ot: 0) }
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.work_days).to eq(3)            # range 内（2/26-28）のみ
      expect(summary.total_overtime_hours).to eq(2) # 週次は前期 tail 込みの 42h で算出（range だけなら 18h<40 で 0）
    end
  end

  describe "休暇集計の合成（3-3a・§3.2）" do
    let(:paid_type) { create(:leave_type, system_type: :annual, paid_leave: true) }

    it "paid_leave_days_used / total_leave_hours を MAS に保存" do
      org.setting.update!(closing_day: 31)
      create(:user_work_pattern, user:, start_date: Date.new(2026, 1, 1),
             work_pattern: create(:work_pattern, standard_work_hours: 8))
      create(:attendance_record, user:, work_date: Date.new(2026, 3, 2),
             status: :on_leave, clock_in: nil, leave_type: paid_type)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.paid_leave_days_used).to eq(1)
      expect(summary.total_leave_hours).to eq(8)
    end

    it "休暇は worked 集計（work_days/total_work_hours）に混入しない" do
      org.setting.update!(closing_day: 31)
      create(:attendance_record, user:, work_date: Date.new(2026, 3, 2),
             status: :on_leave, clock_in: nil, leave_type: paid_type)
      worked(Date.new(2026, 3, 3), actual: 8)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.work_days).to eq(1)
      expect(summary.total_work_hours).to eq(8)
      expect(summary.paid_leave_days_used).to eq(1)
    end
  end
end
