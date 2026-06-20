# frozen_string_literal: true

require "bigdecimal"

module MonthlySummaries
  # 月次（締め期間）集計（SPEC §4.13/§5.2/§6.4/§8・3-1 設計 §3）。
  # AR 群 → MonthlyAttendanceSummary（永久保持）の確定スナップショットを per-user・冪等に upsert。
  # 集計の期間は締め期間（AttendancePeriod・closing_day 基準）。判定（§8 コンプラ）はしない＝素材保存のみ。
  # 無条件上書き（F1）: status は見ない純関数。submitted/finalized を上書きしないゲートは呼び出し側責務（3-2/4-2）。
  class Aggregate
    # AR 由来集計の母数（D10）。on_leave（#104 stale 含む）は除外。
    WORKED_STATUSES = %i[working clocked_out morning_half afternoon_half].freeze

    def self.call(user:, period:, day_types: nil) = new(user:, period:, day_types:).call

    def initialize(user:, period:, day_types: nil)
      @user = user
      @period = period
      @injected_day_types = day_types
    end

    def call
      ActsAsTenant.with_tenant(@user.organization) do
        summary = MonthlyAttendanceSummary.find_or_initialize_by(user: @user, year_month: @period.label)
        summary.update!(attributes)
        summary
      end
    end

    private

    def attributes
      {
        scheduled_work_days:    scheduled_work_days,
        work_days:              in_period.size,
        total_work_hours:       sum_hours(in_period, :actual_work_hours),
        total_deep_night_hours: sum_hours(in_period, :deep_night_hours),
        holiday_work_hours:     sum_hours(in_period.select { holiday_work?(_1) }, :actual_work_hours),
        total_overtime_hours:   total_overtime_hours,
        overtime_hours_over_60: [ total_overtime_hours - 60, BigDecimal("0") ].max,
        late_days:              in_period.count(&:is_late),
        early_leave_days:       in_period.count(&:is_early_leave)
      }
    end

    # 日次 legal OT 寄与（period.range 内・法定休日除く）＋ 週次 extra（週末土曜が period.range 内）。
    # 日次=各日の属する締め期間／週次=土曜の属する締め期間（二重の帰属軸・設計 §3.3）。
    def total_overtime_hours
      @total_overtime_hours ||=
        sum_hours(in_period.reject { holiday_work?(_1) }, :legal_overtime_hours) + weekly_overtime_hours
    end

    # service は worked_records を calculator が食える値配列へ写すだけ。分配は WeeklyOvertimeCalculator（D8）。
    def weekly_overtime_hours
      days = worked_records.map do |r|
        { date: r.work_date,
          actual_hours: r.actual_work_hours || 0,
          daily_legal_overtime_hours: r.legal_overtime_hours || 0,
          legal_holiday_work: holiday_work?(r),
          flextime: r.work_pattern&.flextime? || false } # D7・未割当は false
      end
      WeeklyOvertimeCalculator.call(period_range: @period.range, days:)
    end

    # 出勤系 status かつ計算済みの AR を窓（week_window）で取得（D10・flextime 判定の N+1 回避）。
    # .calculated（8 列非 NULL）必須: 未退勤 working（recalculate.rb:9 で常に未計算）や打刻前半休が
    # 母数に乗ると「出勤日 +1・時間 0」の水増しが永久サマリへ焼き付く。未計算の除外はこのスコープ経由が不変条件。
    def worked_records
      @worked_records ||= AttendanceRecord
        .where(user: @user, work_date: @period.week_window, status: WORKED_STATUSES)
        .calculated
        .includes(:work_pattern).to_a
    end

    # 日次集計の母数 = period.range 内の出勤行
    def in_period
      @in_period ||= worked_records.select { @period.range.cover?(_1.work_date) }
    end

    def day_types
      @day_types ||= @injected_day_types ||
        CompanyCalendarResolver.new(organization: @user.organization)
          .day_types(@period.week_window.first, @period.week_window.last)
    end

    def holiday_work?(record)
      record.is_holiday_work && day_types[record.work_date] == :legal_holiday
    end

    def scheduled_work_days
      @period.range.count { day_types[_1] == :weekday }
    end

    def sum_hours(records, attr)
      records.sum(BigDecimal("0")) { _1.public_send(attr) || 0 }
    end
  end
end
