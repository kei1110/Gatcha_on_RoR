class LeaveType < ApplicationRecord
  acts_as_tenant(:organization)

  # validate: true — 不正値を代入時 ArgumentError でなくバリデーションエラーに（RAILS_GOTCHAS）
  enum :system_type, {
    annual: 0, substitute_holiday: 1, compensatory_leave: 2,
    child_care: 3, paternity_leave: 4, other: 5
  }, validate: true

  validates :name, presence: true
  validates_uniqueness_to_tenant :name
  validates :system_type, presence: true
end
