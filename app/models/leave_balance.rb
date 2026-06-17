# frozen_string_literal: true

# 休暇残高（SPEC §4.10・Phase 2-2a 設計 §1.2）。used_days の writer は 2-2b の approve 副作用のみ。
class LeaveBalance < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user
  belongs_to :leave_type

  validates :fiscal_year, presence: true
  validates :granted_days, :carry_over_days, :used_days,
            numericality: { greater_than_or_equal_to: 0 }
  validates :fiscal_year, uniqueness: { scope: %i[organization_id user_id leave_type_id] }
  validates :granted_on, presence: true, if: :paid_annual?
  validate :user_must_belong_to_same_organization
  validate :leave_type_must_belong_to_same_organization

  # 残日数（§4.10）。used_days は 2-2a では常に 0
  def remaining = granted_days + carry_over_days - used_days

  # 5 日義務（§8.6）の対象 = 有給かつ年休。granted_on を必須にして NULL annual 残高を防ぐ（D5）
  def paid_annual? = leave_type&.paid_leave? && leave_type&.annual?

  private

  # ID 基点 fail-closed（user.rb / attendance_history.rb 同型・§3.6）
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id

    errors.add(:user, "は同一組織でなければなりません")
  end

  def leave_type_must_belong_to_same_organization
    return if leave_type_id.nil?
    return if leave_type&.organization_id == organization_id

    errors.add(:leave_type, "は同一組織でなければなりません")
  end
end
