# frozen_string_literal: true

class CreateUserNotificationPreferences < ActiveRecord::Migration[8.1]
  def change
    create_table :user_notification_preferences do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.boolean :quiet_hours_enabled, null: false, default: true
      t.integer :quiet_hours_start, null: false, default: 19 # 時（0..23）
      t.integer :quiet_hours_end, null: false, default: 8     # 時（0..23）
      t.boolean :holiday_block_enabled, null: false, default: true
      t.timestamps
    end

    # クロステナント参照を DB 層で遮断（§3.6 複合 FK）
    add_foreign_key :user_notification_preferences, :users,
                    column: %i[organization_id user_id], primary_key: %i[organization_id id]

    add_index :user_notification_preferences, %i[organization_id id], unique: true # 規約（将来の複合 FK 参照先）
    # 1 ユーザー 1 行（テナント内）— DB 最終防衛
    add_index :user_notification_preferences, %i[organization_id user_id],
              unique: true, name: "index_user_notification_preferences_unique"
  end
end
