# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClockChangeRequests::Withdraw do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org) }
  let(:work_date) { Date.new(2026, 6, 1) }
  let(:orig_in)  { Time.utc(2026, 6, 1, 0) }   # 09:00 JST
  let(:orig_out) { Time.utc(2026, 6, 1, 9) }   # 18:00 JST
  let(:new_out)  { Time.utc(2026, 6, 1, 10) }  # 19:00 JST（承認で適用済の現値）

  # 承認適用後の状態を再現: AR は new_out、CCR は original_out/new_out を保持し withdrawal_requested
  let(:record) { create(:attendance_record, :done, user:, work_date:, clock_in: orig_in, clock_out: new_out) }
  let(:ccr) do
    create(:clock_change_request, requester: user, attendance_record: record, change_type: :clock_out,
           original_clock_in: orig_in, original_clock_out: orig_out, new_clock_out: new_out,
           approval_status: :withdrawal_requested, withdrawal_reason: "誤申請")
  end
  def withdraw = described_class.call(clock_change_request: ccr, acting_user: approver)

  it "original_clock_out へ復元する" do
    withdraw
    expect(record.reload.clock_out).to eq(orig_out)
  end

  it "現値が new_* と一致しなければ ConflictError（別変更が割り込み）" do
    record.update!(clock_out: Time.utc(2026, 6, 1, 11))
    expect { withdraw }.to raise_error(Approvals::ConflictError)
  end

  it "clock_change_withdrawn 履歴を前後値つきで 1 行記録" do
    expect { withdraw }.to change { AttendanceHistory.where(event_type: :clock_change_withdrawn).count }.by(1)
    h = AttendanceHistory.find_by(event_type: :clock_change_withdrawn)
    expect(h.previous_clock_out).to eq(new_out)
    expect(h.new_clock_out).to eq(orig_out)
  end
end
