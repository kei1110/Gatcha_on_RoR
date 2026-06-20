# frozen_string_literal: true

# 締めステータスによる申請制限（SPEC §6.7・3-2 設計 §2.2）。
# host（LR/CCR/HWR）に include する。**Approvable/Withdrawable より後に include すること**
# （ancestor 順で本 concern の closing_locked? が Approvable 既定 false に勝つ・withdrawable.rb の評価順注記と同型）。
module ClosingRestricted
  extend ActiveSupport::Concern

  included do
    validate :target_dates_not_in_closed_period, on: :create
  end

  # host が実装する締め判定の対象日（複数可）。
  # LR: start_date..end_date / CCR: [attendance_record&.work_date].compact / HWR: [work_date]
  def closing_target_dates = raise NotImplementedError, "#{self.class} must implement #closing_target_dates"

  # 承認時の締め再チェック（§2.4）。Approvable 既定 false を上書き。
  # 注: 名称は apply_*_effects! との対称性を優先し closing_locked? を維持（3-2 設計 §2.4）。
  def closing_locked?
    dates = closing_target_dates
    dates.present? && MonthlySummaries::ClosingLock.locked?(user: requester, dates:)
  end

  def closing_unlocked? = !closing_locked?

  private

  def target_dates_not_in_closed_period
    return unless closing_locked?

    errors.add(:base, "締め済みの月（提出済 / 確定）の日付は申請できません")
  end
end
