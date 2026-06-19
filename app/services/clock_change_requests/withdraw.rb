# frozen_string_literal: true

module ClockChangeRequests
  # 打刻変更撤回の逆操作（SPEC §7.6・§13.6・2-5 設計 §4.2）。ApplyApproval の鏡像。
  # 呼び出し元: ClockChangeRequest#apply_withdrawal_effects!（Approve の with_lock 内・同一 tx）。
  # 処理順: ① FOR UPDATE ② 競合チェック（現値 == new_*）③ original_* へ復元 ④ §5 再計算 ⑤ 前後値 history。
  class Withdraw
    def self.call(clock_change_request:, acting_user:) = new(clock_change_request:, acting_user:).call

    def initialize(clock_change_request:, acting_user:)
      @ccr = clock_change_request
      @acting_user = acting_user
    end

    def call
      ActsAsTenant.with_tenant(@ccr.organization) do
        record = AttendanceRecord.lock.find(@ccr.attendance_record_id)
        check_conflict!(record)
        before = snapshot(record)
        restore_times!(record)
        record.save!
        Clockings::Recalculate.call(record:) if record.clock_out.present?
        record_history(record, before)
      end
      @ccr
    end

    private

    # 承認で適用した new_* が現値と一致するか（間に別変更が無いか）。正方向 check の鏡像
    def check_conflict!(record)
      ok = true
      ok &&= (record.clock_in == @ccr.new_clock_in)   if @ccr.change_clock_in? || @ccr.change_both?
      ok &&= (record.clock_out == @ccr.new_clock_out)  if @ccr.change_clock_out? || @ccr.change_both?
      raise Approvals::ConflictError unless ok
    end

    def restore_times!(record)
      record.clock_in  = @ccr.original_clock_in  if @ccr.change_clock_in? || @ccr.change_both?
      record.clock_out = @ccr.original_clock_out if @ccr.change_clock_out? || @ccr.change_both?
    end

    def snapshot(record)
      record.slice("clock_in", "clock_out", "status",
                   "is_late", "late_minutes", "is_early_leave", "early_leave_minutes")
    end

    def record_history(record, before)
      record.reload
      AttendanceHistory.create!(
        user_id: record.user_id, actor: @acting_user, source: @ccr,
        event_type: :clock_change_withdrawn, event_date: record.work_date,
        previous_clock_in: before["clock_in"], new_clock_in: record.clock_in,
        previous_clock_out: before["clock_out"], new_clock_out: record.clock_out,
        previous_status: before["status"], new_status: record.status,
        previous_is_late: before["is_late"], new_is_late: record.is_late,
        previous_late_minutes: before["late_minutes"], new_late_minutes: record.late_minutes,
        previous_is_early_leave: before["is_early_leave"], new_is_early_leave: record.is_early_leave,
        previous_early_leave_minutes: before["early_leave_minutes"], new_early_leave_minutes: record.early_leave_minutes
      )
    end
  end
end
