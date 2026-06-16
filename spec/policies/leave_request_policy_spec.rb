# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequestPolicy do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:owner) { create(:user, organization: org) }
  let(:other) { create(:user, organization: org) }
  let(:request) { create(:leave_request, requester: owner) }

  permissions :index?, :new?, :create?, :preview? do
    it { expect(described_class).to permit(owner, LeaveRequest) }
  end

  permissions :cancel? do
    it "本人 applying は許可" do
      expect(described_class).to permit(owner, request)
    end

    it "第三者は不許可" do
      expect(described_class).not_to permit(other, request)
    end

    it "terminal（canceled）は不許可" do
      request.cancel!
      expect(described_class).not_to permit(owner, request.reload)
    end
  end

  describe "Scope" do
    it "自分の申請のみ返す" do
      mine = request
      ActsAsTenant.with_tenant(org) { create(:leave_request, requester: other) }
      scope = LeaveRequestPolicy::Scope.new(owner, LeaveRequest).resolve
      expect(scope).to contain_exactly(mine)
    end
  end
end
