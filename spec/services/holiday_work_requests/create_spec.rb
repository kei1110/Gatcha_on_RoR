# frozen_string_literal: true

require "rails_helper"

RSpec.describe HolidayWorkRequests::Create do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:manager) { create(:user, :manager_role, organization: org) }
  let(:requester) { create(:user, organization: org, manager:) }
  let(:comp) { create(:leave_type, system_type: :compensatory_leave, organization: org) }

  def call(**attrs)
    described_class.call(requester:, work_date: Date.new(2026, 6, 7),
                         compensation_leave_type: comp, reason: "休日対応", **attrs)
  end

  it "HWR を作成し承認エンジンを起動する" do
    hwr = call
    expect(hwr).to be_persisted
    expect(hwr.approval_assignments).to be_present
  end

  it "manager 未設定なら RouteError で HWR を残さない（atomic）" do
    requester.update!(manager: nil)
    expect { call }.to raise_error(Approvals::RouteError)
    expect(HolidayWorkRequest.count).to eq(0)
    expect(ApprovalAssignment.count).to eq(0)
  end
end
