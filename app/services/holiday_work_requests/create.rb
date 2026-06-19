# frozen_string_literal: true

module HolidayWorkRequests
  # 休日出勤申請の作成（2-4 設計 §2.1）。1 tx で HWR 作成 + 承認エンジン起動。
  # requester は呼び出し側が current_user を渡す（params 由来の id を受けない）。
  class Create
    def self.call(requester:, work_date:, compensation_leave_type:, reason:)
      new(requester:, work_date:, compensation_leave_type:, reason:).call
    end

    def initialize(requester:, work_date:, compensation_leave_type:, reason:)
      @requester = requester
      @work_date = work_date
      @compensation_leave_type = compensation_leave_type
      @reason = reason
    end

    def call
      ActiveRecord::Base.transaction do
        hwr = HolidayWorkRequest.create!(
          requester: @requester, work_date: @work_date,
          compensation_leave_type: @compensation_leave_type, reason: @reason
        )
        Approvals::Start.call(hwr)   # ルート解決 + pending assignment（既存エンジン）
        hwr
      end
    end
  end
end
