# frozen_string_literal: true

require "csv"

module CompanyCalendars
  # CSV → 行 hash（行番号付きエラー）。読み取りは 4 列のみ — organization_id / fiscal_year 等の
  # 混入列は受理しない（CSV は strong params を通らないため、ここが mass-assignment 防壁の代替 — 0b-3 設計 §3）
  class CsvParser
    MAX_BYTES = 1.megabyte # パース前のメモリガード（行数上限は BulkUpserter::MAX_ROWS が妥当性ガード）
    REQUIRED_HEADERS = %w[date day_type].freeze
    TRUE_VALUES = %w[true 1].freeze
    FALSE_VALUES = [ "false", "0", "", nil ].freeze

    Result = Data.define(:rows, :errors) do
      def success? = errors.empty?
    end

    def self.parse(file) = new(file).parse

    def initialize(file)
      @file = file
    end

    # 検証順序が DoS 緩和の要: 型 → バイト上限 → エンコーディング → CSV パース（0b-3 設計 §3）
    def parse
      fatal = precheck
      return failure(fatal) if fatal

      table = CSV.parse(@content, headers: true)
      missing = REQUIRED_HEADERS - (table.headers || []).compact
      return failure("ヘッダ行に必須列（#{missing.join(', ')}）がありません") if missing.any?
      if table.size > BulkUpserter::MAX_ROWS
        return failure("行数が上限 #{BulkUpserter::MAX_ROWS} を超えています（#{table.size} 行）")
      end

      build_rows(table)
    rescue CSV::MalformedCSVError => e
      failure("CSV の形式が不正です: #{e.message}")
    end

    private

    def precheck
      return "ファイルを選択してください" unless @file.respond_to?(:read)
      return "ファイルサイズが上限 1MB を超えています" if @file.respond_to?(:size) && @file.size > MAX_BYTES

      @content = @file.read.force_encoding(Encoding::UTF_8)
      # size を持たない IO でも read 後のバイト数で二重ガード（メモリピークは読込分のみ）
      return "ファイルサイズが上限 1MB を超えています" if @content.bytesize > MAX_BYTES

      @content.delete_prefix!("\xEF\xBB\xBF") # BOM 許容
      return "文字コードが UTF-8 ではありません。UTF-8 で保存し直してください" unless @content.valid_encoding?

      nil
    end

    def build_rows(table)
      rows = []
      errors = []
      seen = {}
      table.each.with_index(2) do |csv_row, line| # ヘッダが 1 行目
        row, error = convert(csv_row, line)
        next errors << error if error

        if (dup_line = seen[row[:date]])
          errors << RowError.new(line:, message: "#{row[:date]} が #{dup_line} 行目と重複しています")
          next
        end
        seen[row[:date]] = line
        rows << row
      end
      Result.new(rows:, errors:)
    end

    def convert(csv_row, line)
      date = Date.iso8601(csv_row["date"].to_s)
      day_type = csv_row["day_type"].to_s
      unless CompanyCalendar.day_types.key?(day_type)
        return [ nil, RowError.new(line:, message:
          "day_type「#{day_type}」は不正です（#{CompanyCalendar.day_types.keys.join(' / ')} のいずれか）") ]
      end
      counts, counts_error = parse_boolean(csv_row["counts_as_paid_leave"], line)
      return [ nil, counts_error ] if counts_error

      [ { line:, date:, day_type:, name: csv_row["name"].presence, counts_as_paid_leave: counts }, nil ]
    rescue Date::Error
      [ nil, RowError.new(line:, message: "date「#{csv_row['date']}」は YYYY-MM-DD 形式で指定してください") ]
    end

    def parse_boolean(value, line)
      normalized = value&.strip
      return [ true, nil ] if TRUE_VALUES.include?(normalized)
      return [ false, nil ] if FALSE_VALUES.include?(normalized)

      [ nil, RowError.new(line:, message:
        "counts_as_paid_leave「#{value}」は true / 1 / false / 0 / 空 のいずれかで指定してください") ]
    end

    def failure(message)
      Result.new(rows: [], errors: [ RowError.new(line: nil, message:) ])
    end
  end
end
