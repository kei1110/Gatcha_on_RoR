# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::Cancel do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:requester) { create(:user, organization: org) }
  let(:request) { create(:leave_request, requester:) }

  it "applying を canceled へ遷移（by=requester）" do
    described_class.call(approvable: request, by: requester)
    expect(request.reload.approval_status).to eq("canceled")
  end

  it "by != requester は SelfApprovalError（service 層の二層目）" do
    other = create(:user, organization: org)
    expect { described_class.call(approvable: request, by: other) }
      .to raise_error(Approvals::SelfApprovalError)
    expect(request.reload.approval_status).to eq("applying")
  end

  it "canceled の再 cancel は InvalidTransition（terminal）" do
    described_class.call(approvable: request, by: requester)
    expect { described_class.call(approvable: request.reload, by: requester) }
      .to raise_error(AASM::InvalidTransition)
  end
end
