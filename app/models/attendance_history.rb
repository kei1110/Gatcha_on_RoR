# frozen_string_literal: true

# 勤怠の全イベントを前後値つきで記録する追記専用監査証跡（SPEC §4.14・労基法 109 条 5 年保存）。
# 不変性は 3 段で担保: ① readonly? ② before_update/destroy ③ DB トリガー（fx）。
# 真の backstop は ③（update_all 等は ①② を素通りする）。①② は fast-fail。
# 本スライスの writer は proxy_clock のみ。残り event_type は Phase 2-4 が消費。
class AttendanceHistory < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user
  belongs_to :actor, class_name: "User", optional: true   # 操作者（§3.5 オーナー/操作者分離）
  belongs_to :source, polymorphic: true, optional: true

  # §4.14 が全 10 値を順序固定する taxonomy（AttendanceRecord.status の非宣言予約とは扱いが違う）。
  # 整数マッピングは append-only/凍結（リオーダ禁止 — 履歴の誤デコードを防ぐ）
  enum :event_type, {
    clock_in: 0, clock_out: 1, leave_approved: 2, leave_withdrawn: 3,
    clock_change_approved: 4, absence_confirmed: 5, absence_to_paid: 6,
    proxy_clock: 7, interval_shortage: 8, clock_change_withdrawn: 9
  }, validate: true

  validates :event_date, presence: true
  # proxy_clock のみ必須（残り event_type の actor 必須は各 Phase で追記）。不変ゆえ事前防御
  validates :actor_id, presence: true, if: :proxy_clock?
  validates :actor_id, presence: true, if: :leave_approved?  # 2-2b（不変ゆえ事前防御）
  validates :actor_id, presence: true, if: :clock_change_approved?  # 2-3（不変ゆえ事前防御）
  validates :actor_id, presence: true, if: :leave_withdrawn?          # 2-5
  validates :actor_id, presence: true, if: :clock_change_withdrawn?   # 2-5
  validates :actor_id, presence: true, if: :absence_confirmed?  # 4-2c 欠勤確定（§12⑥・不変ゆえ事前防御）
  validates :actor_id, presence: true, if: :absence_to_paid?    # 4-2c 事後有給振替（§12⑥）
  validate :user_must_belong_to_same_organization
  validate :actor_must_belong_to_same_organization
  validate :source_must_belong_to_same_organization

  # 層① — 永続後の UPDATE を AR レベルで封鎖（create は new_record ゆえ通る）
  def readonly? = persisted?

  # 層② — readonly? は destroy を止めないため before_destroy が本体。before_update は belt
  before_update  { raise ActiveRecord::ReadOnlyRecord, "AttendanceHistory is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "AttendanceHistory is append-only" }

  private

  # 複合 FK が DB 層で弾くが、§3.6(2) はモデル検証も要求（クリーンなエラーで surface・user.rb 同型）。
  # ID 基点でガード — 他テナント ID 直接代入は acts_as_tenant が association を nil 解決するため、
  # user.nil? early return では fail-open になる。user.rb の manager 検証と同型に fail-closed 化
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id   # nil（スコープ外）は FK が弾くが AR でも拒否

    errors.add(:user, "は同一組織でなければなりません")
  end

  def actor_must_belong_to_same_organization
    return if actor_id.nil?
    return if actor&.organization_id == organization_id

    errors.add(:actor, "は同一組織でなければなりません")
  end

  # polymorphic は複合 FK を張れないため、モデル検証が source の唯一の構造防衛。
  # source_id 基点でガード（user/actor と同型の fail-closed）— 他テナント ID 直接代入は
  # acts_as_tenant が default_scope で source を nil 解決するため、source.nil? early return では
  # fail-open になる。source_id が立っていれば nil 解決後も nil.respond_to? が false でエラーが立つ
  def source_must_belong_to_same_organization
    return if source_id.nil?
    return if source.respond_to?(:organization_id) && source.organization_id == organization_id

    errors.add(:source, "は同一組織でなければなりません")
  end
end
