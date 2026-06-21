# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::Defer, type: :model do
  let(:summary) { create(:monthly_attendance_summary, status: :submitted) }

  it "submitted を deferred にし reason を保存する" do
    described_class.call(summary:, reason: "打刻漏れあり")
    summary.reload
    expect(summary).to be_deferred
    expect(summary.deferral_reason).to eq("打刻漏れあり")
  end

  it "reason 空なら RecordInvalid（deferral_reason 必須）" do
    expect { described_class.call(summary:, reason: "") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "finalized からも deferred にできる" do
    summary.update!(status: :finalized)
    described_class.call(summary:, reason: "確定後修正")
    expect(summary.reload).to be_deferred
  end

  it "D7: Aggregate を呼ばない" do
    expect(MonthlySummaries::Aggregate).not_to receive(:call)
    described_class.call(summary:, reason: "x")
  end
end
