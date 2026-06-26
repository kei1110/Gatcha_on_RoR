# frozen_string_literal: true

# ディスパッチャの子（設計 §4.3 / §4.4 / §9⑪）。with_tenant で当該テナントの
# due な email pending Delivery を NotificationEmailJob へ流す（取りこぼし回収）。
class NotificationDispatchTenantJob < ApplicationJob
  def perform(organization_id)
    org = Organization.find_by(id: organization_id)
    return if org.nil? # 毎時 sweep の削除レース耐性（org 削除済みは skip・NotificationEmailJob と対称）

    ActsAsTenant.with_tenant(org) do # §3.6 必須（リクエスト文脈なし）
      NotificationDelivery.email.pending
                          .where(scheduled_at: ..Time.current)
                          .find_each do |delivery|
        NotificationEmailJob.perform_later(organization_id: org.id, delivery_id: delivery.id)
      end
    end
  end
end
