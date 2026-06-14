# frozen_string_literal: true

require "rails_helper"

RSpec.describe ProxyClockingPolicy do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  describe "アクション可否" do
    it "manager / hr_admin は可、employee は不可" do
      expect(described_class.new(create(:user, :manager_role, organization: org), :proxy_clocking).clock_in?).to be true
      expect(described_class.new(create(:user, :hr_admin, organization: org), :proxy_clocking).clock_in?).to be true
      expect(described_class.new(create(:user, organization: org), :proxy_clocking).clock_in?).to be false
    end
  end

  describe "Scope" do
    let(:manager) { create(:user, :manager_role, organization: org) }
    let!(:sub)    { create(:user, organization: org, manager: manager) }
    let!(:other)  { create(:user, organization: org) }                 # 非部下
    let!(:inactive_sub) { create(:user, organization: org, manager: manager, active: false) }

    it "manager は直接部下のみ（自分・非部下・inactive 除外）" do
      resolved = ProxyClockingPolicy::Scope.new(manager, User).resolve
      expect(resolved).to contain_exactly(sub)
    end

    it "hr_admin は組織全員（自分除外・active のみ）" do
      admin = create(:user, :hr_admin, organization: org)
      resolved = ProxyClockingPolicy::Scope.new(admin, User).resolve
      expect(resolved).to include(sub, other, manager)
      expect(resolved).not_to include(admin)          # 自分除外
      expect(resolved).not_to include(inactive_sub)   # inactive 除外
    end

    it "employee は空（fail-closed）" do
      expect(ProxyClockingPolicy::Scope.new(other, User).resolve).to be_empty
    end
  end
end
