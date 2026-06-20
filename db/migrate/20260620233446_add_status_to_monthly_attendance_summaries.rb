# frozen_string_literal: true

class AddStatusToMonthlyAttendanceSummaries < ActiveRecord::Migration[8.1]
  def change
    add_column :monthly_attendance_summaries, :status, :integer, null: false, default: 0
    add_column :monthly_attendance_summaries, :deferral_reason, :text
  end
end
