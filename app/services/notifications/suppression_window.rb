# frozen_string_literal: true

module Notifications
  # email 抑制判定の純 PORO（SPEC §4.15・設計 §4.2 / §9①②）。
  # AR 読み取り（preference 解決・休日判定）は Notifier が行い、解決済み値だけを注入する。
  # これにより DB なしで境界算術を網羅テストできる（§2.2-1 PORO 契約）。
  # quiet hours: start 包含・end 排他。start>end は日跨ぎ、start==end は空窓（非抑制）。
  class SuppressionWindow
    def initialize(now_local:, quiet_enabled:, quiet_start:, quiet_end:, holiday_block:, holiday:)
      @now_local = now_local
      @quiet_enabled = quiet_enabled
      @quiet_start = quiet_start
      @quiet_end = quiet_end
      @holiday_block = holiday_block
      @holiday = holiday
    end

    def suppressed?
      in_quiet_hours? || holiday_blocked?
    end

    # 抑制終了時刻（組織ローカル）。両方抑制中なら遅い方。非抑制なら now_local。
    def next_allowed_at
      return @now_local unless suppressed?

      candidates = []
      candidates << quiet_hours_end_at if in_quiet_hours?
      candidates << next_day_start if holiday_blocked?
      candidates.max
    end

    private

    def in_quiet_hours?
      return false unless @quiet_enabled
      return false if @quiet_start == @quiet_end # 空窓

      hour = @now_local.hour
      if @quiet_start < @quiet_end
        hour >= @quiet_start && hour < @quiet_end       # 非日跨ぎ
      else
        hour >= @quiet_start || hour < @quiet_end       # 日跨ぎ
      end
    end

    def holiday_blocked?
      @holiday_block && @holiday
    end

    # quiet_end 時の次の到来（now より後の最初の quiet_end:00）
    def quiet_hours_end_at
      candidate = @now_local.change(hour: @quiet_end, min: 0, sec: 0)
      candidate <= @now_local ? candidate + 1.day : candidate
    end

    def next_day_start
      (@now_local + 1.day).beginning_of_day
    end
  end
end
