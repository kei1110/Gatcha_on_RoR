# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::RequestWithdrawal do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:boss) { create(:user, :manager_role, manager: hr, organization: org) }
  let(:requester) { create(:user, manager: boss, organization: org) }
  let(:host) { WithdrawalTestRecord.create!(requester:, approval_status: :approved) }

  it "approved を withdrawal_requested にし撤回世代を生成" do
    described_class.call(approvable: host, requester:, reason: "誤申請のため")
    expect(host.reload).to be_withdrawal_requested
    expect(host.withdrawal_reason).to eq("誤申請のため")
    expect(host.approval_assignments.where(purpose: :withdrawal)).to be_present
  end

  it "reason が空なら ArgumentError（二層の片側）" do
    expect { described_class.call(approvable: host, requester:, reason: " ") }
      .to raise_error(ArgumentError)
    expect(host.reload).to be_approved
  end

  it "申請者本人でなければ NotRequester" do
    other = create(:user, organization: org)
    expect { described_class.call(approvable: host, requester: other, reason: "x") }
      .to raise_error(Approvals::NotRequester)
  end

  it "撤回世代が既にあれば InvalidTransition（再撤回不可・D6）" do
    host.approval_assignments.create!(organization: org, approver: boss, position: 1, purpose: :withdrawal, decision: :rejected, acted_at: Time.current)
    expect { described_class.call(approvable: host, requester:, reason: "x") }
      .to raise_error(AASM::InvalidTransition)
  end
end
