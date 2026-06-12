module Home
  # 当月カレンダー（§12.1 最小・1-1 設計 §4）。色分けは 1-1 で判定可能な分類のみ —
  # 休暇=緑/半休=黄/欠勤=赤は Phase 2/4-2 で classify に分岐を足す。
  # day_types は CompanyCalendarResolver#day_types の戻り値（未登録日の ISO 曜日フォールバック内蔵）
  class CalendarComponent < ViewComponent::Base
    WDAYS = %w[日 月 火 水 木 金 土].freeze

    CELL_CLASSES = {
      outside: "",
      working: "bg-blue-200 font-bold",
      stale_working: "bg-blue-100",   # 退勤忘れの取り残し — 退勤済と同系（1-1 設計 §4）
      clocked_out: "bg-blue-100",
      holiday: "bg-orange-50 text-orange-400",
      unpunched: "bg-gray-200 text-gray-500",
      plain: ""
    }.freeze

    # month: 月初日 / today: Organization#today / records: { work_date => AttendanceRecord }
    def initialize(month:, today:, records:, day_types:)
      @month = month
      @today = today
      @records = records
      @day_types = day_types
    end

    def title = @month.strftime("%Y年%-m月")
    def prev_month_param = (@month << 1).strftime("%Y-%m")
    def next_month_param = (@month >> 1).strftime("%Y-%m")

    # 日曜始まりの週配列（前後月の余白セル込み — §4.7 の暦週解釈と整合）
    def weeks
      first = @month.beginning_of_week(:sunday)
      last  = @month.end_of_month.end_of_week(:sunday)
      (first..last).each_slice(7)
    end

    # 日 → 分類 symbol（spec で全分類網羅・1-1 設計 §4）。出勤記録は休日判定より優先（休日出勤の可視化）
    def classify(date)
      return :outside unless date.month == @month.month

      record = @records[date]
      if record&.working?
        date == @today ? :working : :stale_working
      elsif record
        :clocked_out
      elsif holiday?(date)
        :holiday
      elsif date < @today
        :unpunched
      else
        :plain
      end
    end

    def cell_class(date) = CELL_CLASSES.fetch(classify(date))

    def outside?(date) = classify(date) == :outside

    private

    # :weekday 以外（saturday/sunday/holiday/company_holiday/legal_holiday）を休日 1 スタイルに縮約
    # （§12.1 は休日種別の視覚区別を要求しない — YAGNI レビュー反映）。
    # fetch の既定 :weekday — day_types の範囲と month がズレても全セル休日化させない fail-safe
    def holiday?(date)
      @day_types.fetch(date, :weekday) != :weekday
    end
  end
end
