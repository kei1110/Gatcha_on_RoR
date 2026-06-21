# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::Submit, type: :model do
  let(:user) { create(:user) }
  let(:period) { AttendancePeriod.new(organization: user.organization, year_month: "2026-05") }

  it "summary 行が無くても初回提出で lazy 生成し submitted にする" do
    summary = described_class.call(user:, period:)
    expect(summary).to be_persisted
    expect(summary).to be_submitted
    expect(summary.year_month).to eq("2026-05")
  end

  it "deferred からの再提出も submitted にする" do
    create(:monthly_attendance_summary, user:, year_month: "2026-05", status: :deferred, deferral_reason: "x")
    summary = described_class.call(user:, period:)
    expect(summary).to be_submitted
  end

  it "in-flight 申請があれば ConflictError（fail-closed）" do
    create(:leave_request, requester: user, start_date: Date.new(2026, 5, 10),
           end_date: Date.new(2026, 5, 10), days_requested: 1) # applying
    expect { described_class.call(user:, period:) }.to raise_error(Approvals::ConflictError)
  end

  it "in-flight 検出時は Aggregate を呼ばない（再集計前に fail-closed）" do
    create(:leave_request, requester: user, start_date: Date.new(2026, 5, 10),
           end_date: Date.new(2026, 5, 10), days_requested: 1)
    expect(MonthlySummaries::Aggregate).not_to receive(:call)
    expect { described_class.call(user:, period:) }.to raise_error(Approvals::ConflictError)
  end

  it "Aggregate を 1 回呼び、その返り値に submit! する（順序・同一インスタンス）" do
    summary = create(:monthly_attendance_summary, user:, year_month: "2026-05")
    expect(MonthlySummaries::Aggregate).to receive(:call).with(user:, period:).once.and_return(summary)
    result = described_class.call(user:, period:)
    expect(result).to eq(summary)
    expect(result).to be_submitted
  end
end
