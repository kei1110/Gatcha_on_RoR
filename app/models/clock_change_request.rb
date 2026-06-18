# frozen_string_literal: true

# 打刻変更申請（SPEC §4.11・Phase 2-3 設計 §1.1）。承認対象の 2 つ目。
# original_*/new_*/approval_status の writer は ClockChangeRequests::Create / 承認エンジンのみ（strong params 恒久ブロック）。
class ClockChangeRequest < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :requester, class_name: "User"
  belongs_to :attendance_record, optional: true   # new_entry は null（本スライスは非 null）

  include Approvable   # approval_status の AASM + has_many :approval_assignments

  # prefix: :change — 述語 change_clock_in? / change_clock_out? / change_both? / change_new_entry?
  enum :change_type, { clock_in: 0, clock_out: 1, both: 2, new_entry: 3 },
       validate: true, prefix: :change

  validates :reason, presence: true
  validate :new_times_present_for_change_type
  validate :new_clock_out_after_in
  validate :target_record_not_on_leave
  validate :target_record_clocked_out
  validate :requester_owns_target_record
  validate :requester_must_belong_to_same_organization
  validate :attendance_record_must_belong_to_same_organization

  private

  def new_times_present_for_change_type
    errors.add(:new_clock_in, "を入力してください") if (change_clock_in? || change_both?) && new_clock_in.blank?
    errors.add(:new_clock_out, "を入力してください") if (change_clock_out? || change_both?) && new_clock_out.blank?
  end

  def new_clock_out_after_in
    return unless change_both? && new_clock_in.present? && new_clock_out.present?
    return if new_clock_out > new_clock_in

    errors.add(:new_clock_out, "は出勤時刻以降にしてください")
  end

  def target_record_not_on_leave
    return unless attendance_record&.on_leave?

    errors.add(:attendance_record, "は全休日のため打刻変更できません")
  end

  def target_record_clocked_out
    return if attendance_record.nil?
    return if attendance_record.on_leave?   # not_on_leave 検証に一本化（二重エラー防止）
    return if attendance_record.clock_out.present?

    errors.add(:attendance_record, "は勤務中の記録のため変更できません（退勤後にお申し込みください）")
  end

  def requester_owns_target_record
    return if attendance_record.nil? || attendance_record.user_id == requester_id

    errors.add(:attendance_record, "は本人の記録ではありません")
  end

  # ID 基点 fail-closed（leave_request.rb 同型）
  def requester_must_belong_to_same_organization
    return if requester_id.nil?
    return if requester&.organization_id == organization_id

    errors.add(:requester, "は同一組織でなければなりません")
  end

  def attendance_record_must_belong_to_same_organization
    return if attendance_record_id.nil?
    return if attendance_record&.organization_id == organization_id

    errors.add(:attendance_record, "は同一組織でなければなりません")
  end
end
