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
end
