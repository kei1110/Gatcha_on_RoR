# frozen_string_literal: true

module LeaveRequests
  # 見積りの単一ソース（Phase 2-2a 設計 §3.1・F2）。フォーム初期描画・preview・Create が共有。
  # requester は呼び出し側で current_user に固定（§3.2・MPR C3）— 他者の残高を読まない。
  class Estimate
    Result = Data.define(
      :days_requested, :fiscal_year, :paid_leave,
      :confirmed_remaining, :provisional_remaining, :remaining_after
    ) do
      def status
        return nil if remaining_after.nil?

        remaining_after.positive? ? :positive : (remaining_after.zero? ? :zero : :negative)
      end
    end

    def self.call(requester:, leave_type:, start_date:, end_date:, half_day_type:)
      new(requester, leave_type, start_date, end_date, half_day_type.to_sym).call
    end

    def initialize(requester, leave_type, start_date, end_date, half_day_type)
      @requester = requester
      @leave_type = leave_type
      @start_date = start_date
      @end_date = end_date
      @half_day_type = half_day_type
    end

    def call
      validate_input!
      days = leave_days
      fy = @requester.organization.fiscal_year_for(@start_date)
      confirmed, provisional = balances(fy)
      Result.new(
        days_requested: days, fiscal_year: fy, paid_leave: @leave_type.paid_leave?,
        confirmed_remaining: confirmed,
        provisional_remaining: provisional,
        remaining_after: provisional && (provisional - days)
      )
    end

    private

    # 半休は単日（calculator 呼出前の fail-closed・MPR）。span 上限も見積り段階で弾く
    def validate_input!
      if @half_day_type != :none && @start_date != @end_date
        raise ArgumentError, "半休は単日申請でのみ指定できます"
      end
      if (@end_date - @start_date).to_i > LeaveRequest::MAX_SPAN_DAYS
        raise ArgumentError, "申請可能な期間を超えています"
      end
    end

    def leave_days
      classifications =
        CompanyCalendarResolver.new(organization: @requester.organization)
                               .day_classifications(@start_date, @end_date)
      LeaveDaysCalculator.call(classifications:, half_day_type: @half_day_type)
    end

    # paid_leave 種別のみ残高算出。非 paid は [nil, nil]
    def balances(fiscal_year)
      return [ nil, nil ] unless @leave_type.paid_leave?

      balance = LeaveBalance.find_by(user: @requester, leave_type: @leave_type, fiscal_year:)
      confirmed = balance&.remaining || BigDecimal("0")
      [ confirmed, confirmed - provisional_used(fiscal_year) ]
    end

    # 同一申請者・同一種別で applying かつ start_date が当該年度に属する days_requested の和（C1）
    def provisional_used(fiscal_year)
      LeaveRequest.where(requester: @requester, leave_type: @leave_type, approval_status: :applying)
                  .where(start_date: @requester.organization.fiscal_year_range(fiscal_year))
                  .sum(:days_requested)
    end
  end
end
