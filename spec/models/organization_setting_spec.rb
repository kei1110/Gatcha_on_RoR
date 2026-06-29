# frozen_string_literal: true

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

  describe "通知列の lazy 既定（§4.15）" do
    it "Organization#setting が抑制/opt-in の既定値を返す" do
      expect(setting.quiet_hours_enabled).to be(true)
      expect(setting.quiet_hours_start).to eq(19)
      expect(setting.quiet_hours_end).to eq(8)
      expect(setting.holiday_block_enabled).to be(true)
      expect(setting.email_notification_enabled).to be(false)
    end
  end

  describe "quiet hours の時刻範囲検証（0..23）" do
    it "0..23 の外は無効" do
      setting.quiet_hours_start = 24
      expect(setting).not_to be_valid
      setting.quiet_hours_start = -1
      expect(setting).not_to be_valid
    end

    it "0 と 23 は有効" do
      setting.quiet_hours_start = 0
      setting.quiet_hours_end = 23
      expect(setting).to be_valid
    end
  end

  describe "rest_interval_hours（4-2・§10⑩）" do
    let(:org) { create(:organization) }

    it "既定は 11" do
      ActsAsTenant.with_tenant(org) { expect(org.setting.rest_interval_hours).to eq(11) }
    end

    it "1..24 の範囲外は無効（0 はインターバル無効化ゆえ禁止）" do
      ActsAsTenant.with_tenant(org) do
        s = org.setting
        s.rest_interval_hours = 0
        expect(s).to be_invalid
        s.rest_interval_hours = 25
        expect(s).to be_invalid
        s.rest_interval_hours = 11
        expect(s).to be_valid
      end
    end
  end
end
