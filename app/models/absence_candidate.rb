# frozen_string_literal: true

# 欠勤候補（no AR ∧ no LR の未打刻日・§6.8/§6.10）。存在 = 未解決・削除 = resolve（ephemeral）。
# 監査は AttendanceHistory(absence_confirmed) が担い、本テーブルは作業状態。4-2b が upsert・4-2c が権威源。
class AbsenceCandidate < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user

  scope :unnotified, -> { where(notified_on: nil) }

  validate :user_must_belong_to_same_organization

  private

  # ID 基点 fail-closed（§3.6・複合 FK と二層）
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id

    errors.add(:user, "は同一組織でなければなりません")
  end
end
