# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClockChangeRequests::Create do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:boss) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org, manager: boss) }   # route: [boss]（単段）
  let(:record) do
    create(:attendance_record, :done, user:, work_date: Date.new(2026, 6, 1),
           clock_in: Time.utc(2026, 6, 1, 1), clock_out: Time.utc(2026, 6, 1, 9))
  end

  def call
    described_class.call(requester: user, attendance_record: record, change_type: "clock_in",
                         new_clock_in: Time.utc(2026, 6, 1, 0), new_clock_out: nil, reason: "修正")
  end

  it "original_* を記録から snapshot する（サーバ権威）" do
    ccr = call
    expect(ccr.original_clock_in).to eq(record.clock_in)
    expect(ccr.original_clock_out).to eq(record.clock_out)
  end

  it "Approvals::Start を起動し pending assignment を生成する" do
    ccr = call
    expect(ccr.approval_assignments.where(decision: :pending)).to be_present
  end

  it "RouteError 時は CCR / assignment 双方とも作られない（manager 未設定）" do
    orphan = create(:user, organization: org)   # manager 無し
    orphan_record = create(:attendance_record, :done, user: orphan, work_date: Date.new(2026, 6, 2))
    expect {
      described_class.call(requester: orphan, attendance_record: orphan_record, change_type: "clock_in",
                           new_clock_in: Time.utc(2026, 6, 2, 0), new_clock_out: nil, reason: "x")
    }.to raise_error(Approvals::RouteError)
    expect(ClockChangeRequest.count).to eq(0)
  end
end
