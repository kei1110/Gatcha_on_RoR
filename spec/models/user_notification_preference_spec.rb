# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserNotificationPreference do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def in_savepoint = ActiveRecord::Base.transaction(requires_new: true) { yield }

  describe "1 ユーザー 1 行（テナント内一意）" do
    it "同一 user の 2 行目はモデル検証で無効" do
      first = create(:user_notification_preference)
      dup = build(:user_notification_preference, user: first.user)
      expect(dup).to be_invalid
    end

    it "別テナントなら同一 user_id でも valid（鏡像）" do
      create(:user_notification_preference)
      other = create(:organization)
      ActsAsTenant.with_tenant(other) do
        u = create(:user, organization: other)
        mirror = build(:user_notification_preference, organization: other, user: u)
        expect(mirror).to be_valid
      end
    end

    it "DB 最終防衛: validate:false でも複合 unique を弾く" do
      first = create(:user_notification_preference)
      expect {
        in_savepoint do
          build(:user_notification_preference, user: first.user).save!(validate: false)
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "時刻範囲（0..23）" do
    it "範囲外は無効" do
      pref = build(:user_notification_preference, quiet_hours_start: 24)
      expect(pref).to be_invalid
    end
  end

  describe "同一組織検証（§3.6）" do
    it "他テナントの user は DB 複合 FK で拒否（validate:false）" do
      other = create(:organization)
      foreign_user = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
      expect {
        in_savepoint do
          pref = build(:user_notification_preference)
          pref.user_id = foreign_user.id # org は自テナントのまま user_id だけ越境
          pref.save!(validate: false)
        end
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "他テナントの user はモデル検証でも無効（fail-closed）" do
      other = create(:organization)
      foreign_user = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
      pref = build(:user_notification_preference)
      pref.user_id = foreign_user.id
      expect(pref).to be_invalid
    end
  end
end
