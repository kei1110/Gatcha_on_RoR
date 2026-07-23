# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbsenceCancellationPolicy do
  let(:org) { create(:organization) }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)       { create(:user, :hr_admin) }
  let(:manager)  { create(:user, :manager_role, manager: hr) }
  let(:sub)      { create(:user, manager: manager) }
  let(:employee) { create(:user) }

  describe "#create?" do
    it "manager / hr_admin は許可・一般社員は拒否" do
      expect(described_class.new(manager, :absence_cancellation).create?).to be(true)
      expect(described_class.new(hr, :absence_cancellation).create?).to be(true)
      expect(described_class.new(employee, :absence_cancellation).create?).to be(false)
    end
  end

  describe "Scope" do
    it "hr_admin は組織全体を解決する（無効化済みも含む）" do
      inactive = create(:user, manager: manager)
      inactive.update!(active: false)
      resolved = AbsenceCancellationPolicy::Scope.new(hr, User).resolve
      expect(resolved).to include(sub, inactive)
    end

    it "manager は直属部下のみ（無効化済み部下も含む）" do
      inactive_sub = create(:user, manager: manager)
      inactive_sub.update!(active: false)
      resolved = AbsenceCancellationPolicy::Scope.new(manager, User).resolve
      expect(resolved).to include(sub, inactive_sub)
      expect(resolved).not_to include(employee) # 別 manager 配下
    end

    it "一般社員は誰も解決しない" do
      expect(AbsenceCancellationPolicy::Scope.new(employee, User).resolve).to be_empty
    end
  end
end
