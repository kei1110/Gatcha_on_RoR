# frozen_string_literal: true

# グローバルナビ常設の通知ベル（設計 §5.1）。未読バッジ + 直近通知ドロップダウン。
# 描画は current_user.notifications（= NotificationPolicy::Scope の述語 target_user_id=user.id・
# 本人ルートゆえ越境不能・§9⑤）。bare Notification を触らない。
class NotificationBellComponent < ViewComponent::Base
  RECENT_LIMIT = 10

  def initialize(current_user:)
    @current_user = current_user
  end

  attr_reader :current_user

  def recent
    @recent ||= current_user.notifications.order(created_at: :desc).limit(RECENT_LIMIT)
  end

  def unread_count
    current_user.notifications.unread.count
  end
end
