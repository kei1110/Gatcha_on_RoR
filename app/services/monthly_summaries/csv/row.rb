# frozen_string_literal: true

require "csv"
require "bigdecimal"

module MonthlySummaries
  module Csv
    # CSV 行生成の共有プリミティブ（SPEC §5・3-3 設計 D12）。
    # 型駆動でセルを整形し、文字列セルのみ formula-injection を無害化する。
    module Row
      BOM = "﻿"
      # スプレッドシートインジェクション: 先頭が = + - @ / TAB / CR の文字列は数式・コマンド評価され得る。
      DANGEROUS_PREFIX = /\A[=+\-@\t\r]/

      module_function

      # 1 行を CRLF 終端・RFC4180 quoting で生成（型駆動・time_zone は Time 整形に使用）
      def line(cells, time_zone: nil)
        ::CSV.generate_line(cells.map { |c| cell(c, time_zone) }, row_sep: "\r\n")
      end

      def cell(value, time_zone = nil)
        case value
        when nil                                then nil
        when String                             then sanitize(value)
        when ActiveSupport::TimeWithZone, Time  then value.in_time_zone(time_zone).strftime("%H:%M")
        when Date                               then value.strftime("%Y-%m-%d")
        when BigDecimal                         then value.to_s("F") # ドット小数（科学記法回避）
        else value.to_s
        end
      end

      def sanitize(str)
        DANGEROUS_PREFIX.match?(str) ? "'#{str}" : str
      end
    end
  end
end
