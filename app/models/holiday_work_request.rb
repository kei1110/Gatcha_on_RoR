# frozen_string_literal: true

# 休日出勤申請（SPEC §4.12・Phase 2-4 設計 §1.1）。承認対象の 3 つ目。
# approval_status の writer は承認エンジンのみ。compensation_leave_type は v1 代休限定（振替は後置）。
class HolidayWorkRequest < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :requester, class_name: "User"
  belongs_to :compensation_leave_type, class_name: "LeaveType"

  include Approvable   # approval_status の AASM + has_many :approval_assignments

  validates :work_date, presence: true
  validates :reason, presence: true
  validate :work_date_is_non_weekday
  validate :compensation_type_is_compensatory
  validate :no_duplicate_active_request
  validate :requester_must_belong_to_same_organization
  validate :compensation_leave_type_must_belong_to_same_organization

  # 承認確定時の副作用（§6.11・§13.6）。Approve エンジンの with_lock 内・同一 tx で呼ばれる。
  # 実装は Task 4。
  def apply_approval_effects!(acting_user:)
    HolidayWorkRequests::ApplyApproval.call(holiday_work_request: self, acting_user:)
  end

  private

  # 平日以外のみ許可（§6.11 step1）。未登録日は CompanyCalendarResolver が ISO 曜日でフォールバック。
  def work_date_is_non_weekday
    return if work_date.nil?   # presence に委ねる（resolver を nil で呼ばない）
    return if CompanyCalendarResolver.new(organization:).day_type(work_date) != :weekday

    errors.add(:work_date, "は休日（平日以外）のみ申請できます")
  end

  # v1 は振替（substitute_holiday）を選べない＝割増免除運用を作らない（SPEC §6.11 事前特定ノート・D3）。
  def compensation_type_is_compensatory
    return if compensation_leave_type_id.nil?
    return if compensation_leave_type&.compensatory_leave?

    errors.add(:compensation_leave_type, "は代休のみ指定できます")
  end

  # 同一 (requester, work_date) で applying/approved の他レコードを拒否（DB partial unique と二層）。
  def no_duplicate_active_request
    return if requester_id.nil? || work_date.nil?

    dup = HolidayWorkRequest.where(requester_id:, work_date:, approval_status: %i[applying approved])
                            .where.not(id:)
    errors.add(:work_date, "は既に申請済みです") if dup.exists?
  end

  # ID 基点 fail-closed（clock_change_request.rb / leave_balance.rb 同型）
  def requester_must_belong_to_same_organization
    return if requester_id.nil?
    return if requester&.organization_id == organization_id

    errors.add(:requester, "は同一組織でなければなりません")
  end

  def compensation_leave_type_must_belong_to_same_organization
    return if compensation_leave_type_id.nil?
    return if compensation_leave_type&.organization_id == organization_id

    errors.add(:compensation_leave_type, "は同一組織でなければなりません")
  end
end
