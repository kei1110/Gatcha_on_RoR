# frozen_string_literal: true

module MonthlySummaries
  module Csv
    # 月次サマリ CSV（§6.4・1 行=1 社員・給与システム入力用・3-3 設計 §4/§5）。
    # summaries は controller が policy_scope + includes(:user) で事前 .to_a した配列（body で DB を引かない）。
    class SummaryExporter
      def self.call(summaries:) = new(summaries:).call

      def initialize(summaries:)
        @summaries = summaries
      end

      def call
        Enumerator.new do |y|
          y << Row::BOM + Row.line(I18n.t("monthly_summaries.csv.summary_headers"))
          @summaries.each { |s| y << Row.line(row_for(s)) }
        end
      end

      private

      def row_for(summary)
        u = summary.user
        [
          u.employee_code, u.name,
          summary.scheduled_work_days, summary.work_days,
          summary.total_work_hours, summary.total_overtime_hours, summary.overtime_hours_over_60,
          summary.holiday_work_hours, summary.total_deep_night_hours,
          (u.exempt_from_overtime? ? "1" : "0"),
          summary.paid_leave_days_used, summary.late_days, summary.early_leave_days,
          summary.total_leave_hours
        ]
      end
    end
  end
end
