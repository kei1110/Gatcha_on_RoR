# frozen_string_literal: true

# 残業 2 系統（SPEC §5.2 補正後・1-2 設計 §3.2）。整数分の Data を返す純粋関数。
# - legal: 実労働 8h 超のみ（所定に依存しない — 半休でも閾値不変）。所定超過の表示は scheduled が担う
# - scheduled: 時刻基準（退勤 − 所定終業）。半休・フレックスでも同式 — 所定終業の定義は end_at が唯一
class OvertimeCalculator
  Result = Data.define(:legal_overtime_minutes, :scheduled_overtime_minutes)

  # 労基法 32 条 2 項「休憩時間を除き一日について八時間」— 法定値・テナント改変不可（SPEC §8 原則）。
  # 出典: https://laws.e-gov.go.jp/law/322AC0000000049（原典照合 2026-06-13）
  LEGAL_DAILY_MINUTES = 480

  def self.call(actual_work_minutes:, clock_out:, window:)
    Result.new(
      legal_overtime_minutes: [ actual_work_minutes - LEGAL_DAILY_MINUTES, 0 ].max,
      scheduled_overtime_minutes:
        [ MinuteConversion.minutes_between(window.end_at, clock_out), 0 ].max
    )
  end
end
