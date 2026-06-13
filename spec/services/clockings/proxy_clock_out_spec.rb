require "rails_helper"

RSpec.describe Clockings::ProxyClockOut do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:operator) { create(:user, :manager_role, organization: org) }
  let(:target)   { create(:user, organization: org, manager: operator) }

  before { allow(org).to receive(:today).and_return(Date.new(2026, 6, 1)) }

  def open_shift
    create(:attendance_record, organization: org, user: target,
           work_date: Date.new(2026, 6, 1), status: :working)
  end

  def call(reason: "forgot_punch")
    described_class.call(operator: operator, target_user: target, reason:)
  end

  it "代理退勤し履歴を残す。再計算は commit 後" do
    open_shift
    expect { @result = call }.to change(AttendanceHistory, :count).by(1)
    expect(@result).to be_success
    rec = @result.record.reload
    expect(rec.status).to eq "clocked_out"
    expect(rec.clock_out).to be_present
    expect(rec.note).to include("代理打刻（退勤）")

    hist = AttendanceHistory.last
    expect(hist.previous_status).to eq AttendanceRecord.statuses["working"]
    expect(hist.new_status).to eq AttendanceRecord.statuses["clocked_out"]
  end

  it "window 内に working が無ければ not_working" do
    expect(call.error).to eq :not_working
  end

  it "reason 欠落は reason_required" do
    open_shift
    result = described_class.call(operator:, target_user: target, reason: "")
    expect(result.error).to eq :reason_required
  end

  it "履歴 INSERT 失敗時は退勤ごとロールバック（証跡なき改変を作らない）" do
    rec = open_shift
    allow(Clockings).to receive(:record_history).and_raise(ActiveRecord::RecordInvalid.new(AttendanceHistory.new))
    result = call
    expect(result.error).to eq :proxy_clock_failed
    expect(rec.reload.status).to eq "working"
    expect(rec.clock_out).to be_nil
  end
end
