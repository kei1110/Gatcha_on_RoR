# frozen_string_literal: true

class AddNotificationQueryIndexes < ActiveRecord::Migration[8.1]
  def change
    # 未読件数のホットパス（ベルバッジ・一覧フィルタ）。部分 index で小さく保つ。
    add_index :notifications, %i[organization_id target_user_id],
              where: "read_at IS NULL",
              name: "index_notifications_on_org_target_unread"

    # 重複制御キー（subject_user）の将来 dedup。nullable・安価（ROADMAP 対称化）。
    add_index :notifications, %i[organization_id subject_user_id],
              name: "index_notifications_on_org_subject_user"

    # 複合 FK [organization_id, notification_id]→notifications の結合裏付け（PG は FK 自動 index 無し）。
    add_index :notification_deliveries, %i[organization_id notification_id],
              name: "index_notification_deliveries_on_org_notification"
  end
end
