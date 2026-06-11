require "rails_helper"

RSpec.describe Admin::CompanyCalendarPolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let(:record) { create(:company_calendar) }

  context "hr_admin" do
    let(:actor) { create(:user, :hr_admin) }
    # destroy/import/generate は基底 MasterPolicy に無い異型 3 アクション（0b-3 設計 §4）
    it { is_expected.to permit_actions(%i[index new create edit update destroy import generate]) }
  end

  context "manager" do
    let(:actor) { create(:user, :manager_role) }
    it { is_expected.to forbid_actions(%i[index new create edit update destroy import generate]) }
  end

  context "employee" do
    let(:actor) { create(:user) }
    it { is_expected.to forbid_actions(%i[index new create edit update destroy import generate]) }
  end

  describe "Scope" do
    it "組織全件・他テナント漏れなし" do
      actor = create(:user, :hr_admin)
      ActsAsTenant.with_tenant(create(:organization)) { create(:company_calendar) }

      resolved = described_class::Scope.new(actor, CompanyCalendar.all).resolve
      expect(resolved).to contain_exactly(record)
    end

    it "without_tenant 文脈でも自組織のみ（organization_id 明示の fail-open 検出 — test_tenant 下では検知不能）" do
      actor = create(:user, :hr_admin)
      record # 生成
      ActsAsTenant.with_tenant(create(:organization)) { create(:company_calendar) }

      resolved = ActsAsTenant.without_tenant do
        described_class::Scope.new(actor, CompanyCalendar.all).resolve.to_a
      end
      expect(resolved).to contain_exactly(record)
    end
  end
end
