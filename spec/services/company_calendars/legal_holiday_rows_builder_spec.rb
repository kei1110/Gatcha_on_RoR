require "rails_helper"

RSpec.describe CompanyCalendars::LegalHolidayRowsBuilder do
  it "期間内の該当曜日（ISO cwday）だけを legal_holiday 行にする" do
    # 2026-06-01 は月曜。日曜（cwday 7）は 6/7・6/14 の 2 件
    result = described_class.build(start_date: "2026-06-01", end_date: "2026-06-14", cwday: "7")

    expect(result).to be_success
    expect(result.rows).to eq([
      { line: 1, date: Date.new(2026, 6, 7), day_type: "legal_holiday", name: "法定休日", counts_as_paid_leave: false },
      { line: 2, date: Date.new(2026, 6, 14), day_type: "legal_holiday", name: "法定休日", counts_as_paid_leave: false }
    ])
  end

  it "日付不正・曜日未選択・期間逆転・2 年超は行 nil のエラー" do
    expect(described_class.build(start_date: "bogus", end_date: "2026-06-14", cwday: "7")
      .errors.first.message).to include("YYYY-MM-DD")
    expect(described_class.build(start_date: "2026-06-01", end_date: "2026-06-14", cwday: "")
      .errors.first.message).to include("曜日")
    expect(described_class.build(start_date: "2026-06-14", end_date: "2026-06-01", cwday: "7")
      .errors.first.message).to include("終了日")
    expect(described_class.build(start_date: "2026-01-01", end_date: "2028-01-03", cwday: "7")
      .errors.first.message).to include("2 年")
  end

  it "2 年ちょうど（731 日差）は許容（境界）" do
    result = described_class.build(start_date: "2026-01-01", end_date: "2028-01-02", cwday: "7")
    expect(result).to be_success
  end
end
