# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notification do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def in_savepoint = ActiveRecord::Base.transaction(requires_new: true) { yield }

  describe "enum" do
    it "priority / source_type を取りうる" do
      n = build(:notification, priority: :action_required, source_type: :request_rejected)
      expect(n).to be_valid
      expect(n.action_required?).to be(true)
      expect(n.request_rejected?).to be(true)
    end
  end

  describe "scope :unread" do
    it "read_at nil のみ返す" do
      unread = create(:notification, read_at: nil)
      create(:notification, read_at: Time.current)
      expect(described_class.unread).to contain_exactly(unread)
    end
  end

  describe "subject_user は任意（null 可）" do
    it "subject_user なしで valid" do
      expect(build(:notification, subject_user: nil)).to be_valid
    end
  end

  describe "同一組織検証（§3.6・§9④）" do
    it "他テナントの target_user は DB 複合 FK で拒否（validate:false）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
      expect {
        in_savepoint do
          n = build(:notification)
          n.target_user_id = foreign.id
          n.save!(validate: false)
        end
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "他テナントの target_user はモデル検証でも無効（fail-closed）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
      n = build(:notification)
      n.target_user_id = foreign.id
      expect(n).to be_invalid
    end

    it "他テナントの subject_user はモデル検証で無効" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
      n = build(:notification)
      n.subject_user_id = foreign.id
      expect(n).to be_invalid
    end
  end

  describe "同一組織強制（§3.6・二層防御）" do
    let(:org)   { create(:organization) }
    let(:other) { create(:organization) }
    let(:other_user) { ActsAsTenant.with_tenant(other) { create(:user) } }

    it "必須 target_user の他組織 id は DB 複合 FK で拒否（model 層を貫通）" do
      ActsAsTenant.with_tenant(org) do
        n = build(:notification, target_user: nil)
        n.target_user_id = other_user.id # 他組織 id を直挿（acts_as_tenant の nil ロードを迂回）
        expect { n.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
      end
    end

    it "optional subject_user の他組織 id は model validator が判別的に弾く" do
      ActsAsTenant.with_tenant(org) do
        n = build(:notification, subject_user_id: other_user.id)
        expect(n).to be_invalid
        expect(n.errors[:subject_user]).to be_present
      end
    end
  end
end
