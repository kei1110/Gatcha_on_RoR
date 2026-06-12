class ReasonTemplate < ApplicationRecord
  acts_as_tenant(:organization)

  # Admin::Deactivatable の flash 文言は record.name 契約（concern 参照）。
  # 本マスタの表示名カラムは label（SPEC §4.16）のためエイリアスで適合させる（0b-5 設計 §0）
  alias_attribute :name, :label

  enum :applies_to, { clock_change: 0, leave: 1, both: 2 }, validate: true

  validates :label, presence: true
  validates_uniqueness_to_tenant :label
  validates :template_text, presence: true
end
