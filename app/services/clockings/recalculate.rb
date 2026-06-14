# frozen_string_literal: true

module Clockings
  # 計算 8 列の書き戻し唯一経路（1-2 設計 §4）。退勤打刻のほか 2-2/2-3 打刻変更承認・
  # Phase 2 休暇承認の再計算もこの入口に合流する（SPEC §4.8）。
  # 例外は投げ得る — rescue は呼び出し側の責務（ClockOut は打刻保全 + Rails.error.report・R4）。
  # 未割当（pattern nil）は何もしない: 全列 NULL = 未計算の意味論（brainstorm 決定 3）。
  # 計算済みレコードのパターンが外れた場合も残置（クリアしない — 2-2 の再計算設計で再訪）。
  # 前提: clock_out 設定済み（working には呼ばない — 2-2 で入口合流する際に明示ガードを追加）
  class Recalculate
    def self.call(record:) = new(record).call

    def initialize(record)
      @record = record
    end

    def call
      ActsAsTenant.with_tenant(@record.organization) do
        pattern = @record.work_pattern
        next @record if pattern.nil?

        zone = ActiveSupport::TimeZone[@record.organization.time_zone]
        window = ScheduledWindow.for(pattern:, work_date: @record.work_date, zone:)
        clock_in = @record.clock_in.in_time_zone(zone)   # §5 入力契約: 組織 TZ 変換済みを渡す
        clock_out = @record.clock_out.in_time_zone(zone)
        day_part = :full # Phase 2 で status（morning_half 等）から導出

        actual = WorkTimeCalculator.call(clock_in:, clock_out:, window:, day_part:)
        overtime = OvertimeCalculator.call(actual_work_minutes: actual, clock_out:, window:)
        # break は day_part 解決済みの値を渡す — 実際に控除した休憩と按分母体を一致させる
        deep_night = DeepNightCalculator.call(
          clock_in:, clock_out:, break_minutes: window.break_minutes_for(day_part),
          work_date: @record.work_date, zone:)
        late_early = LateEarlyCalculator.call(
          clock_in:, clock_out:, window:, flextime: pattern.flextime?, day_part:)

        @record.update!(
          actual_work_hours: MinuteConversion.to_hours(actual),
          legal_overtime_hours: MinuteConversion.to_hours(overtime.legal_overtime_minutes),
          scheduled_overtime_hours: MinuteConversion.to_hours(overtime.scheduled_overtime_minutes),
          deep_night_hours: MinuteConversion.to_hours(deep_night),
          is_late: late_early.is_late,
          late_minutes: late_early.late_minutes,
          is_early_leave: late_early.is_early_leave,
          early_leave_minutes: late_early.early_leave_minutes
        )
        @record
      end
    end
  end
end
