# frozen_string_literal: true

# 休暇申請（SPEC §4.9・Phase 2-2a 設計 §1.1）。承認対象モデルの初投入。
# days_requested / approval_status の writer は LeaveRequests::Create（サーバ権威）のみ — strong params 恒久ブロック。
class LeaveRequest < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :requester, class_name: "User"
  belongs_to :leave_type

  include Withdrawable # approval_status の AASM + 撤回フロー（2-5）
  include ClosingRestricted # §6.7 締め制限（Withdrawable より後＝ancestor 順で closing_locked? が勝つ）

  MAX_SPAN_DAYS = 366  # 1 年度相当の上限（不定・DoS 抑止）

  # _prefix: :half_day — Rails 8.1 では :none が AR.none（空スコープ）と衝突するため prefix で回避。
  # 値 :none/:morning/:afternoon は変わらない（DB 整数 0/1/2・factory/spec 変更不要）。
  # 述語は half_day_none? / half_day_morning? / half_day_afternoon? になる。
  enum :half_day_type, { none: 0, morning: 1, afternoon: 2 }, validate: true, prefix: :half_day

  validates :start_date, :end_date, :days_requested, presence: true
  validates :days_requested, numericality: { greater_than: 0 }   # 0 日申請拒否
  validate :end_date_not_before_start_date
  validate :span_within_limit
  validate :half_day_requires_single_day
  validate :half_day_requires_half_day_enabled_type
  validate :requester_must_belong_to_same_organization
  validate :leave_type_must_belong_to_same_organization

  # 締め判定の対象日（§6.7・3-2）。start_date..end_date の全日。
  # end < start（不正入力）は空を返して締め制限をバイパス（存在検証は end_date_not_before_start_date に委ねる）。
  def closing_target_dates = (start_date && end_date && end_date >= start_date) ? (start_date..end_date) : []

  # この申請が AttendanceRecord へ書く leave status（half_day_type の純関数）。
  # 承認（ApplyApproval）と重複撤回時の貼り直し（Withdraw）が同一の対応表を読むための単一ソース。
  # 二重定義は「承認で書いた status と貼り直した status が食い違う」drift を生む
  def leave_status
    case half_day_type
    when "none" then :on_leave
    when "morning" then :morning_half
    when "afternoon" then :afternoon_half
    end
  end

  # 承認確定時の副作用（§6.2・§13.6）。Approve エンジンの with_lock 内・同一 tx で呼ばれる。
  def apply_approval_effects!(acting_user:)
    LeaveRequests::ApplyApproval.call(leave_request: self, acting_user:)
  end

  # 撤回承認確定時の逆副作用（§7.6・§13.6・2-5）。Approve エンジンの with_lock 内・同一 tx で呼ばれる。
  def apply_withdrawal_effects!(acting_user:)
    LeaveRequests::Withdraw.call(leave_request: self, acting_user:)
  end

  private

  def end_date_not_before_start_date
    return if start_date.blank? || end_date.blank? || end_date >= start_date

    errors.add(:end_date, "は開始日以降にしてください")
  end

  def span_within_limit
    return if start_date.blank? || end_date.blank?
    return if (end_date - start_date).to_i <= MAX_SPAN_DAYS

    errors.add(:end_date, "は申請可能な期間（#{MAX_SPAN_DAYS} 日）を超えています")
  end

  def half_day_requires_single_day
    return if half_day_none? || start_date.blank? || end_date.blank? || start_date == end_date

    errors.add(:half_day_type, "は単日申請でのみ指定できます")
  end

  def half_day_requires_half_day_enabled_type
    return if half_day_none? || leave_type&.allow_half_day?

    errors.add(:half_day_type, "はこの休暇種別では指定できません")
  end

  def requester_must_belong_to_same_organization
    return if requester_id.nil?
    return if requester&.organization_id == organization_id

    errors.add(:requester, "は同一組織でなければなりません")
  end

  def leave_type_must_belong_to_same_organization
    return if leave_type_id.nil?
    return if leave_type&.organization_id == organization_id

    errors.add(:leave_type, "は同一組織でなければなりません")
  end
end
