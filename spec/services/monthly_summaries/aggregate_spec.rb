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
end
