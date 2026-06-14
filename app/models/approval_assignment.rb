# frozen_string_literal: true

# 承認の実行時状態（SPEC §7.1）。段階情報は本テーブル群から導出する。
class ApprovalAssignment < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :approvable, polymorphic: true
  belongs_to :approver, class_name: "User"

  enum :decision, { pending: 0, approved: 1, rejected: 2 }, validate: true

  validates :position, inclusion: { in: [ 1, 2 ] }
  validates :position, uniqueness: { scope: [ :organization_id, :approvable_type, :approvable_id ] }
  validate :approver_must_belong_to_same_organization
  validate :approvable_must_belong_to_same_organization
  validate :acted_at_consistency_with_decision
  validate :decision_is_one_way, on: :update

  private

  # approver は必須（非 optional）ゆえ nil early return を持たない（user.rb の manager は optional で early return あり）。nil 時は belongs_to と二重エラーになるが安全側
  def approver_must_belong_to_same_organization
    return if approver&.organization_id == organization_id

    errors.add(:approver, "は同一組織のユーザーである必要があります")
  end

  # polymorphic ゆえ実 FK 不可 → この検証が唯一の構造防衛。整数 ID 直接代入の fail-closed も担保
  def approvable_must_belong_to_same_organization
    return if approvable_type.blank? && approvable_id.blank? # belongs_to 必須検証に委ねる（片方だけ blank の場合も nil 解決で reject → belongs_to と二重エラーだが安全側）
    return if approvable&.organization_id == organization_id

    errors.add(:approvable, "は同一組織のレコードである必要があります")
  end

  def acted_at_consistency_with_decision
    if pending? && acted_at.present?
      errors.add(:acted_at, "は pending 中は設定できません")
    elsif !pending? && acted_at.blank?
      errors.add(:acted_at, "は決裁時に必須です")
    end
  end

  # pending からの一方向のみ許可（決裁の取消・付け替えを禁止）
  def decision_is_one_way
    return unless decision_changed?
    return if decision_was == "pending"

    errors.add(:decision, "は決裁後に変更できません")
  end
end
