# frozen_string_literal: true

# 日付 → day_type の解決（SPEC §4.7 指定名のため CompanyCalendars:: 名前空間外 — 0b-3 設計 §1）。
# AR 依存ゆえ calculators（値→値・DB なし）には置けない。Phase 1 では入力合成層（service/job）が
# 本クラスを呼び、calculator へは day_type を**値として**渡すこと（SPEC §2.2-1 の境界）
class CompanyCalendarResolver
  # 未登録日の ISO 曜日フォールバック（ロケール非依存・SPEC §4.7）: 1〜5=weekday / 6=saturday / 7=sunday
  FALLBACK_DAY_TYPES = { 6 => :saturday, 7 => :sunday }.freeze

  # organization 明示必須 — without_tenant 文脈の fail-open 遮断（0b-3 設計 §3）
  def initialize(organization:)
    raise ArgumentError, "organization は必須です" if organization.nil?

    @organization = organization
  end

  def day_type(date)
    with_tenant { CompanyCalendar.find_by(date: date)&.day_type&.to_sym } || fallback(date)
  end

  # 登録由来かフォールバック由来かの判別 — Phase 1 の「未特定の休日労働は 35% 側 or 警告」の手がかり。
  # フォールバックの :sunday を「所定休日」と断定させない（労務レビュー反映・0b-3 設計 §3）
  def registered?(date)
    with_tenant { CompanyCalendar.exists?(date: date) }
  end

  # 範囲一括（1 クエリ）— 月次処理の N+1 を防ぎ、生 SQL へ逃げる誘因を残さない
  def day_types(from, to)
    registered = with_tenant { CompanyCalendar.where(date: from..to).pluck(:date, :day_type).to_h }
    (from..to).index_with { |d| registered[d]&.to_sym || fallback(d) }
  end

  # day_types の上位版（Phase 2-2a 設計 §2.2）。counts_as_paid_leave を surface し
  # LeaveDaysCalculator の company_holiday 分岐に渡す。company_holiday 以外の flag は false 固定。
  def day_classifications(from, to)
    registered = with_tenant do
      CompanyCalendar.where(date: from..to).pluck(:date, :day_type, :counts_as_paid_leave)
    end.to_h { |date, dt, cpl| [ date, { day_type: dt.to_sym, counts_as_paid_leave: cpl } ] }
    (from..to).index_with do |d|
      registered[d] || { day_type: fallback(d), counts_as_paid_leave: false }
    end
  end

  private

  def fallback(date)
    FALLBACK_DAY_TYPES.fetch(date.cwday, :weekday)
  end

  def with_tenant(&) = ActsAsTenant.with_tenant(@organization, &)
end
