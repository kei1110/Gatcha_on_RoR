# 遅刻・早退判定（SPEC §5.4・1-2 設計 §3.4）。Data を返す純粋関数。
# 固定時間制 = start_at/end_at 基準（秒厳密・分数 floor）。
# フレックス = コア基準の二値・分数 0 固定。mode_conflict は flex 判定が優先（1-2 設計 §0-2 —
# WorkTime/Overtime が読む night_shift 換算とは別カラムゆえ矛盾なく共存）。
# 半休の片側免除: morning_half = 遅刻免除 / afternoon_half = 早退免除（両制度共通）
class LateEarlyCalculator
  Result = Data.define(:is_late, :late_minutes, :is_early_leave, :early_leave_minutes)

  DAY_PARTS = %i[full morning_half afternoon_half].freeze

  def self.call(clock_in:, clock_out:, window:, flextime:, day_part:)
    raise ArgumentError, "unknown day_part: #{day_part.inspect}" unless DAY_PARTS.include?(day_part)

    late_threshold  = flextime ? window.core_start_at : window.start_at
    early_threshold = flextime ? window.core_end_at : window.end_at

    is_late = day_part != :morning_half && clock_in > late_threshold
    is_early_leave = day_part != :afternoon_half && clock_out < early_threshold

    Result.new(
      is_late:,
      late_minutes:
        is_late && !flextime ? MinuteConversion.minutes_between(late_threshold, clock_in) : 0,
      is_early_leave:,
      early_leave_minutes:
        is_early_leave && !flextime ? MinuteConversion.minutes_between(clock_out, early_threshold) : 0
    )
  end
end
