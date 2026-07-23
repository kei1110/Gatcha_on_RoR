# frozen_string_literal: true

class HomeController < ApplicationController
  # 月ナビの暴走 URL（遠方年）を当月へフォールバックさせる範囲ガード（1-1 設計 §4）
  MONTH_RANGE = Date.new(2020, 1, 1)..Date.new(2100, 12, 1)

  def show
    authorize :home, :show?
    @state = Clockings::State.new(user: current_user)
    @month = parse_month
    # カレンダーは current_user 起点必須（ClockingPolicy の補償統制 — 1-1 設計 §4）。
    # 当月データは各 1 クエリ（records は index_by で日付引きに変換）
    @records = current_user.attendance_records
                           .where(work_date: @month.all_month).index_by(&:work_date)
    @day_types = CompanyCalendarResolver.new(organization: ActsAsTenant.current_tenant)
                                        .day_types(@month, @month.end_of_month)
  end

  private

  # ?month=YYYY-MM。不正値・範囲外は今日の月へフォールバック（1-1 設計 §4）
  def parse_month
    month = Date.strptime(params[:month].to_s, "%Y-%m")
    MONTH_RANGE.cover?(month) ? month : @state.today.beginning_of_month
  rescue ArgumentError
    @state.today.beginning_of_month
  end
end
