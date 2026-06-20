# frozen_string_literal: true

# 月次（締め期間）サマリ（SPEC §4.13・3-1 設計 §1.1）。永久保持・長期参照の基点。
# 本スライスは AR 由来の集計列のみ。status/AASM・休暇由来列・コンプラフラグは消費 Phase が同梱追加（D4）。
class MonthlyAttendanceSummary < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user

  AGGREGATE_COLUMNS = %i[
    scheduled_work_days work_days total_work_hours total_overtime_hours
    overtime_hours_over_60 holiday_work_hours total_deep_night_hours late_days early_leave_days
  ].freeze

  validates :year_month, presence: true, format: { with: /\A\d{4}-(0[1-9]|1[0-2])\z/ }
  validates_uniqueness_to_tenant :year_month, scope: :user_id
  validates(*AGGREGATE_COLUMNS, numericality: { greater_than_or_equal_to: 0 })
  validate :user_must_belong_to_same_organization

  private

  # ID 基点 fail-closed（leave_balance.rb:27 同型・§3.6）。
  # find_or_initialize_by で organization_id(tenant 由来) と user_id(引数由来) が別経路ゆえ能動検証。
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id

    errors.add(:user, "は同一組織でなければなりません")
  end
end
