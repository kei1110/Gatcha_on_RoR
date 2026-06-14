# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::Start do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:dept) { create(:user, :manager_role, organization: org, manager: hr) }
  let(:boss) { create(:user, :manager_role, organization: org, manager: dept) }
  let(:emp)  { create(:user, organization: org, manager: boss) }

  it "ルート長に応じた pending assignment を position 順に生成する" do
    host = ApprovalTestRecord.create!(requester: emp)
    described_class.call(host)

    assignments = host.approval_assignments.order(:position)
    expect(assignments.map(&:position)).to eq([ 1, 2 ])
    expect(assignments.map(&:approver)).to eq([ boss, dept ])
    expect(assignments.map(&:decision)).to all(eq("pending"))
  end

  it "単段縮約時は 1 件だけ生成" do
    top = create(:user, :manager_role, organization: org)
    solo = create(:user, organization: org, manager: top)
    host = ApprovalTestRecord.create!(requester: solo)
    described_class.call(host)
    expect(host.approval_assignments.count).to eq(1)
  end

  it "冪等（再呼出で増えない）" do
    host = ApprovalTestRecord.create!(requester: emp)
    described_class.call(host)
    expect { described_class.call(host) }.not_to change { host.approval_assignments.count }
  end

  it "RouteError 時は呼び出し側 tx をロールバック（host 未永続）" do
    no_manager = create(:user, organization: org, manager: nil)
    expect {
      ActiveRecord::Base.transaction do
        host = ApprovalTestRecord.create!(requester: no_manager)
        described_class.call(host)
      end
    }.to raise_error(Approvals::RouteError)
    expect(ApprovalTestRecord.count).to eq(0)
  end
end
