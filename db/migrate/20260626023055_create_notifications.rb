# frozen_string_literal: true

class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :target_user_id, null: false  # 通知先
      t.bigint :subject_user_id              # 通知対象者（重複制御キー・null 可）
      t.string :title, null: false
      t.text :body, null: false
      t.integer :priority, null: false       # enum: action_required:0 / informational:1 / reference:2
      t.integer :source_type, null: false    # enum: request_approved:0 / request_rejected:1
      t.timestamptz :read_at                  # 既読時刻（null = 未読）
      t.timestamps
    end

    # クロステナント参照を DB 層で遮断（§3.6 複合 FK）
    add_foreign_key :notifications, :users,
                    column: %i[organization_id target_user_id], primary_key: %i[organization_id id]
    add_foreign_key :notifications, :users,
                    column: %i[organization_id subject_user_id], primary_key: %i[organization_id id]

    add_index :notifications, %i[organization_id id], unique: true # 規約（NotificationDelivery が複合 FK で参照）
    add_index :notifications, %i[organization_id target_user_id read_at],
              name: "index_notifications_target_unread" # 未読絞り込み
  end
end
