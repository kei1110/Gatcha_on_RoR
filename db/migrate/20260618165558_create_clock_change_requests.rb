# frozen_string_literal: true

class CreateClockChangeRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :clock_change_requests do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :requester_id, null: false
      t.bigint :attendance_record_id              # new_entry は null（本スライスは非 null）
      t.integer :change_type, null: false
      t.date :target_date                         # new_entry 用予約（本スライス未使用）
      t.timestamptz :original_clock_in
      t.timestamptz :original_clock_out
      t.timestamptz :new_clock_in
      t.timestamptz :new_clock_out
      t.text :reason
      t.integer :approval_status, null: false, default: 0
      t.text :withdrawal_reason                   # 2-5 予約
      t.date :last_stale_notified_on              # Phase 4 予約
      t.timestamps
    end

    add_index :clock_change_requests, %i[organization_id id], unique: true
    add_index :clock_change_requests, %i[organization_id requester_id approval_status],
              name: "idx_ccr_requester_status"
    add_foreign_key :clock_change_requests, :users,
                    column: %i[organization_id requester_id], primary_key: %i[organization_id id]
    add_foreign_key :clock_change_requests, :attendance_records,
                    column: %i[organization_id attendance_record_id], primary_key: %i[organization_id id]
  end
end
