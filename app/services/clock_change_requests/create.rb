# frozen_string_literal: true

module ClockChangeRequests
  # 打刻変更申請の作成（2-3 設計 §3.1）。1 tx で CCR 作成 + 承認エンジン起動。
  # original_* は対象記録から snapshot（サーバ権威・§7.4 競合チェック用）。
  # requester は呼び出し側が current_user を渡す（params 由来の id を受けない）。
  class Create
    def self.call(requester:, attendance_record:, change_type:, new_clock_in:, new_clock_out:, reason:)
      new(requester:, attendance_record:, change_type:, new_clock_in:, new_clock_out:, reason:).call
    end

    def initialize(requester:, attendance_record:, change_type:, new_clock_in:, new_clock_out:, reason:)
      @requester = requester
      @attendance_record = attendance_record
      @change_type = change_type
      @new_clock_in = new_clock_in
      @new_clock_out = new_clock_out
      @reason = reason
    end

    def call
      ActiveRecord::Base.transaction do
        ccr = ClockChangeRequest.create!(
          requester: @requester, attendance_record: @attendance_record,
          change_type: @change_type, reason: @reason,
          new_clock_in: @new_clock_in, new_clock_out: @new_clock_out,
          original_clock_in: @attendance_record.clock_in,     # snapshot（サーバ権威）
          original_clock_out: @attendance_record.clock_out
        )
        Approvals::Start.call(ccr)   # ルート解決 + pending assignment（既存エンジン）
        ccr
      end
    end
  end
end
