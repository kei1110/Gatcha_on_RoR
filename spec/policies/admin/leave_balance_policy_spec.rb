# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::LeaveBalancePolicy do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr) { create(:user, :hr_admin, organization: org) }
  let(:employee) { create(:user, organization: org) }
  let(:balance) { create(:leave_balance) }

  permissions :create?, :update?, :new?, :edit? do
    it { expect(described_class).to permit(hr, balance) }
    it { expect(described_class).not_to permit(employee, balance) }
  end
end
