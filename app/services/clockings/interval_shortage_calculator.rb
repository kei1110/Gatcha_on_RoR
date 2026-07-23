# frozen_string_literal: true

module Clockings
  # 勤務間インターバル不足の純粋判定（SPEC §6.9・設計 §10③/§13④）。DB を触らない。
  # 11h ちょうど = 非違反・1 分でも下回れば違反（`<` 境界・§10⑧）。秒以下は floor で分に丸める
  # （10:59:59 の休息は 659 分 = 違反側・11:00:30 は 660 分 = 非違反側 — 実インターバルに忠実）。
  # 戻り値: 不足分（分・正の整数）。非違反・判定不能（prev なし）は nil
  class IntervalShortageCalculator
    def self.call(prev_clock_out:, clock_in:, threshold_hours:)
      return nil if prev_clock_out.nil?

      interval_minutes = ((clock_in - prev_clock_out) / 60).floor
      threshold_minutes = threshold_hours * 60
      return nil if interval_minutes >= threshold_minutes

      threshold_minutes - interval_minutes
    end
  end
end
