# frozen_string_literal: true

module LeaveRequests
  # 休暇撤回の逆操作（SPEC §7.6・§13.6・2-5 設計 §4.1）。
  # 呼び出し元: LeaveRequest#apply_withdrawal_effects!（Approvals::Approve の with_lock 内・同一 tx）。
  # 内側で rescue しない — raise 伝播で撤回承認ごと atomic rollback。
  # 処理順: ① 残高減算（balance_tracked? のみ・lock!）→ ② 範囲内 leave-status AR を復元/destroy → ③ leave_withdrawn 履歴。
  class Withdraw
    def self.call(leave_request:, acting_user:) = new(leave_request:, acting_user:).call

    def initialize(leave_request:, acting_user:)
      @leave_request = leave_request
      @acting_user = acting_user
    end

    def call
      ActsAsTenant.with_tenant(@leave_request.organization) do
        remove_from_balance
        restore_attendance_records
        record_history
      end
      @leave_request
    end

    private

    # 正方向 add_to_balance と同一述語（paid_leave? || compensatory_leave?）。R2 残高リーク防止
    def remove_from_balance
      return unless @leave_request.leave_type.balance_tracked?

      fiscal_year = @leave_request.organization.fiscal_year_for(@leave_request.start_date)
      balance = LeaveBalance
                .where(user_id: @leave_request.requester_id,
                       leave_type_id: @leave_request.leave_type_id, fiscal_year:)
                .lock.first
      if balance.nil?
        Rails.error.report(StandardError.new("LeaveRequests::Withdraw: balance_tracked type has no balance row at withdrawal"), handled: true)
        return
      end

      new_used = balance.used_days - @leave_request.days_requested
      Rails.error.report(StandardError.new("withdraw underflow: balance would go negative"), handled: true) if new_used.negative?
      balance.update!(used_days: [ new_used, BigDecimal("0") ].max)
    end

    # counted_dates を再計算せず、範囲内で leave-status を持つ AR を直接巻き戻す（R3/R4）。
    # 1 日 1 AR（unique [user, work_date]）ゆえ範囲内 leave-status AR = この休暇の日。
    def restore_attendance_records
      AttendanceRecord
        .where(user_id: @leave_request.requester_id,
               work_date: @leave_request.start_date..@leave_request.end_date,
               status: %i[on_leave morning_half afternoon_half])
        .find_each do |record|
          if record.clock_in.blank?
            record.destroy!
          else
            record.update!(status: record.clock_out.present? ? :clocked_out : :working)
            Clockings::Recalculate.call(record:) if record.clock_out.present?
          end
        end
    end

    def record_history
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id, actor: @acting_user, source: @leave_request,
        event_type: :leave_withdrawn, event_date: @leave_request.start_date
      )
    end
  end
end
