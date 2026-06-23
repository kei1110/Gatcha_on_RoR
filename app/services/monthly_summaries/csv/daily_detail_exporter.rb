# frozen_string_literal: true

module MonthlySummaries
  module Csv
    # 日別明細 CSV（§6.4・1 行=1 実在 AR・3-3 設計 §4/§5）。
    # records は controller が period.range で事前 .to_a した AR 配列・time_zone は組織 TZ。
    class DailyDetailExporter
      def self.call(records:, time_zone:) = new(records:, time_zone:).call

      def initialize(records:, time_zone:)
        @records = records
        @time_zone = time_zone
      end

      def call
        Enumerator.new do |y|
          y << Row::BOM + Row.line(I18n.t("monthly_summaries.csv.detail_headers"))
          @records.each { |r| y << Row.line(row_for(r), time_zone: @time_zone) }
        end
      end

      private

      def row_for(record)
        [
          record.work_date, record.clock_in, record.clock_out,
          record.actual_work_hours, record.legal_overtime_hours, record.deep_night_hours,
          record.late_minutes, record.early_leave_minutes,
          I18n.t("activerecord.attributes.attendance_record.statuses.#{record.status}")
        ]
      end
    end
  end
end
