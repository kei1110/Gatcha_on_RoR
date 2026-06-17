# frozen_string_literal: true

class CreateLeaveRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :leave_requests do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :requester_id, null: false
      t.bigint :leave_type_id, null: false
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.integer :half_day_type, null: false, default: 0
      t.decimal :days_requested, precision: 6, scale: 2, null: false
      t.text :reason
      t.integer :approval_status, null: false, default: 0   # Approvable（applying:0）

      t.timestamps
    end

    add_foreign_key :leave_requests, :users,
                    column: [ :organization_id, :requester_id ], primary_key: [ :organization_id, :id ]
    add_foreign_key :leave_requests, :leave_types,
                    column: [ :organization_id, :leave_type_id ], primary_key: [ :organization_id, :id ]

    add_index :leave_requests, %i[organization_id id], unique: true
    add_index :leave_requests, %i[organization_id requester_id approval_status]            # 自分の申請一覧
    add_index :leave_requests, %i[organization_id requester_id leave_type_id start_date]   # 仮残高の年度別集計
  end
end
