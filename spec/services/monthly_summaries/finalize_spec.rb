# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::Finalize, type: :model do
  let(:summary) { create(:monthly_attendance_summary, status: :submitted) }

  it "submitted を finalized にする" do
    described_class.call(summary:)
    expect(summary.reload).to be_finalized
  end

  it "submitted 以外は InvalidTransition" do
    summary.update!(status: :aggregating)
    expect { described_class.call(summary:) }.to raise_error(AASM::InvalidTransition)
  end

  it "D7: Aggregate を呼ばない（確定値が確定後に動かない）" do
    expect(MonthlySummaries::Aggregate).not_to receive(:call)
    described_class.call(summary:)
  end
end
