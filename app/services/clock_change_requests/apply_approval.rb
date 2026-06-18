# frozen_string_literal: true

module ClockChangeRequests
  # 打刻変更承認の副作用本体（SPEC §6.3・§7.4・2-3 設計 §2）。
  # 呼び出し元: ClockChangeRequest#apply_approval_effects!（Approvals::Approve の with_lock 内・同一 tx）。
  # 内側で rescue しない — ConflictError は raise 伝播し承認ごと atomic rollback。
  # 処理順: ① FOR UPDATE ロック ② §7.4 競合チェック ③ 時刻更新（status 不変）④ §5 再計算 ⑤ 前後値 history。
  class ApplyApproval
    def self.call(clock_change_request:, acting_user:) = new(clock_change_request:, acting_user:).call

    def initialize(clock_change_request:, acting_user:)
      @ccr = clock_change_request
      @acting_user = acting_user
    end

    def call
      ActsAsTenant.with_tenant(@ccr.organization) do
        record = AttendanceRecord.lock.find(@ccr.attendance_record_id)   # FOR UPDATE
        check_conflict!(record)
        before = snapshot(record)
        apply_times!(record)
        record.save!
        Clockings::Recalculate.call(record:) if record.clock_out.present?
        record_history(record, before)
      end
      @ccr
    end

    private

    # §7.4: snapshot（Create 時の original_*）と現記録の厳密照合。DB 由来値同士の == 比較
    def check_conflict!(record)
      return if record.clock_in == @ccr.original_clock_in &&
                record.clock_out == @ccr.original_clock_out

      raise Approvals::ConflictError
    end

    def apply_times!(record)
      record.clock_in  = @ccr.new_clock_in  if @ccr.change_clock_in? || @ccr.change_both?
      record.clock_out = @ccr.new_clock_out if @ccr.change_clock_out? || @ccr.change_both?
    end

    # 前後値の「前」（apply 前に捕捉）。AR#slice は string キーの hash を返す
    def snapshot(record)
      record.slice("clock_in", "clock_out", "status",
                   "is_late", "late_minutes", "is_early_leave", "early_leave_minutes")
    end

    def record_history(record, before)
      record.reload   # recalc 後の確定値（after）
      AttendanceHistory.create!(
        user_id: record.user_id, actor: @acting_user, source: @ccr,
        event_type: :clock_change_approved, event_date: record.work_date,
        previous_clock_in: before["clock_in"], new_clock_in: record.clock_in,
        previous_clock_out: before["clock_out"], new_clock_out: record.clock_out,
        previous_status: before["status"], new_status: record.status,
        previous_is_late: before["is_late"], new_is_late: record.is_late,
        previous_late_minutes: before["late_minutes"], new_late_minutes: record.late_minutes,
        previous_is_early_leave: before["is_early_leave"], new_is_early_leave: record.is_early_leave,
        previous_early_leave_minutes: before["early_leave_minutes"],
        new_early_leave_minutes: record.early_leave_minutes
      )
    end
  end
end
