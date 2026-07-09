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
    # **absent 由来の日は destroy せず復元する**（4-2c-2 レビュー C1 — 候補は再生成されず欠勤が台帳から消える）
    def restore_attendance_records
      AttendanceRecord
        .where(user_id: @leave_request.requester_id,
               work_date: @leave_request.start_date..@leave_request.end_date,
               status: %i[on_leave morning_half afternoon_half])
        .find_each do |record|
          conversion = absence_to_paid_history(record.work_date)
          if conversion
            restore_absence(record, conversion)
          elsif record.clock_in.blank?
            record.destroy!
          else
            record.update!(status: record.clock_out.present? ? :clocked_out : :working, leave_type_id: nil)
            Clockings::Recalculate.call(record:) if record.clock_out.present?
          end
        end
    end

    # この休暇の承認が absent を on_leave へ昇格させた日か。昇格した AR は clock_in が nil のままなので、
    # clock_in.blank? だけでは「休暇が新規作成した AR」と区別できない（destroy すると欠勤が消える）
    def absence_to_paid_history(work_date)
      AttendanceHistory.find_by(user_id: @leave_request.requester_id, source: @leave_request,
                                event_type: :absence_to_paid, event_date: work_date)
    end

    # 欠勤へ戻す（理由・自由記述は absence_to_paid 履歴が構造化して保持している）。
    # previous_status は update! の**前**に捕捉する（capture-before-assign）
    def restore_absence(record, conversion)
      previous_status = AttendanceRecord.statuses[record.status]
      record.update!(status: :absent, absence_reason: conversion.absence_reason,
                     note: conversion.note, leave_type_id: nil)
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id, actor: @acting_user, source: @leave_request,
        event_type: :absence_restored, event_date: record.work_date,
        previous_status: previous_status,
        new_status: AttendanceRecord.statuses[:absent],
        absence_reason: conversion.absence_reason, note: conversion.note
      )
    end

    def record_history
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id, actor: @acting_user, source: @leave_request,
        event_type: :leave_withdrawn, event_date: @leave_request.start_date
      )
    end
  end
end
