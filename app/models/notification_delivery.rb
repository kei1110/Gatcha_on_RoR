# frozen_string_literal: true

# email 配信の監査記録 + 抑制キュー（SPEC §4.18）。
# 独立状態機械は持たない — status は SolidQueue ジョブ結果の反映（遅延/リトライは SolidQueue が正）。
class NotificationDelivery < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :notification

  enum :channel, { in_app: 0, email: 1 }, validate: true
  enum :status, { pending: 0, sent: 1, error: 2 }, validate: true

  validates :scheduled_at, presence: true
  validate :notification_must_belong_to_same_organization

  private

  # ID 基点 fail-closed（§3.6・複合 FK と二層）
  def notification_must_belong_to_same_organization
    return if notification_id.nil?
    return if notification&.organization_id == organization_id

    errors.add(:notification, "は同一組織でなければなりません")
  end
end
