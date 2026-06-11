class CompanyCalendar < ApplicationRecord
  # 宣言順が重要: acts_as_tenant の organization_id 代入（before_validation, on: :create）が
  # 先に登録されるため、後続の set_fiscal_year から organization を参照できる（0b-3 設計 §2）
  acts_as_tenant(:organization)

  # validate: true — CSV 入力が直結するため必須（RAILS_GOTCHAS）。
  # legal_holiday と sunday の排他（SPEC §4.7）は単一 enum カラムにより構造的に保証
  enum :day_type, {
    weekday: 0, saturday: 1, sunday: 2,
    holiday: 3, company_holiday: 4, legal_holiday: 5
  }, validate: true

  before_validation :set_fiscal_year
  # before_save も登録: validate: false で保存する場合（DB レベル unique 検証等）に
  # before_validation が呼ばれないため、fiscal_year NOT NULL 制約に先に引っかかる事故を防ぐ
  before_save :set_fiscal_year

  validates :date, presence: true
  validates_uniqueness_to_tenant :date
  validates :day_type, presence: true
  # date あり + fiscal_year nil = 導出バグの場合のみ守る。date nil 時は date 側のエラーで十分
  # （UI 非露出属性の冗長エラーを出さない — Task 2 レビュー反映）
  validates :fiscal_year, presence: true, if: -> { date.present? }
  validates :name, presence: true, if: -> { holiday? || company_holiday? }
  validate :counts_as_paid_leave_only_for_company_holiday

  private

  # current_tenant でなく**レコードの organization** から導出 — without_tenant 文脈・
  # with_tenant ミスマッチ時に他社の決算月で算出する取り違えを構造的に排除（0b-3 設計 §2）
  def set_fiscal_year
    self.fiscal_year = organization&.fiscal_year_for(date) if date
  end

  # §4.7 の列定義どおり会社休業日専用。true 運用には計画的付与の労使協定等の根拠が必要
  # （労基法 39 条 6 項 — 社労士確認 #10）。暗黙で握りつぶさず明示エラー
  def counts_as_paid_leave_only_for_company_holiday
    return unless counts_as_paid_leave? && !company_holiday?

    errors.add(:counts_as_paid_leave, "は会社休業日でのみ設定できます")
  end
end
