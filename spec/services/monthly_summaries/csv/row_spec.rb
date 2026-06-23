# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::Csv::Row do
  describe ".line" do
    it "RFC4180 + CRLF 終端で 1 行を生成" do
      expect(described_class.line(%w[a b])).to eq("a,b\r\n")
    end

    it "カンマ・引用符を含む文字列を quoting" do
      expect(described_class.line([ "a,b", 'q"x' ])).to eq(%("a,b","q""x"\r\n))
    end

    it "nil は空セル" do
      expect(described_class.line([ nil, "x" ])).to eq(",x\r\n")
    end

    it "BigDecimal はドット小数（科学記法にしない）" do
      expect(described_class.line([ BigDecimal("8.0"), BigDecimal("0.5") ])).to eq("8.0,0.5\r\n")
    end

    it "Integer はそのまま" do
      expect(described_class.line([ 3 ])).to eq("3\r\n")
    end

    it "Date は YYYY-MM-DD" do
      expect(described_class.line([ Date.new(2026, 3, 5) ])).to eq("2026-03-05\r\n")
    end

    it "Time は組織 TZ で HH:MM" do
      t = Time.utc(2026, 3, 5, 0, 30) # JST 09:30
      expect(described_class.line([ t ], time_zone: "Tokyo")).to eq("09:30\r\n")
    end

    it "formula-injection: 文字列先頭 = + - @ TAB は ' 前置で無害化" do
      expect(described_class.line([ "=SUM(A1)" ])).to eq("'=SUM(A1)\r\n") # ' 前置で無害化・quoting は CSV 判断（カンマ/引用符なし → quoting なし）
      expect(described_class.line([ "+1" ])).to eq("'+1\r\n")
      expect(described_class.line([ "-cmd" ])).to eq("'-cmd\r\n")
      expect(described_class.line([ "@x" ])).to eq("'@x\r\n")
      expect(described_class.line([ "\tx" ])).to eq("'\tx\r\n")
    end

    it "数値の負値はサニタイズしない（型で分岐）" do
      expect(described_class.line([ BigDecimal("-1.5") ])).to eq("-1.5\r\n")
    end
  end
end
