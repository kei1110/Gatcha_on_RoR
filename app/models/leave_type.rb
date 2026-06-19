# frozen_string_literal: true

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

  # 残高で管理する種別の述語。付与（HWR 承認）・消費（LeaveRequest 承認）の両方がこれで分岐。
  # paid_leave は admin 設定の boolean 列（有給消化系）、compensatory_leave は system_type enum（代償休暇）。
  # v1 は振替（substitute_holiday）を述語に列挙しない＝HWR が代休限定で真を返す経路が無いデッド項を作らない。
  # 注意: paid_leave? 単独でも true ゆえ、admin が振替種別に paid_leave を立てれば列挙の有無に関わらず true。
  def balance_tracked? = paid_leave? || compensatory_leave?
end
