# WorkPattern × work_date → 組織 TZ 合成済み所定時刻群（1-2 設計 §2）。
# SPEC §5 入力契約（夜勤 +1.day・日跨ぎコア翌日換算・time 型の加算禁止）の単一実装点 —
# 合成規則をここ以外に書かないこと。
# pattern は duck: WorkPattern AR か、同名メソッドに応答する Struct（テストで DB 不要）。
# effective_* ヘルパ参照は WorkPattern のフォールバック規則（null → break/2）の単一ソース維持（0b-4）
class ScheduledWindow
  BREAK_METHODS = {
    full: :break_minutes,
    morning_half: :effective_morning_half_break_minutes,
    afternoon_half: :effective_afternoon_half_break_minutes
  }.freeze

  def self.for(pattern:, work_date:, zone:) = new(pattern, work_date, zone)

  def initialize(pattern, work_date, zone)
    @pattern = pattern
    @work_date = work_date
    @zone = zone
  end

  def start_at = at(@pattern.start_time)

  # 夜勤の日跨ぎ（night_shift かつ start > end）は翌日換算 — Time.zone 上の +1.day 合成
  def end_at
    base = at(@pattern.end_time)
    @pattern.night_shift? && @pattern.start_time > @pattern.end_time ? base + 1.day : base
  end

  def core_start_at
    return nil unless @pattern.flextime?

    at(@pattern.core_time_start)
  end

  # 日跨ぎコア（night_shift かつ core start > end）も同規則で翌日換算（SPEC §5 入力契約・R7）
  def core_end_at
    return nil unless @pattern.flextime?

    base = at(@pattern.core_time_end)
    @pattern.night_shift? && @pattern.core_time_start > @pattern.core_time_end ? base + 1.day : base
  end

  # day_part: :full | :morning_half | :afternoon_half（§4.8 の将来 status 名と整合）。
  # 不正値は fetch で即例外（fail-fast — 1-1 CalendarComponent と同方式）
  def break_minutes_for(day_part) = @pattern.public_send(BREAK_METHODS.fetch(day_part))

  private

  def at(time)
    @zone.local(@work_date.year, @work_date.month, @work_date.day, time.hour, time.min, time.sec)
  end
end
