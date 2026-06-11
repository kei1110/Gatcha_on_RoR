require "rails_helper"

RSpec.describe Organization, type: :model do
  it "is valid with name and subdomain" do
    expect(build(:organization)).to be_valid
  end

  it "requires globally unique subdomain" do
    create(:organization, subdomain: "acme")
    expect(build(:organization, subdomain: "acme")).not_to be_valid
  end

  it "rejects invalid subdomain format" do
    expect(build(:organization, subdomain: "Bad_Sub!")).not_to be_valid
  end

  it "enforces subdomain uniqueness at DB level" do
    create(:organization, subdomain: "acme")
    dup = build(:organization, subdomain: "acme")
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  describe "#fiscal_year_for（年度導出 — 0b-3 設計 §2）" do
    it "3 月決算（既定）: 年度は 4 月開始（3/31 と 4/1 が境界）" do
      org = create(:organization) # migration 後の DB 既定 3
      expect(org.fiscal_year_for(Date.new(2026, 3, 31))).to eq("2025")
      expect(org.fiscal_year_for(Date.new(2026, 4, 1))).to eq("2026")
      expect(org.fiscal_year_for(Date.new(2027, 1, 15))).to eq("2026")
    end

    it "12 月決算: 年度 = 暦年（start_month 計算の % 12 境界）" do
      org = create(:organization, fiscal_year_end_month: 12)
      expect(org.fiscal_year_for(Date.new(2026, 1, 1))).to eq("2026")
      expect(org.fiscal_year_for(Date.new(2026, 12, 31))).to eq("2026")
    end

    it "1 月決算: 2 月開始" do
      org = create(:organization, fiscal_year_end_month: 1)
      expect(org.fiscal_year_for(Date.new(2026, 1, 31))).to eq("2025")
      expect(org.fiscal_year_for(Date.new(2026, 2, 1))).to eq("2026")
    end

    it "6 月決算: 7 月開始（中間月の代表）" do
      org = create(:organization, fiscal_year_end_month: 6)
      expect(org.fiscal_year_for(Date.new(2026, 6, 30))).to eq("2025")
      expect(org.fiscal_year_for(Date.new(2026, 7, 1))).to eq("2026")
    end

    it "fiscal_year_end_month の範囲外（0 / 13）は invalid（% 12 のサイレント誤算出を遮断）" do
      expect(build(:organization, fiscal_year_end_month: 0)).not_to be_valid
      expect(build(:organization, fiscal_year_end_month: 13)).not_to be_valid
    end
  end
end
