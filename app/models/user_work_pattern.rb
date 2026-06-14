# frozen_string_literal: true

class UserWorkPattern < ApplicationRecord
  # 意味論（0b-4 設計 §0）: active=false は「誤登録の論理削除」専用。
  # 正常な終了・切替は end_date で表現する（切替 = 旧割当の end_date 設定 → 新規作成）。
  # 無効化は過去日の所定根拠を消すための操作ではない。
  # 過去割当は Phase 1 の「未打刻日の所定根拠」として温存（destroy ルートなし）
  acts_as_tenant(:organization)

  belongs_to :user
  belongs_to :work_pattern

  # Phase 1 の打刻時取得（SPEC §4.6「打刻日時点で有効な 1 件」）と未割当バナーの単一ソース。
  # この述語を他所に二度書かないこと（定義が割れると Phase 1 接続が穴あきになる）
  scope :effective_on, ->(date) {
    where(active: true)
      .where(start_date: ..date)
      .where("end_date IS NULL OR end_date >= ?", date)
  }

  validates :start_date, presence: true
  validate :end_date_not_before_start_date
  # 発火条件は「保存後に active であるすべての保存」（0b-4 設計 §2-2）—
  # create / update / activate（update(active: true)）が単一の検証に収束する
  validate :no_overlap_with_active_assignments, if: :active?
  validate :work_pattern_must_be_active_and_same_tenant,
           if: -> { new_record? || work_pattern_id_changed? || (active_changed? && active?) }

  private

  def end_date_not_before_start_date
    return if start_date.blank? || end_date.blank? || end_date >= start_date

    errors.add(:end_date, "は適用開始日以降の日付にしてください")
  end

  # ②型クエリ（RAILS_GOTCHAS の①型/②型書き分け）: user_id は全域一意 PK + 複合 FK
  # (organization_id, user_id) が越境を排除するため organization_id 明示不要。
  # without_tenant ラップで mismatched with_tenant 文脈（console で他社テナント設定中の操作）
  # でも default scope に実在行を隠されない。
  # 式は DB の exclusion constraint と同一の daterange '[]' — 意味の二重実装を避ける
  def no_overlap_with_active_assignments
    return if user_id.blank? || start_date.blank?
    return if end_date.present? && end_date < start_date # daterange が逆転で DB エラーになる入力は日付検証に委ねる

    conflict = ActsAsTenant.without_tenant do
      UserWorkPattern.where(user_id: user_id, active: true).where.not(id: id)
                     .where("daterange(start_date, end_date, '[]') && daterange(?, ?, '[]')",
                            start_date, end_date)
                     .order(:start_date).first
    end
    return if conflict.nil?

    period = conflict.end_date ? "#{conflict.start_date} 〜 #{conflict.end_date}" : "#{conflict.start_date} 〜（無期限）"
    errors.add(:base, "適用期間が既存の割当（#{period}）と重複しています")
  end

  # fail-closed（user.rb の manager_must_belong_to_same_organization と同型・0b-4 設計 §2-3）:
  # テナントスコープ下では他テナント id の association 解決が nil になるため、
  # without_tenant で実体を引き、nil（=実在しない）と組織不一致を明示エラーにする。
  # 改竄 POST を 422 で止め、複合 FK は最終防衛に退かせる
  def work_pattern_must_be_active_and_same_tenant
    return if work_pattern_id.blank? # presence は belongs_to が拾う

    pattern = ActsAsTenant.without_tenant { WorkPattern.find_by(id: work_pattern_id) }
    if pattern.nil? || pattern.organization_id != organization_id
      errors.add(:work_pattern_id, "は同一組織の勤務パターンである必要があります")
    elsif !pattern.active?
      errors.add(:work_pattern_id, "は有効な勤務パターンである必要があります")
    end
  end
end
