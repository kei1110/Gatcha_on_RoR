# frozen_string_literal: true

class CreateMonthlyAttendanceSummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :monthly_attendance_summaries do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.string :year_month, null: false # 締め期間ラベル "YYYY-MM"（AttendancePeriod#label）
      t.integer :scheduled_work_days, null: false, default: 0
      t.integer :work_days, null: false, default: 0
      t.decimal :total_work_hours, precision: 7, scale: 2, null: false, default: 0
      t.decimal :total_overtime_hours, precision: 7, scale: 2, null: false, default: 0 # legal・法定休日除く
      t.decimal :overtime_hours_over_60, precision: 7, scale: 2, null: false, default: 0
      t.decimal :holiday_work_hours, precision: 7, scale: 2, null: false, default: 0 # 35%・60h カウント外
      t.decimal :total_deep_night_hours, precision: 7, scale: 2, null: false, default: 0
      t.integer :late_days, null: false, default: 0
      t.integer :early_leave_days, null: false, default: 0

      t.timestamps
    end

    # クロステナント参照を DB 層で遮断（leave_balances と同じ複合 FK・§3.6）
    add_foreign_key :monthly_attendance_summaries, :users,
                    column: [ :organization_id, :user_id ], primary_key: [ :organization_id, :id ]

    # 複合 FK 参照先（規約）。テーブル名が長いため index 名を明示（63 文字制限回避）
    add_index :monthly_attendance_summaries, %i[organization_id id],
              unique: true, name: "index_monthly_summaries_org_id"
    add_index :monthly_attendance_summaries, %i[organization_id user_id year_month],
              unique: true, name: "index_monthly_summaries_unique"
    add_index :monthly_attendance_summaries, %i[organization_id user_id],
              name: "index_monthly_summaries_org_user"
  end
end
