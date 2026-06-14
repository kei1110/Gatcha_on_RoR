# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompanyCalendar, type: :model do
  describe "date（3 点セット・gen-spec 規約）" do
    it "is unique within tenant" do
      create(:company_calendar, date: "2026-01-01")
      expect(build(:company_calendar, date: "2026-01-01")).not_to be_valid
    end

    it "allows same date in another tenant (鏡像)" do
      create(:company_calendar, date: "2026-01-01")
      ActsAsTenant.with_tenant(create(:organization)) do
        expect(build(:company_calendar, date: "2026-01-01")).to be_valid
      end
    end

    it "is enforced by composite unique index at DB level" do
      cal = create(:company_calendar, date: "2026-01-01")
      dup = build(:company_calendar, date: "2026-01-01", organization: cal.organization)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "day_type" do
    it "全 6 値を受け付け、不正値は invalid（enum validate: true — ArgumentError 500 にしない）" do
      %i[weekday saturday sunday holiday company_holiday legal_holiday].each do |t|
        cal = build(:company_calendar, day_type: t)
        cal.name = "名称" # holiday/company_holiday の name 必須を満たす
        expect(cal).to be_valid, "day_type=#{t}: #{cal.errors.full_messages}"
      end
      expect(build(:company_calendar, day_type: "bogus")).not_to be_valid
    end

    it "整数マッピングを固定（DB 値依存のリオーダー事故検知）" do
      expect(CompanyCalendar.day_types).to eq(
        "weekday" => 0, "saturday" => 1, "sunday" => 2,
        "holiday" => 3, "company_holiday" => 4, "legal_holiday" => 5)
    end

    it "全 enum 値に ja.yml の表示名がある（訳語欠落の検知）" do
      CompanyCalendar.day_types.keys.each do |key|
        expect(I18n.exists?("company_calendars.day_types.#{key}")).to be(true), "missing: #{key}"
      end
    end
  end

  describe "name の条件付き必須" do
    it "holiday / company_holiday は name 必須・weekday / saturday / sunday / legal_holiday は不要（対照）" do
      expect(build(:company_calendar, day_type: :holiday, name: nil)).not_to be_valid
      expect(build(:company_calendar, day_type: :company_holiday, name: nil)).not_to be_valid
      expect(build(:company_calendar, day_type: :weekday, name: nil)).to be_valid
      expect(build(:company_calendar, day_type: :saturday, name: nil)).to be_valid
      expect(build(:company_calendar, day_type: :sunday, name: nil)).to be_valid
      expect(build(:company_calendar, day_type: :legal_holiday, name: nil)).to be_valid
    end
  end

  describe "counts_as_paid_leave の相関（§4.7 — 会社休業日専用）" do
    it "company_holiday なら true 可・それ以外は invalid（対照）" do
      expect(build(:company_calendar, day_type: :company_holiday, name: "夏季休業",
                   counts_as_paid_leave: true)).to be_valid
      cal = build(:company_calendar, day_type: :holiday, counts_as_paid_leave: true)
      expect(cal).not_to be_valid
      expect(cal.errors[:counts_as_paid_leave]).to be_present
    end
  end

  describe "fiscal_year 自動導出（0b-3 設計 §2）" do
    it "レコードの organization の決算月から導出される（3 月決算既定: 3/31 と 4/1 が境界）" do
      expect(create(:company_calendar, date: "2026-03-31").fiscal_year).to eq("2025")
      expect(create(:company_calendar, date: "2026-04-01").fiscal_year).to eq("2026")
    end

    it "current_tenant でなくレコードの organization から導出（取り違え検知）" do
      dec_org = create(:organization, fiscal_year_end_month: 12)
      cal = ActsAsTenant.with_tenant(dec_org) do
        create(:company_calendar, date: "2026-01-15")
      end
      expect(cal.fiscal_year).to eq("2026") # 12 月決算 = 暦年。3 月決算なら "2025" になる
    end

    it "date 変更時に再導出される" do
      cal = create(:company_calendar, date: "2026-03-31")
      cal.update!(date: "2026-04-02")
      expect(cal.fiscal_year).to eq("2026")
    end

    it "date が nil のとき fiscal_year の冗長エラーは出ない（date 側のエラーで十分）" do
      cal = build(:company_calendar, date: nil)
      cal.valid?
      expect(cal.errors[:date]).to be_present
      expect(cal.errors[:fiscal_year]).to be_empty
    end
  end
end
