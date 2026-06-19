# frozen_string_literal: true

class AddIsHolidayWorkToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    # index は張らない（Phase 3-1 が実集計クエリの形状に合わせて張る・設計 R3）
    add_column :attendance_records, :is_holiday_work, :boolean, null: false, default: false
  end
end
