# frozen_string_literal: true

# 全休/半休の AttendanceRecord は打刻が無いため clock_in の DB NOT NULL を解除（2-2b 設計 §2.1）。
# working/clocked_out の必須はモデルの条件付き presence が引き継ぐ二層構成。
class AllowNullClockInOnAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    change_column_null :attendance_records, :clock_in, true
  end
end
