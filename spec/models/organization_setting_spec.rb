require "rails_helper"

RSpec.describe OrganizationSetting, type: :model do
  let(:setting) { ActsAsTenant.test_tenant.setting }

  describe "範囲検証" do
    it "closing_day は 1..31（境界）" do
      [ 0, 32 ].each do |v|
        setting.closing_day = v
        expect(setting).not_to be_valid
      end
      [ 1, 31 ].each do |v|
        setting.closing_day = v
        expect(setting).to be_valid
      end
    end

    it "submit_deadline_days は 1..28（境界 — 28 = 2 月の最短月長）" do
      [ 0, 29 ].each do |v|
        setting.submit_deadline_days = v
        expect(setting).not_to be_valid
      end
      [ 1, 28 ].each do |v|
        setting.submit_deadline_days = v
        expect(setting).to be_valid
      end
    end
  end

  describe "1 行制約" do
    it "同一組織の 2 行目はフォームエラー（DB 例外前に検証で止まる）" do
      setting # 1 行目を生成
      dup = OrganizationSetting.new
      expect(dup).not_to be_valid
      expect(dup.errors[:organization_id]).to be_present
    end

    it "バリデーション skip の 2 行目 INSERT は RecordNotUnique（DB 最終防衛）" do
      setting
      dup = OrganizationSetting.new
      expect { dup.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
