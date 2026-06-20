# frozen_string_literal: true

require "bigdecimal"

# 週 40h 超の法定時間外（SPEC §5.2・3-1 設計 §2・D8）。当該締め期間に帰属する週次法定時間外の合計を返す純粋関数。
# 【単位は時間(BigDecimal)で統一・D6】入力は AR の確定済み 2dp 時間値（分を保持しない）ゆえ MinuteConversion は使わない
#   ＝§2.2-1 の分単位中間計算規約からの明示的逸脱。将来「分へ揃える」手戻りを防ぐため本コメントを残す。
# 週は暦週（日曜起算・労基法 32 条 1 項／昭 63.1.1 基発 1 号）。期間帰属・法定休日/flextime 除外・重複控除を内包。
class WeeklyOvertimeCalculator
  WEEKLY_LEGAL_HOURS = BigDecimal("40") # 労基法 32 条 1 項・法定値固定（テナント改変不可）

  # period_range : Range<Date>（= AttendancePeriod#range）。土曜の帰属判定に使う。
  # days : [{ date:, actual_hours:, daily_legal_overtime_hours:, legal_holiday_work:, flextime: }, ...]
  def self.call(period_range:, days:)
    days.group_by { |d| d[:date].beginning_of_week(:sunday) }.sum(BigDecimal("0")) do |week_start, week_days|
      saturday = week_start + 6
      next BigDecimal("0") unless period_range.cover?(saturday)

      countable = week_days.reject { |d| d[:legal_holiday_work] || d[:flextime] }
      actual = countable.sum(BigDecimal("0")) { |d| d[:actual_hours] }
      daily  = countable.sum(BigDecimal("0")) { |d| d[:daily_legal_overtime_hours] }
      result = [ actual - WEEKLY_LEGAL_HOURS - daily, BigDecimal("0") ].max
      result.round(2)
    end
  end
end
