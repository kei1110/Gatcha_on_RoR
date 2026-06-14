# frozen_string_literal: true

# 実労働時間（SPEC §5.1・1-2 設計 §3.1）: 退勤 − 出勤 − 休憩。整数分を返す純粋関数。
# 夜勤の翌日換算は打刻側には不要（clock_in/clock_out は実時刻 — 差分が自然に正）
class WorkTimeCalculator
  def self.call(clock_in:, clock_out:, window:, day_part:)
    presence = MinuteConversion.minutes_between(clock_in, clock_out)
    [ presence - window.break_minutes_for(day_part), 0 ].max
  end
end
