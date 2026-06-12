require "rails_helper"

RSpec.describe Home::CalendarComponent, type: :component do
  let(:month) { Date.new(2026, 6, 1) }
  let(:today) { Date.new(2026, 6, 15) }

  # 未登録日の ISO 曜日フォールバックを再現（CompanyCalendarResolver#day_types と同じ形）
  def default_day_types(range = Date.new(2026, 6, 1)..Date.new(2026, 6, 30))
    range.index_with { |d| { 6 => :saturday, 7 => :sunday }.fetch(d.cwday, :weekday) }
  end

  def component(records: {}, day_types: default_day_types)
    described_class.new(month:, today:, records:, day_types:)
  end

  describe "#classify" do
    it "当日 working は :working / 過去日 working は :stale_working（退勤忘れの取り残し）" do
      records = {
        Date.new(2026, 6, 15) => build(:attendance_record, work_date: Date.new(2026, 6, 15)),
        Date.new(2026, 6, 10) => build(:attendance_record, work_date: Date.new(2026, 6, 10))
      }
      c = component(records:)
      expect(c.classify(Date.new(2026, 6, 15))).to eq(:working)
      expect(c.classify(Date.new(2026, 6, 10))).to eq(:stale_working)
    end

    it "clocked_out は :clocked_out（過去日でも当日でも）" do
      records = {
        Date.new(2026, 6, 10) => build(:attendance_record, :done, work_date: Date.new(2026, 6, 10)),
        Date.new(2026, 6, 15) => build(:attendance_record, :done, work_date: Date.new(2026, 6, 15))
      }
      c = component(records:)
      expect(c.classify(Date.new(2026, 6, 10))).to eq(:clocked_out)
      expect(c.classify(Date.new(2026, 6, 15))).to eq(:clocked_out)
    end

    it "休日は day_type が :weekday 以外すべて（未登録の土日もフォールバックでグレーにならない — §4.7）" do
      day_types = default_day_types.merge(Date.new(2026, 6, 11) => :holiday,
                                          Date.new(2026, 6, 12) => :legal_holiday)
      c = component(day_types:)
      expect(c.classify(Date.new(2026, 6, 7))).to eq(:holiday)   # 日曜（フォールバック）
      expect(c.classify(Date.new(2026, 6, 6))).to eq(:holiday)   # 土曜（フォールバック）
      expect(c.classify(Date.new(2026, 6, 11))).to eq(:holiday)  # 祝日行
      expect(c.classify(Date.new(2026, 6, 12))).to eq(:holiday)  # 法定休日行
    end

    it "過去の未打刻平日は :unpunched・当日未打刻と未来日は :plain・月外は :outside" do
      c = component
      expect(c.classify(Date.new(2026, 6, 10))).to eq(:unpunched) # 過去平日（水）
      expect(c.classify(Date.new(2026, 6, 15))).to eq(:plain)     # 当日（月）未打刻
      expect(c.classify(Date.new(2026, 6, 22))).to eq(:plain)     # 未来平日
      expect(c.classify(Date.new(2026, 5, 31))).to eq(:outside)   # 前月余白
    end

    it "休日に出勤記録があれば記録の分類が勝つ（休日出勤の可視化）" do
      records = { Date.new(2026, 6, 7) => build(:attendance_record, :done, work_date: Date.new(2026, 6, 7)) }
      expect(component(records:).classify(Date.new(2026, 6, 7))).to eq(:clocked_out)
    end
  end

  describe "レンダリング" do
    it "月タイトル・曜日ヘッダ・前後月ナビが出る" do
      render_inline(component)
      expect(page).to have_text("2026年6月")
      expect(page).to have_link("← 前月", href: "/?month=2026-05")
      expect(page).to have_link("翌月 →", href: "/?month=2026-07")
      expect(page).to have_text("日")
      expect(page).to have_text("土")
    end

    it "2026 年 6 月は月初が月曜 — 前週日曜の余白セルは数字なし・30 日分が描画される" do
      render_inline(component)
      expect(page).to have_css("td", text: /\A30\z/) # 6/30
      expect(page).to have_css("tbody tr", count: 5) # 6 月は 5 週
    end

    it "2 月（28 日・月初日曜）の境界でも壊れない" do
      feb = described_class.new(month: Date.new(2026, 2, 1), today: Date.new(2026, 2, 10),
                                records: {},
                                day_types: default_day_types(Date.new(2026, 2, 1)..Date.new(2026, 2, 28)))
      render_inline(feb)
      expect(page).to have_text("2026年2月")
      expect(page).to have_css("td", text: /\A28\z/)
      expect(page).to have_css("tbody tr", count: 4) # 2/1 日曜開始 → ちょうど 4 週
    end
  end
end
