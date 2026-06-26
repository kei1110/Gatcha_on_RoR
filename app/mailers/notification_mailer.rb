# frozen_string_literal: true

# 汎用通知メール（設計 §4.3 / §9⑦）。NotificationEmailJob から deliver_now される。
# job 文脈ゆえ request が無い → リンク host は notification.organization.subdomain から構築。
class NotificationMailer < ApplicationMailer
  default from: ENV.fetch("MAILER_SENDER", "notifications@example.com")

  def notify(notification)
    @notification = notification
    org = notification.organization
    host = "#{org.subdomain}.#{ENV.fetch('APP_HOST', 'example.com')}"
    # 4-1b では notifications route 未整備ゆえ root。4-1c で notifications_url(host:) に差し替え。
    @url = root_url(host: host)
    mail(to: notification.target_user.email, subject: notification.title)
  end
end
