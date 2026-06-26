# frozen_string_literal: true

# 通知生成の単一入口（設計 §2 / §4.1〜§4.3 / §9③④⑨）。
# 1) Notification を作成（in_app の実体）
# 2) 優先度 × 二重 opt-in で email 要否を判定
# 3) email 要なら SuppressionWindow で scheduled_at を決め NotificationDelivery を作成
# 自身の DB 書き込みは明示 tx で囲み、tx 確定後に in_app broadcast + job enqueue を発火
# （rollback 時の幻通知 / 未コミット sweep 防止・§9③）。caller=producer 接続は 4-1c。
class Notifier
  HOLIDAY_DAY_TYPES = %i[saturday sunday holiday legal_holiday company_holiday].freeze

  def self.call(**) = new(**).call

  def initialize(target_user:, title:, body:, priority:, source_type:, subject_user: nil)
    @target_user = target_user
    @title = title
    @body = body
    @priority = priority.to_sym
    @source_type = source_type.to_sym
    @subject_user = subject_user
  end

  def call
    notification = nil
    delivery = nil
    ActiveRecord::Base.transaction do
      notification = Notification.create!(
        target_user: @target_user, subject_user: @subject_user,
        title: @title, body: @body, priority: @priority, source_type: @source_type
      )
      delivery = build_email_delivery(notification)
    end
    # tx 確定後（§9③）: 幻ベル・未コミット sweep を防ぐため commit 後に発火
    broadcast_in_app(notification)
    enqueue_email(delivery) if delivery
    notification
  end

  private

  # 優先度 × 二重 opt-in（§4.1）で email Delivery を作成。不要なら nil。
  def build_email_delivery(notification)
    return nil unless email?

    NotificationDelivery.create!(
      notification:, channel: :email, status: :pending, scheduled_at: email_scheduled_at
    )
  end

  def email?
    case @priority
    when :action_required then true        # 常時（opt-in 無関係）
    when :informational then double_opt_in? # 二重 opt-in 時のみ
    else false                              # reference: メール無し
    end
  end

  def double_opt_in?
    ActsAsTenant.current_tenant.setting.email_notification_enabled && @target_user.email_enabled
  end

  # 抑制（§4.2・email のみ）。非抑制なら即時。
  def email_scheduled_at
    window = suppression_window
    window.suppressed? ? window.next_allowed_at : Time.current
  end

  def suppression_window
    pref = resolved_preference
    org = ActsAsTenant.current_tenant
    now_local = Time.current.in_time_zone(org.time_zone) # 組織ローカル（§9①）
    Notifications::SuppressionWindow.new(
      now_local:,
      quiet_enabled: pref.quiet_hours_enabled,
      quiet_start: pref.quiet_hours_start,
      quiet_end: pref.quiet_hours_end,
      holiday_block: pref.holiday_block_enabled,
      holiday: holiday_today?(org, now_local.to_date)
    )
  end

  # UserNotificationPreference → 無ければ OrganizationSetting（§4.2）。
  # 両者は quiet_hours_enabled / quiet_hours_start / quiet_hours_end / holiday_block_enabled を持つ。
  def resolved_preference
    UserNotificationPreference.find_by(user: @target_user) || ActsAsTenant.current_tenant.setting
  end

  def holiday_today?(org, date)
    CompanyCalendarResolver.new(organization: org).day_type(date).in?(HOLIDAY_DAY_TYPES)
  end

  # 署名 stream（GlobalID）にのみ broadcast（§9⑨）。target は 4-1c のベル list 要素。
  def broadcast_in_app(notification)
    Turbo::StreamsChannel.broadcast_prepend_to(
      @target_user,
      target: "notifications",
      partial: "notifications/notification",
      locals: { notification: }
    )
  end

  def enqueue_email(delivery)
    NotificationEmailJob.set(wait_until: delivery.scheduled_at)
                        .perform_later(organization_id: ActsAsTenant.current_tenant.id, delivery_id: delivery.id)
  end
end
