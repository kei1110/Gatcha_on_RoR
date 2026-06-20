# frozen_string_literal: true

# 締め期間（closing_day 基準）の不変な値オブジェクト（3-1 設計 §1.2・D9）。
# (organization, year_month) から締め期間の全属性を導出し、3-1/3-2/3-3/4-x が共有する背骨。
# 週は暦週（日〜土・労基法）のまま歪めず、本オブジェクトは「どの週・どの日が当期か」の帰属だけを担う。
class AttendancePeriod
  # 厳格 YYYY-MM（MonthlyAttendanceSummary の format バリデーションと同一）。
  # strptime は "2026-3"（1 桁月）や "2026-03foo"（末尾ゴミ）を 03-01 と黙認するため、値オブジェクト側で先に弾く。
  YEAR_MONTH_FORMAT = /\A\d{4}-(0[1-9]|1[0-2])\z/

  # year_month = 締め日が属する暦月のラベル "YYYY-MM"。不正値は ArgumentError で早期に弾く。
  def initialize(organization:, year_month:)
    raise ArgumentError, "invalid year_month: #{year_month.inspect}" unless YEAR_MONTH_FORMAT.match?(year_month)

    @organization = organization
    @year_month   = year_month
    @label_first  = Date.strptime(year_month, "%Y-%m") # 厳格検証済み（"2026-13" は regex で弾かれる）
  end

  attr_reader :year_month
  alias_method :label, :year_month

  # 締め期間 [start, last]（closing_day 尊重）
  def range
    @range ||= (period_start..period_end)
  end

  # 週次 OT 用 fetch 窓 = 期初日を含む週の日曜 .. 期末日
  def week_window
    @week_window ||= (range.first.beginning_of_week(:sunday)..range.last)
  end

  def prev
    self.class.new(organization: @organization, year_month: @label_first.prev_month.strftime("%Y-%m"))
  end

  def next
    self.class.new(organization: @organization, year_month: @label_first.next_month.strftime("%Y-%m"))
  end

  # 締め日(期末)の暦年度ラベル。年度境界をまたぐ期は前年度日も closing FY へ寄る近似（設計 §5 限界12）。
  def fiscal_year = @organization.fiscal_year_for(range.last)

  private

  def closing_day = @organization.setting.closing_day

  # ラベル月 first_of_month の締め日（31=月末・各月末日でクランプ）
  def closing_date_for(first_of_month)
    last = first_of_month.end_of_month
    Date.new(first_of_month.year, first_of_month.month, [ closing_day, last.day ].min)
  end

  def period_end   = closing_date_for(@label_first)
  def period_start = closing_date_for(@label_first.prev_month) + 1
end
