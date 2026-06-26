# frozen_string_literal: true

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

  describe "#setting（0b-5 設計 §0 のアクセサ規約）" do
    let(:org) { create(:organization) }

    it "未生成なら既定値で生成する" do
      expect { org.setting }.to change {
        OrganizationSetting.unscoped.where(organization: org).count
      }.from(0).to(1)
      expect(org.setting.closing_day).to eq(31)
      expect(org.setting.submit_deadline_days).to eq(5)
    end

    it "生成済みなら同一行を返す（重複生成しない）" do
      first = org.setting
      expect { org.setting }.not_to change { OrganizationSetting.unscoped.count }
      expect(org.setting.id).to eq(first.id)
    end

    it "テナント文脈に依らず自組織へアンカーされる（mismatched with_tenant でも安全）" do
      other = create(:organization)
      created = ActsAsTenant.with_tenant(other) { org.setting }
      expect(created.organization_id).to eq(org.id)
    end

    it "lazy 生成後は has_one キャッシュも更新される（再呼び出しが再生成経路を踏まない）" do
      created = org.setting
      expect(org.organization_setting).to eq(created) # 修正前は nil（キャッシュ未更新）
    end
  end

  describe "#fiscal_year_range" do
    it "fiscal_year_for の逆（3 月決算: '2026' → 2026-04-01..2027-03-31）" do
      org = build(:organization, fiscal_year_end_month: 3)
      expect(org.fiscal_year_range("2026")).to eq(Date.new(2026, 4, 1)..Date.new(2027, 3, 31))
    end

    it "12 月決算は暦年に一致（'2026' → 2026-01-01..2026-12-31）" do
      org = build(:organization, fiscal_year_end_month: 12)
      expect(org.fiscal_year_range("2026")).to eq(Date.new(2026, 1, 1)..Date.new(2026, 12, 31))
    end

    it "範囲の先頭・末尾の境界日が fiscal_year_for で同じ年度へ戻る（往復一致）" do
      org = build(:organization, fiscal_year_end_month: 3)
      range = org.fiscal_year_range("2026")
      expect([ range.first, range.last ].map { |d| org.fiscal_year_for(d) }).to all(eq("2026"))
    end

    it "12 月決算でも境界日が往復一致する" do
      org = build(:organization, fiscal_year_end_month: 12)
      range = org.fiscal_year_range("2026")
      expect([ range.first, range.last ].map { |d| org.fiscal_year_for(d) }).to all(eq("2026"))
    end
  end

  describe "fiscal_year_end_month 変更ガード（残高あり）" do
    let(:org) { create(:organization, fiscal_year_end_month: 3) }

    it "残高が存在すると変更を拒否" do
      ActsAsTenant.with_tenant(org) { create(:leave_balance) }
      org.fiscal_year_end_month = 12
      expect(org).to be_invalid
      expect(org.errors[:fiscal_year_end_month]).to be_present
    end

    it "残高がなければ変更可" do
      org.fiscal_year_end_month = 12
      expect(org).to be_valid
    end

    it "他属性の変更は残高ありでも通る（過剰ブロック回避）" do
      ActsAsTenant.with_tenant(org) { create(:leave_balance) }
      org.name = "新社名"
      expect(org).to be_valid
    end

    it "他テナントの残高は当組織をロックしない" do
      ActsAsTenant.with_tenant(create(:organization)) { create(:leave_balance) }
      org.fiscal_year_end_month = 12
      expect(org).to be_valid
    end
  end

  describe ".active スコープ（§9⑩・ディスパッチャ用）" do
    it "active=true のみ返す" do
      active = create(:organization)
      inactive = create(:organization, active: false)
      expect(Organization.active).to include(active)
      expect(Organization.active).not_to include(inactive)
    end
  end

  describe "#today（0b-4 設計 §0 の TZ 契約）" do
    it "組織 TZ の当日を返す（アプリ TZ = UTC と日付が割れる時刻帯）" do
      org = build(:organization, time_zone: "Asia/Tokyo")
      travel_to Time.utc(2026, 6, 11, 20, 0) do # JST 2026-06-12 05:00
        expect(Date.current).to eq(Date.new(2026, 6, 11)) # 前提の固定: アプリ TZ では前日
        expect(org.today).to eq(Date.new(2026, 6, 12))
      end
    end

    it "UTC 組織なら Date.current と一致する" do
      org = build(:organization, time_zone: "UTC")
      travel_to Time.utc(2026, 6, 11, 20, 0) do
        expect(org.today).to eq(Date.new(2026, 6, 11))
      end
    end
  end
end
