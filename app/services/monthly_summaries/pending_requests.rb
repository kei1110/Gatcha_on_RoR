# frozen_string_literal: true

module MonthlySummaries
  # 提出前チェック（SPEC §6.6・3-2 設計 §3.1・D6）。
  # (user, period) の期間に重なる in-flight 申請（LR/CCR/HWR）を横断収集し、
  # 承認進行中（started）/ 未起動（not_started）に二分する。
  # Submit のゲートは any?（boolean）で足り、二分は UI 表示専用（N+1 回避）。
  class PendingRequests
    IN_FLIGHT = %w[applying withdrawal_requested].freeze

    def initialize(user:, period:)
      @user = user
      @period = period
    end

    def any? = in_flight_records.any?

    # 承認進行中 = active purpose に pending でない assignment が存在
    def started = @started ||= in_flight_records.select { |r| acted?(r) }

    def not_started = @not_started ||= in_flight_records.reject { |r| acted?(r) }

    private

    def range = @period.range

    def in_flight_records
      @in_flight_records ||= leave_requests + clock_change_requests + holiday_work_requests
    end

    def leave_requests
      LeaveRequest.where(requester: @user, approval_status: IN_FLIGHT)
                  .where("start_date <= ? AND end_date >= ?", range.last, range.first).to_a
    end

    def clock_change_requests
      ClockChangeRequest.where(requester: @user, approval_status: IN_FLIGHT)
                        .joins(:attendance_record)
                        .where(attendance_records: { work_date: range }).to_a
    end

    def holiday_work_requests
      # HWR は Approvable のみ（withdrawal_requested 状態なし）。applying のみが in-flight
      HolidayWorkRequest.where(requester: @user, approval_status: :applying)
                        .where(work_date: range).to_a
    end

    # active purpose に decision != pending の assignment が 1 件でもあれば「起動済み」
    def acted?(record)
      record.approval_assignments
            .where(purpose: record.active_purpose)
            .where.not(decision: :pending).exists?
    end
  end
end
