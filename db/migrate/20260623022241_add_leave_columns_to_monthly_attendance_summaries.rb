# frozen_string_literal: true

class AddLeaveColumnsToMonthlyAttendanceSummaries < ActiveRecord::Migration[8.1]
  def change
    # §4.13 の正本に一致（有給使用日数・総休暇時間）。3-3 設計 §1.1(b)。
    add_column :monthly_attendance_summaries, :paid_leave_days_used, :decimal, precision: 6, scale: 2, null: false, default: 0
    add_column :monthly_attendance_summaries, :total_leave_hours, :decimal, precision: 7, scale: 2, null: false, default: 0
  end
end
