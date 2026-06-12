require "rails_helper"

RSpec.describe ReasonTemplate, type: :model do
  describe "検証" do
    it "label / template_text 必須" do
      record = build(:reason_template, label: nil, template_text: nil)
      expect(record).not_to be_valid
      expect(record.errors[:label]).to be_present
      expect(record.errors[:template_text]).to be_present
    end

    it "enum 毒値は ArgumentError でなくバリデーションエラー（validate: true）" do
      record = build(:reason_template)
      record.applies_to = "superuser"
      expect(record).not_to be_valid
      expect(record.errors[:applies_to]).to be_present
    end

    it "整数マッピングを固定（DB 値依存のリオーダー事故検知）" do
      expect(ReasonTemplate.applies_tos).to eq(
        "clock_change" => 0, "leave" => 1, "both" => 2)
    end

    it "label はテナント内 unique・他テナント同名は許可（鏡像）" do
      create(:reason_template, label: "電車遅延")
      expect(build(:reason_template, label: "電車遅延")).not_to be_valid

      ActsAsTenant.with_tenant(create(:organization)) do
        expect(build(:reason_template, label: "電車遅延")).to be_valid
      end
    end
  end

  describe "Deactivatable 契約（0b-5 設計 §0）" do
    it "name エイリアスが label を返す（concern の record.name が 500 にならない）" do
      record = build(:reason_template, label: "電車遅延")
      expect(record.name).to eq("電車遅延")
    end
  end
end
