# frozen_string_literal: true

class CreateNotificationDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :notification_deliveries do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :notification_id, null: false
      t.integer :channel, null: false                 # enum: in_app:0 / email:1（実質 email のみ生成）
      t.timestamptz :scheduled_at, null: false        # 抑制終了後の送信予定
      t.integer :status, null: false, default: 0       # enum: pending:0 / sent:1 / error:2
      t.integer :retry_count, null: false, default: 0  # >3 で error 確定（§9.5・監査ミラー）
      t.timestamps
    end

    # クロステナント参照を DB 層で遮断（§3.6 複合 FK）
    add_foreign_key :notification_deliveries, :notifications,
                    column: %i[organization_id notification_id], primary_key: %i[organization_id id]

    add_index :notification_deliveries, %i[organization_id id], unique: true # 規約
    add_index :notification_deliveries, %i[organization_id status scheduled_at],
              name: "index_notification_deliveries_sweep" # sweep（pending かつ scheduled_at<=now）用
  end
end
