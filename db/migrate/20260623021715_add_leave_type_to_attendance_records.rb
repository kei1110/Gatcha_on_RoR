# frozen_string_literal: true

class AddLeaveTypeToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :attendance_records, :leave_type_id, :bigint, null: true

    # クロステナント参照を DB 層で遮断（既存 work_patterns FK と同型・§3.6）。
    # leave_type_id NULL の worked 行は MATCH SIMPLE で検査スキップ。
    add_foreign_key :attendance_records, :leave_types,
                    column: [ :organization_id, :leave_type_id ], primary_key: [ :organization_id, :id ]

    # worked 行（status 0/1）に休暇種別が紛れ込むのを DB 最終防衛（設計 D8）。
    # status enum: working=0 / clocked_out=1 / morning_half=2 / afternoon_half=3 / on_leave=4（§13.1 凍結）。
    # leave 系 status を追加する場合は本 CHECK も更新すること。
    add_check_constraint :attendance_records,
                         "leave_type_id IS NULL OR status IN (2, 3, 4)",
                         name: "attendance_records_leave_type_only_on_leave_status"

    # 参照側 index は入れない（集計は既存 [user_id, work_date] index が担当・設計 §1.1a）。
  end
end
