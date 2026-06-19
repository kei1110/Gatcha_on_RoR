# frozen_string_literal: true

class CreateHolidayWorkRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :holiday_work_requests do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :requester_id, null: false
      t.date :work_date, null: false
      t.bigint :compensation_leave_type_id, null: false
      t.text :reason
      t.integer :approval_status, null: false, default: 0
      t.timestamps
    end

    add_index :holiday_work_requests, %i[organization_id id], unique: true
    add_index :holiday_work_requests, %i[organization_id requester_id approval_status],
              name: "idx_hwr_requester_status"
    # 同一日重複禁止（applying:0 / approved:1 のみ・canceled/rejected 後の再申請は許可）
    add_index :holiday_work_requests, %i[organization_id requester_id work_date],
              unique: true, where: "approval_status IN (0, 1)", name: "idx_hwr_active_unique"

    add_foreign_key :holiday_work_requests, :users,
                    column: %i[organization_id requester_id], primary_key: %i[organization_id id]
    add_foreign_key :holiday_work_requests, :leave_types,
                    column: %i[organization_id compensation_leave_type_id],
                    primary_key: %i[organization_id id]
  end
end
