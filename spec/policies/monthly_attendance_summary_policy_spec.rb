# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlyAttendanceSummaryPolicy, type: :policy do
  let(:org) { create(:organization) }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  subject { described_class.new(user, summary) }

  let(:owner) { create(:user, organization: org) }
  let(:summary) { create(:monthly_attendance_summary, user: owner, organization: org) }

  context "本人" do
    let(:user) { owner }

    it { is_expected.to permit_actions(%i[index show submit]) }
    it { is_expected.to forbid_actions(%i[finalize defer]) }
  end

  context "直属 manager" do
    let(:user) { create(:user, :manager_role, organization: org) }

    before { owner.update!(manager: user) }

    it { is_expected.to permit_actions(%i[index show finalize defer]) }
    it { is_expected.to forbid_actions(%i[submit]) }
  end

  context "無関係な manager（別部下の上長）" do
    let(:user) { create(:user, :manager_role, organization: org) }

    it { is_expected.to forbid_actions(%i[show finalize defer]) }
  end

  context "hr_admin" do
    let(:user) { create(:user, :hr_admin, organization: org) }

    it { is_expected.to permit_actions(%i[index show finalize defer]) }
  end

  describe "Scope" do
    it "自分 + 直属部下の summary のみ返す" do
      manager = create(:user, :manager_role, organization: org)
      sub = create(:user, organization: org, manager: manager)
      other = create(:user, organization: org)
      own = create(:monthly_attendance_summary, user: manager, organization: org)
      sub_s = create(:monthly_attendance_summary, user: sub, organization: org)
      create(:monthly_attendance_summary, user: other, organization: org)

      resolved = described_class::Scope.new(manager, MonthlyAttendanceSummary).resolve
      expect(resolved).to contain_exactly(own, sub_s)
    end

    it "hr_admin は組織全件" do
      admin = create(:user, :hr_admin, organization: org)
      s1 = create(:monthly_attendance_summary, organization: org)
      s2 = create(:monthly_attendance_summary, organization: org)

      resolved = described_class::Scope.new(admin, MonthlyAttendanceSummary).resolve
      expect(resolved).to include(s1, s2)
    end
  end
end
