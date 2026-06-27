# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationDelivery do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def in_savepoint = ActiveRecord::Base.transaction(requires_new: true) { yield }

  describe "enum と既定" do
    it "channel / status を取り、既定は pending / retry_count 0" do
      d = create(:notification_delivery)
      expect(d.email?).to be(true)
      expect(d.pending?).to be(true)
      expect(d.retry_count).to eq(0)
    end
  end

  describe "同一組織検証（§3.6・§9④）" do
    it "他テナントの notification は DB 複合 FK で拒否（validate:false）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:notification, organization: other, target_user: create(:user, organization: other))
      end
      expect {
        in_savepoint do
          d = build(:notification_delivery)
          d.notification_id = foreign.id
          d.save!(validate: false)
        end
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "他テナントの notification はモデル検証でも無効（fail-closed）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:notification, organization: other, target_user: create(:user, organization: other))
      end
      d = build(:notification_delivery)
      d.notification_id = foreign.id
      expect(d).to be_invalid
    end
  end

  describe "同一組織強制（§3.6・二層防御）" do
    let(:org)   { create(:organization) }
    let(:other) { create(:organization) }
    let(:other_notification) do
      ActsAsTenant.with_tenant(other) { create(:notification) }
    end

    it "必須 notification の他組織 id は DB 複合 FK で拒否" do
      ActsAsTenant.with_tenant(org) do
        d = build(:notification_delivery, notification: nil)
        d.notification_id = other_notification.id
        expect { d.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
      end
    end
  end
end
