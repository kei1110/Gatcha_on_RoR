require "rails_helper"

RSpec.describe Clockings::ProxyClockIn do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:operator) { create(:user, :manager_role, organization: org) }
  let(:target)   { create(:user, organization: org, manager: operator) }

  def call(reason: "system_failure", op: operator, tg: target)
    described_class.call(operator: op, target_user: tg, reason:)
  end

  it "代理出勤を作成し履歴を残す" do
    expect { @result = call }.to change(AttendanceRecord, :count).by(1)
                            .and change(AttendanceHistory, :count).by(1)
    expect(@result).to be_success
    rec = @result.record
    expect(rec.user).to eq target
    expect(rec.status).to eq "working"
    expect(rec.proxy_clock_reason).to eq "system_failure"
    expect(rec.note).to include("代理打刻（出勤）", operator.name)

    hist = AttendanceHistory.last
    expect(hist.event_type).to eq "proxy_clock"
    expect(hist.actor).to eq operator
    expect(hist.user).to eq target
    expect(hist.source).to eq rec
    expect(hist.new_status).to eq AttendanceRecord.statuses["working"]
  end

  it "reason 欠落は reason_required で拒否（無理由代理打刻を塞ぐ）" do
    result = call(reason: nil)
    expect(result).not_to be_success
    expect(result.error).to eq :reason_required
    expect(AttendanceRecord.count).to eq 0
  end

  it "自己代理は self_proxy_forbidden（自分は通常打刻）" do
    result = call(tg: operator)
    expect(result.error).to eq :self_proxy_forbidden
  end

  it "別テナント対象は cross_tenant で fail-closed" do
    other = create(:organization)
    foreign = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
    result = call(tg: foreign)
    expect(result.error).to eq :cross_tenant
    expect(AttendanceHistory.count).to eq 0
  end

  it "同日出勤済みは already_clocked_in" do
    call
    expect(call.error).to eq :already_clocked_in
  end

  it "window 内に未退勤の working があれば still_working" do
    allow(org).to receive(:today).and_return(Date.new(2026, 6, 2))
    create(:attendance_record, organization: org, user: target,
           work_date: Date.new(2026, 6, 1), status: :working)
    expect(call.error).to eq :still_working
  end

  it "履歴 INSERT 失敗時は出勤レコードごとロールバック（証跡なき改変を作らない）" do
    allow(Clockings).to receive(:record_history).and_raise(
      ActiveRecord::RecordInvalid.new(AttendanceHistory.new))
    result = call
    expect(result.error).to eq :proxy_clock_failed
    expect(AttendanceRecord.count).to eq 0
  end
end
