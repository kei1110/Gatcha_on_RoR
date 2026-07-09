# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbsenceCandidatePolicy do
  let(:org) { create(:organization) }
  let(:other_org) { create(:organization, subdomain: "other") }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)       { create(:user, :hr_admin) }
  let(:manager)  { create(:user, :manager_role, manager: hr) }
  let(:sub)      { create(:user, manager: manager) }
  let(:stranger) { create(:user, manager: hr) }
  let(:employee) { create(:user) }

  let!(:sub_candidate)      { create(:absence_candidate, user: sub, target_date: Date.new(2026, 5, 1)) }
  let!(:stranger_candidate) { create(:absence_candidate, user: stranger, target_date: Date.new(2026, 5, 1)) }

  describe "#destroy?（却下 dismiss の role ゲート）" do
    it "manager / hr_admin は却下可・一般社員は不可" do
      expect(described_class.new(manager, sub_candidate).destroy?).to be(true)
      expect(described_class.new(hr, sub_candidate).destroy?).to be(true)
      expect(described_class.new(employee, sub_candidate).destroy?).to be(false)
    end
  end

  describe "Scope" do
    def resolve(actor) = described_class::Scope.new(actor, AbsenceCandidate).resolve

    it "manager は直属部下の候補のみ（同一テナント別部下は見えない＝IDOR 封鎖）" do
      expect(resolve(manager)).to include(sub_candidate)
      expect(resolve(manager)).not_to include(stranger_candidate)
    end

    it "hr_admin は組織全体の候補" do
      expect(resolve(hr)).to include(sub_candidate, stranger_candidate)
    end

    it "他テナントの候補は hr_admin にも見えない" do
      outsider_candidate = ActsAsTenant.with_tenant(other_org) do
        create(:absence_candidate, user: create(:user, organization: other_org),
                                   organization: other_org, target_date: Date.new(2026, 5, 1))
      end
      expect(resolve(hr)).not_to include(outsider_candidate)
    end

    it "一般社員は空（自分の候補も見えない）" do
      create(:absence_candidate, user: employee, target_date: Date.new(2026, 5, 1))
      expect(resolve(employee)).to be_empty
    end
  end
end
