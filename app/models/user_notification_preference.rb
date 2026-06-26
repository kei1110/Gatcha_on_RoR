# frozen_string_literal: true

# 個人の通知抑制設定（SPEC §4.17）。1 ユーザー 1 行・任意（無ければ OrganizationSetting にフォールバック）。
# email_enabled は持たない（個人メール opt-in は User.email_enabled が SSOT・設計判断 B）。
class UserNotificationPreference < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user

  validates_uniqueness_to_tenant :user_id
  validates :quiet_hours_start, :quiet_hours_end, inclusion: { in: 0..23 } # 時（§4.15）
  validate :user_must_belong_to_same_organization

  private

  # ID 基点 fail-closed（leave_balance.rb 同型・§3.6）。複合 FK と二層で守る
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id

    errors.add(:user, "は同一組織でなければなりません")
  end
end
