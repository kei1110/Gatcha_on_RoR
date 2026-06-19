# frozen_string_literal: true

require "rails_helper"

RSpec.describe HolidayWorkRequestPolicy do
  subject { described_class }

  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:user) { create(:user, organization: org) }
  let(:other) { create(:user, organization: org) }

  permissions :cancel? do
    it "本人かつ applying なら許可" do
      hwr = create(:holiday_work_request, organization: org, requester: user, approval_status: :applying)
      expect(subject).to permit(user, hwr)
    end

    it "applying でなければ拒否" do
      hwr = create(:holiday_work_request, organization: org, requester: user, approval_status: :approved)
      expect(subject).not_to permit(user, hwr)
    end

    it "他人は拒否" do
      hwr = create(:holiday_work_request, organization: org, requester: user, approval_status: :applying)
      expect(subject).not_to permit(other, hwr)
    end
  end

  describe "Scope" do
    it "本人の申請のみ返す" do
      mine = create(:holiday_work_request, organization: org, requester: user)
      create(:holiday_work_request, organization: org, requester: other)
      resolved = described_class::Scope.new(user, HolidayWorkRequest).resolve
      expect(resolved).to contain_exactly(mine)
    end
  end
end
