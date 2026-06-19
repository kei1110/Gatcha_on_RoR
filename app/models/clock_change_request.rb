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
  # new_entry は Phase 4-2 で解除予定。現時点では受け付けない（設計 §0 D1・§1.1「Create が弾く」）
  validates :change_type, exclusion: { in: %w[new_entry], message: "は現在この種別の申請を受け付けていません" }
  validate :new_times_present_for_change_type
  validate :resulting_times_consistent
  validate :target_record_not_on_leave
  validate :target_record_clocked_out
  validate :requester_owns_target_record
  validate :requester_must_belong_to_same_organization
  validate :attendance_record_must_belong_to_same_organization

  # フォームは出退勤の両欄を常時表示するため、change_type の対象外に入力された値を捨てる。
  # 残すと承認行で「退勤 X → Y」と表示されるのに apply_times! は触らず、表示と反映が乖離する（Codex review）。
  before_validation :clear_non_target_new_times

  # 承認確定時の副作用（§6.3・§13.6）。Approve エンジンの with_lock 内・同一 tx で呼ばれる。
  def apply_approval_effects!(acting_user:)
    ClockChangeRequests::ApplyApproval.call(clock_change_request: self, acting_user:)
  end

  private

  # change_type の対象側だけ new_* を残し、対象外は nil にする（表示・保存・反映の一致を担保）
  def clear_non_target_new_times
    self.new_clock_in = nil unless change_clock_in? || change_both?
    self.new_clock_out = nil unless change_clock_out? || change_both?
  end

  def new_times_present_for_change_type
    errors.add(:new_clock_in, "を入力してください") if (change_clock_in? || change_both?) && new_clock_in.blank?
    errors.add(:new_clock_out, "を入力してください") if (change_clock_out? || change_both?) && new_clock_out.blank?
  end

  # 片側・両側いずれの変更型でも、変更後の最終 clock_in/out が矛盾しないことを保証する。
  # 変更しない側は attendance_record の現値を使用（target_record_clocked_out で clock_out 存在保証済み）。
  def resulting_times_consistent
    return if attendance_record.nil?

    final_in  = (change_clock_in? || change_both?) ? new_clock_in  : attendance_record.clock_in
    final_out = (change_clock_out? || change_both?) ? new_clock_out : attendance_record.clock_out
    return if final_in.blank? || final_out.blank?
    return if final_out > final_in

    errors.add(:base, "変更後の退勤時刻は出勤時刻以降にしてください")
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
