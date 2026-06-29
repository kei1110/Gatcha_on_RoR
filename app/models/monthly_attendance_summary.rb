# frozen_string_literal: true

# 月次（締め期間）サマリ（SPEC §4.13・3-1 設計 §1.1・3-2 設計 §1.2）。永久保持・長期参照の基点。
# 締め状態機械（AASM・§13.4）を 3-2 で追加。status/deferral_reason はサーバ権威（AASM event 経由のみ・
# strong params 不受領・update_column/all 禁止）。
class MonthlyAttendanceSummary < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user

  AGGREGATE_COLUMNS = %i[
    scheduled_work_days work_days total_work_hours total_overtime_hours
    overtime_hours_over_60 holiday_work_hours total_deep_night_hours late_days early_leave_days
  ].freeze

  # enum を aasm より先に宣言（class ロード時マッピング解決・Approvable と同型）
  enum :status, { aggregating: 0, submitted: 1, finalized: 2, deferred: 3 }

  validates :year_month, presence: true, format: { with: /\A\d{4}-(0[1-9]|1[0-2])\z/ }
  validates_uniqueness_to_tenant :year_month, scope: :user_id
  validates(*AGGREGATE_COLUMNS, numericality: { greater_than_or_equal_to: 0 })
  validates :interval_violation_count, numericality: { greater_than_or_equal_to: 0 }
  validates :deferral_reason, presence: true, if: :deferred?
  validate :user_must_belong_to_same_organization

  include AASM
  aasm column: :status, enum: true, whiny_persistence: true do # bang の save 失敗を例外化
    state :aggregating, initial: true
    state :submitted
    state :finalized
    state :deferred

    event :submit do # 提出 / 再提出（副作用＝MonthlySummaries::Submit 側・3-2 設計 D2）
      transitions from: %i[aggregating deferred], to: :submitted
    end
    event :finalize do
      transitions from: :submitted, to: :finalized
    end
    event :defer do # 差戻し（deferral_reason 必須・whiny_persistence で空は例外）
      transitions from: %i[submitted finalized], to: :deferred
    end
  end

  private

  # ID 基点 fail-closed（leave_balance.rb:27 同型・§3.6）。
  # find_or_initialize_by で organization_id(tenant 由来) と user_id(引数由来) が別経路ゆえ能動検証。
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id

    errors.add(:user, "は同一組織でなければなりません")
  end
end
