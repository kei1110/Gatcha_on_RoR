# frozen_string_literal: true

# ベル通知の実体（SPEC §4.18）。配信監査は NotificationDelivery（email 専用）。
# 状態機械は持たない（read_at の有無のみ・遅延/リトライは SolidQueue が正・§4.18 注記）。
class Notification < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :target_user, class_name: "User"
  belongs_to :subject_user, class_name: "User", optional: true
  has_many :notification_deliveries, dependent: :destroy

  enum :priority, { action_required: 0, informational: 1, reference: 2 }, validate: true
  # 後続 Phase が値を追加（integer enum ゆえ model 編集のみ・append-only）
  enum :source_type, { request_approved: 0, request_rejected: 1,
                       clock_out_missing: 2, absence_candidate: 3, leave_pending_no_clock: 4,
                       proxy_clocked: 5, interval_shortage: 6, absence_confirmed: 7 }, validate: true

  validates :title, :body, presence: true
  validate :target_user_must_belong_to_same_organization
  validate :subject_user_must_belong_to_same_organization

  scope :unread, -> { where(read_at: nil) }

  private

  # ID 基点 fail-closed（leave_balance.rb 同型・§3.6・複合 FK と二層）
  def target_user_must_belong_to_same_organization
    return if target_user_id.nil?
    return if target_user&.organization_id == organization_id

    errors.add(:target_user, "は同一組織でなければなりません")
  end

  # optional ゆえ nil は早期 return
  def subject_user_must_belong_to_same_organization
    return if subject_user_id.nil?
    return if subject_user&.organization_id == organization_id

    errors.add(:subject_user, "は同一組織でなければなりません")
  end
end
