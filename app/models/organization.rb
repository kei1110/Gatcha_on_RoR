# frozen_string_literal: true

class Organization < ApplicationRecord
  # テナントルートゆえ acts_as_tenant を付けない（SPEC §3.1）
  has_many :users, dependent: :restrict_with_error
  has_many :company_calendars, dependent: :restrict_with_error
  has_one :organization_setting, dependent: :destroy

  validates :name, presence: true
  validates :subdomain, presence: true, uniqueness: true,
            format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
                      message: "は小文字英数とハイフンのみ使用できます" }
  validates :time_zone, presence: true

  # 範囲外（0 や 13）は % 12 演算でサイレントに別月扱いになるため書き込み時に止める（0b-3 Task 1 レビュー反映）
  validates :fiscal_year_end_month, inclusion: { in: 1..12 }

  # 設定行の唯一の取得経路（0b-5 設計 §0 のアクセサ規約 — Phase 2〜4 の読み取りもここを通すこと）。
  # create_or_find_by! は [organization_id] unique index 前提で並行初回アクセスの
  # SELECT→INSERT 競合を吸収する（属性なし呼び出し = DB 既定値で完結）。
  # with_tenant(self) ラップで呼び出し側のテナント文脈に依らず自組織へアンカー
  # （mismatched with_tenant でも他社行を掴まない・テナント分離レビュー Critical 反映）
  def setting
    organization_setting || ActsAsTenant.with_tenant(self) do
      OrganizationSetting.create_or_find_by!(organization: self).tap do |s|
        # has_one キャッシュの明示更新。create 経路は inverse_of の自動検出が既に更新するが
        # （Rails 8.1 実測）、find フォールバック経路（並行 INSERT 競合時）では設定されない —
        # 明示更新で両経路を決定的にカバーし、inverse_of の暗黙挙動への依存も外す
        assoc = association(:organization_setting)
        assoc.target = s
        assoc.loaded!
      end
    end
  end

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
