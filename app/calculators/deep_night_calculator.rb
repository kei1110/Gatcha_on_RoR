# 深夜労働（SPEC §5.3・1-2 設計 §3.3）: 隣接 2 窓との重複 − 休憩按分。整数分を返す純粋関数。
# 深夜帯は法定帯でパターン非依存 — フレックス・夜勤・mode_conflict すべてロジック同一（免除なし）。
# 労基法 37 条 4 項「午後十時から午前五時まで」— 法定値・テナント改変不可。
# 出典: https://laws.e-gov.go.jp/law/322AC0000000049（原典照合 2026-06-13）
class DeepNightCalculator
  NIGHT_START_HOUR = 22
  NIGHT_END_HOUR = 5

  # 定義域: clock_out < D+1 22:00 を前提（第 3 窓は数えない）。ClockOut の window 探索（前日まで）と
  # 4-2 打刻漏れバッチが上流で抑止する（1-2 設計 §3.3 — spec で現挙動を pin 済み）
  def self.call(clock_in:, clock_out:, break_minutes:, work_date:, zone:)
    overlap_seconds = windows(work_date, zone).sum do |from, to|
      [ [ clock_out, to ].min - [ clock_in, from ].max, 0 ].max
    end
    overlap_minutes = (overlap_seconds / 60).floor # 2 窓の秒を合算してから 1 回だけ floor（R1）
    presence_minutes = MinuteConversion.minutes_between(clock_in, clock_out)
    return 0 if overlap_minutes.zero? || presence_minutes.zero?

    # 休憩按分（SPEC §5.3 Step 2）: FLOOR = 控除を小さく = 労働者有利。
    # presence は gross 在席分（休憩込み）— 整数除算が床関数を兼ねる
    deep_night_break = break_minutes * overlap_minutes / presence_minutes
    [ overlap_minutes - deep_night_break, 0 ].max
  end

  # 出勤日 D 基準の隣接 2 窓: [D−1 22:00, D 5:00] と [D 22:00, D+1 5:00]（SPEC §5.3 Step 1 —
  # 単窓では早朝シフトの D 0:00〜5:00 帯を取りこぼす・1-1 設計レビュー補正）
  def self.windows(work_date, zone)
    [
      [ boundary(work_date - 1, zone, NIGHT_START_HOUR), boundary(work_date, zone, NIGHT_END_HOUR) ],
      [ boundary(work_date, zone, NIGHT_START_HOUR), boundary(work_date + 1, zone, NIGHT_END_HOUR) ]
    ]
  end
  private_class_method :windows

  def self.boundary(date, zone, hour) = zone.local(date.year, date.month, date.day, hour)
  private_class_method :boundary
end
