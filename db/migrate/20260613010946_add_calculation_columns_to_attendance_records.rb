class AddCalculationColumnsToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    # 計算 8 列（SPEC §4.8・1-2 設計 §1）。全列 NULL 許容・default なし — NULL = 未計算。
    # 0 埋めは「残業ゼロ」と区別不能（監査上の欠陥）ゆえ採らない
    change_table :attendance_records, bulk: true do |t|
      t.decimal :actual_work_hours, precision: 6, scale: 2
      t.decimal :legal_overtime_hours, precision: 6, scale: 2
      t.decimal :scheduled_overtime_hours, precision: 6, scale: 2
      t.decimal :deep_night_hours, precision: 6, scale: 2
      t.boolean :is_late
      t.boolean :is_early_leave
      t.integer :late_minutes
      t.integer :early_leave_minutes
    end
  end
end
