# frozen_string_literal: true

require "bigdecimal"

module MonthlySummaries
  # 休暇集計（SPEC §6.4・§4.13・3-3 設計 §3.1）。
  # period.range 内の leave-status AR を直接読む（counted_dates 非再計算＝drift なし・D5）。
  # paid_leave_days_used（paid 種別のみ・日/半 0.5）と total_leave_hours（全種別・所定時間換算）を返す。
  # 計算 8 列は読まない（status / leave_type / standard_work_hours のみ）ゆえ .calculated を課さない。
  class LeaveAggregator
    HALF_STATUSES = %w[morning_half afternoon_half].freeze

    def self.call(user:, period:) = new(user:, period:).call

    def initialize(user:, period:)
      @user = user
      @period = period
    end

    def call
      ActsAsTenant.with_tenant(@user.organization) do
        {
          paid_leave_days_used: leave_records.sum(BigDecimal("0")) { paid_weight(_1) },
          total_leave_hours:    leave_records.sum(BigDecimal("0")) { hours_for(_1) }
        }
      end
    end

    private

    def leave_records
      @leave_records ||= AttendanceRecord
        .where(user: @user, work_date: @period.range, status: AttendanceRecord::LEAVE_STATUSES)
        .includes(:leave_type, :work_pattern).to_a
    end

    def weight(record) = HALF_STATUSES.include?(record.status) ? BigDecimal("0.5") : BigDecimal("1")

    def paid_weight(record) = record.leave_type&.paid_leave? ? weight(record) : BigDecimal("0")

    def hours_for(record)
      hours = standard_hours_on(record)
      return BigDecimal("0") if hours.nil?

      HALF_STATUSES.include?(record.status) ? hours / 2 : hours
    end

    # §6.1 スナップショット優先: 半休+打刻 AR は work_pattern_id を持つ → record.work_pattern。
    # 純休暇日（work_pattern_id NULL）のみ effective 割当を解決し worked 集計と同日で乖離させない。
    def standard_hours_on(record)
      pattern = record.work_pattern || effective_pattern_on(record.work_date)
      pattern&.standard_work_hours
    end

    def effective_pattern_on(date)
      user_assignments.find do |a|
        a.start_date <= date && (a.end_date.nil? || a.end_date >= date)
      end&.work_pattern
    end

    # active 割当を 1 回ロード（N+1 回避・effective_on と同条件）
    def user_assignments
      @user_assignments ||= @user.user_work_patterns.where(active: true).includes(:work_pattern).to_a
    end
  end
end
