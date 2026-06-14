# frozen_string_literal: true

class AddProxyClockColumnsToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :attendance_records, :proxy_clock_reason, :integer  # enum・NULL = 通常打刻
    add_column :attendance_records, :note, :text                   # 代理打刻/インターバル不足の追記先
  end
end
