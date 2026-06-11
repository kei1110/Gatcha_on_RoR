require "rails_helper"

RSpec.describe CompanyCalendars::CsvParser do
  def upload(content)
    file = Tempfile.new([ "calendar", ".csv" ])
    file.binmode
    file.write(content.b)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv")
  end

  it "正常系: 4 列を行 hash に変換（name 空は nil・counts 空は false・行番号はヘッダ込み）" do
    result = described_class.parse(upload(<<~CSV))
      date,day_type,name,counts_as_paid_leave
      2026-01-01,holiday,元日,
      2026-08-13,company_holiday,夏季休業,true
      2026-04-06,weekday,,0
    CSV

    expect(result).to be_success
    expect(result.rows).to eq([
      { line: 2, date: Date.new(2026, 1, 1), day_type: "holiday", name: "元日", counts_as_paid_leave: false },
      { line: 3, date: Date.new(2026, 8, 13), day_type: "company_holiday", name: "夏季休業", counts_as_paid_leave: true },
      { line: 4, date: Date.new(2026, 4, 6), day_type: "weekday", name: nil, counts_as_paid_leave: false }
    ])
  end

  it "BOM 付き UTF-8 を受理し、未知列（organization_id 等）は無視する（ホワイトリスト・設計 §3）" do
    result = described_class.parse(upload(
      "\xEF\xBB\xBFdate,day_type,name,counts_as_paid_leave,organization_id,fiscal_year\n" \
      "2026-01-01,holiday,元日,,999,1999\n"))
    expect(result).to be_success
    expect(result.rows.first.keys).to contain_exactly(:line, :date, :day_type, :name, :counts_as_paid_leave)
  end

  it "date 不正・day_type 不正・counts 不正は行番号付きエラー（正常行も全件不採用の材料として返す）" do
    result = described_class.parse(upload(<<~CSV))
      date,day_type,name,counts_as_paid_leave
      2026/01/01,holiday,元日,
      2026-02-11,祝日,建国記念の日,
      2026-03-20,holiday,春分の日,yes
    CSV

    expect(result).not_to be_success
    expect(result.errors.map(&:line)).to eq([ 2, 3, 4 ])
    expect(result.errors[0].message).to include("YYYY-MM-DD")
    expect(result.errors[1].message).to include("day_type") # 日本語ラベルは受理しない（設計 §0）
    expect(result.errors[2].message).to include("counts_as_paid_leave")
  end

  it "CSV 内の日付重複は後行をエラーにする" do
    result = described_class.parse(upload(<<~CSV))
      date,day_type,name,counts_as_paid_leave
      2026-01-01,holiday,元日,
      2026-01-01,weekday,,
    CSV
    expect(result.errors.map(&:line)).to eq([ 3 ])
    expect(result.errors.first.message).to include("重複")
  end

  it "ファイル欠落・必須ヘッダ欠落・非 UTF-8・壊れた CSV はファイルエラー（line nil）" do
    expect(described_class.parse(nil).errors.first.message).to include("ファイルを選択")
    expect(described_class.parse(upload("day_type,name\nholiday,x\n")).errors.first.message).to include("date")
    expect(described_class.parse(upload("date,day_type\n2026-01-01,祝日\n".encode("Shift_JIS")))
      .errors.first.message).to include("UTF-8")
    expect(described_class.parse(upload(%(date,day_type\n"2026-01-01,holiday\n)))
      .errors.first.message).to include("CSV")
  end

  it "行数 2,001 行は上限エラー" do
    body = (0...2_001).map { |n| "#{Date.new(2026, 1, 1) + n},weekday,," }.join("\n")
    result = described_class.parse(upload("date,day_type,name,counts_as_paid_leave\n#{body}\n"))
    expect(result.errors.first.message).to include("2000")
  end

  it "1MB 超はパース前に拒否（DoS ガード — 検証順序・設計 §3）" do
    big = "date,day_type\n" + "x" * 1.megabyte
    expect(described_class.parse(upload(big)).errors.first.message).to include("1MB")
  end

  it "size を持たない IO でも read 後のバイト数で 1MB 超を拒否（素通り経路の遮断）" do
    reader = Class.new do
      def initialize(content) = @content = content
      def read = @content
    end.new("date,day_type\n" + "x" * 1.megabyte)
    expect(described_class.parse(reader).errors.first.message).to include("1MB")
  end

  it "ヘッダのみ（0 データ行）は success（no-op インポートとして許容）" do
    result = described_class.parse(upload("date,day_type,name,counts_as_paid_leave\n"))
    expect(result).to be_success
    expect(result.rows).to be_empty
  end
end
