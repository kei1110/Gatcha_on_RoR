class Organization < ApplicationRecord
  # テナントルートゆえ acts_as_tenant を付けない（SPEC §3.1）
  has_many :users, dependent: :restrict_with_error

  validates :name, presence: true
  validates :subdomain, presence: true, uniqueness: true,
            format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
                      message: "は小文字英数とハイフンのみ使用できます" }
  validates :time_zone, presence: true

  # 範囲外（0 や 13）は % 12 演算でサイレントに別月扱いになるため書き込み時に止める（0b-3 Task 1 レビュー反映）
  validates :fiscal_year_end_month, inclusion: { in: 1..12 }

  # 「年度の開始年」を文字列で返す（例: 3 月決算で 2027-01-15 → "2026"）。
  # Organization が fiscal_year_end_month の所有者ゆえここに置く（0b-3 設計 §2。
  # CompanyCalendar.fiscal_year / Phase 2 の LeaveBalance.fiscal_year はこの値を使う）
  def fiscal_year_for(date)
    start_month = fiscal_year_end_month % 12 + 1
    (date.month >= start_month ? date.year : date.year - 1).to_s
  end

  # 「今日」の単一ソース（組織 TZ・0b-4 設計 §0）。config.time_zone は未設定（UTC）のため
  # Date.current は JST 0:00〜8:59 に前日を返す。WorkPattern 無効化ガード・割当の表示分類・
  # 未割当バナー（Phase 1 の打刻日判定もここに合流予定）は必ずこれを使うこと
  def today
    Time.current.in_time_zone(time_zone).to_date
  end
end
