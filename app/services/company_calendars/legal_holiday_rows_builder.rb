# frozen_string_literal: true

module CompanyCalendars
  # 期間 × 曜日 → legal_holiday 行の生成（週休制専用 — 4 週 4 日制は CSV 個別登録・0b-3 設計 §3）。
  # 生成は labor 有利方向（→ legal_holiday）のみなので BulkUpserter の降格ガードに掛からない
  class LegalHolidayRowsBuilder
    MAX_PERIOD_DAYS = 731 # 2 年（閏年込み）— 行数爆発と「長期登録による失効先送り」の抑止

    Result = Data.define(:rows, :errors) do
      def success? = errors.empty?
    end

    def self.build(start_date:, end_date:, cwday:)
      errors = []
      from = parse_date(start_date)
      to = parse_date(end_date)
      wday = cwday.to_s.match?(/\A[1-7]\z/) ? cwday.to_i : nil # ISO 曜日番号（月=1〜日=7）
      errors << RowError.new(line: nil, message: "開始日・終了日は YYYY-MM-DD 形式で指定してください") if from.nil? || to.nil?
      errors << RowError.new(line: nil, message: "曜日を選択してください") if wday.nil?
      if from && to
        errors << RowError.new(line: nil, message: "終了日は開始日以降にしてください") if to < from
        errors << RowError.new(line: nil, message: "期間は 2 年以内にしてください") if (to - from).to_i > MAX_PERIOD_DAYS
      end
      return Result.new(rows: [], errors:) if errors.any?

      rows = (from..to).select { |d| d.cwday == wday }.map.with_index(1) do |date, line|
        { line:, date:, day_type: "legal_holiday", name: "法定休日", counts_as_paid_leave: false }
      end
      Result.new(rows:, errors: [])
    end

    def self.parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
    private_class_method :parse_date
  end
end
