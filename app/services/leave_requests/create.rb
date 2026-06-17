# app/services/leave_requests/create.rb
# frozen_string_literal: true

module LeaveRequests
  # 申請作成（Phase 2-2a 設計 §3.2）。days_requested をサーバ確定 → save! → Approvals::Start を
  # 1 tx。RouteError（manager 未設定・§7.2）は tx ロールバックで host・assignment ともに未永続。
  class Create
    def self.call(requester:, leave_type:, start_date:, end_date:, half_day_type:, reason:)
      new(requester, leave_type, start_date, end_date, half_day_type, reason).call
    end

    def initialize(requester, leave_type, start_date, end_date, half_day_type, reason)
      @requester = requester
      @leave_type = leave_type
      @start_date = start_date
      @end_date = end_date
      @half_day_type = half_day_type
      @reason = reason
    end

    def call
      ActiveRecord::Base.transaction do
        est = Estimate.call(requester: @requester, leave_type: @leave_type,
                            start_date: @start_date, end_date: @end_date, half_day_type: @half_day_type)
        record = LeaveRequest.create!(
          requester: @requester, leave_type: @leave_type, start_date: @start_date,
          end_date: @end_date, half_day_type: @half_day_type, reason: @reason,
          days_requested: est.days_requested
        )
        Approvals::Start.call(record)
        record
      end
    end
  end
end
