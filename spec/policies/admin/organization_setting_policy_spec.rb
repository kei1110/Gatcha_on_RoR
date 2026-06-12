require "rails_helper"

RSpec.describe Admin::OrganizationSettingPolicy, type: :policy do
  subject { described_class.new(actor, setting) }

  let(:setting) { ActsAsTenant.test_tenant.setting }

  context "hr_admin" do
    let(:actor) { create(:user, :hr_admin) }
    it { is_expected.to permit_actions(%i[edit update]) }
    it "index?/show?/destroy? は既定 deny のまま（singleton — 開けない）" do
      expect(subject.index?).to be(false)
      expect(subject.show?).to be(false)
      expect(subject.destroy?).to be(false)
    end
  end

  context "manager" do
    let(:actor) { create(:user, :manager_role) }
    it { is_expected.to forbid_actions(%i[edit update]) }
  end

  context "employee" do
    let(:actor) { create(:user) }
    it { is_expected.to forbid_actions(%i[edit update]) }
  end
end
