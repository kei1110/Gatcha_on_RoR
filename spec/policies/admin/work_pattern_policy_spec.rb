require "rails_helper"

RSpec.describe Admin::WorkPatternPolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let(:record) { create(:work_pattern) }

  context "hr_admin" do
    let(:actor) { create(:user, :hr_admin) }
    it { is_expected.to permit_actions(%i[index show new create edit update deactivate activate]) }
    it "destroy は不可（無効化のみ方針の固定）" do
      expect(subject.destroy?).to be(false)
    end
  end

  context "manager" do
    let(:actor) { create(:user, :manager_role) }
    it { is_expected.to forbid_actions(%i[index show new create edit update deactivate activate]) }
  end

  context "employee" do
    let(:actor) { create(:user) }
    it { is_expected.to forbid_actions(%i[index show new create edit update deactivate activate]) }
  end

  describe "Scope" do
    it "組織全件（inactive 含む）・他テナント漏れなし" do
      actor    = create(:user, :hr_admin)
      inactive = create(:work_pattern, active: false)
      ActsAsTenant.with_tenant(create(:organization)) { create(:work_pattern) }

      resolved = described_class::Scope.new(actor, WorkPattern.all).resolve
      expect(resolved).to contain_exactly(record, inactive)
    end

    it "without_tenant 文脈でも自組織のみ（organization_id 明示の fail-open 検出 — test_tenant 下では検知不能）" do
      actor = create(:user, :hr_admin)
      record # 生成
      ActsAsTenant.with_tenant(create(:organization)) { create(:work_pattern) }

      resolved = ActsAsTenant.without_tenant do
        described_class::Scope.new(actor, WorkPattern.all).resolve.to_a
      end
      expect(resolved).to contain_exactly(record)
    end
  end
end
