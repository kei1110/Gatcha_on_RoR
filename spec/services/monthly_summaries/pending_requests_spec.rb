# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::PendingRequests, type: :model do
  let(:user) { create(:user) }
  let(:period) { AttendancePeriod.new(organization: user.organization, year_month: "2026-05") }

  def in_period_lr(status: :applying)
    create(:leave_request, requester: user, start_date: Date.new(2026, 5, 10),
           end_date: Date.new(2026, 5, 10), days_requested: 1).tap { |lr| lr.update!(approval_status: status) }
  end

  describe "#any?" do
    it "in-flight 申請が無ければ false" do
      expect(described_class.new(user:, period:).any?).to be(false)
    end

    it "applying の LR が期間内にあれば true" do
      in_period_lr
      expect(described_class.new(user:, period:).any?).to be(true)
    end

    it "approved/canceled/withdrawn は in-flight でない（誤検出しない）" do
      in_period_lr(status: :approved)
      expect(described_class.new(user:, period:).any?).to be(false)
    end

    it "期間外の applying は拾わない" do
      create(:leave_request, requester: user, start_date: Date.new(2026, 7, 1),
             end_date: Date.new(2026, 7, 1), days_requested: 1)
      expect(described_class.new(user:, period:).any?).to be(false)
    end
  end

  describe "#started / #not_started" do
    it "acted assignment があれば started" do
      lr = in_period_lr
      # 承認進行中 = active purpose に pending でない assignment が 1 件以上
      create(:approval_assignment, approvable: lr, position: 1, decision: :approved, approver: create(:user))
      pr = described_class.new(user:, period:)
      expect(pr.started).to include(lr)
      expect(pr.not_started).not_to include(lr)
    end

    it "全 assignment が pending なら not_started" do
      lr = in_period_lr
      create(:approval_assignment, approvable: lr, position: 1, decision: :pending, approver: create(:user))
      pr = described_class.new(user:, period:)
      expect(pr.not_started).to include(lr)
      expect(pr.started).not_to include(lr)
    end
  end
end
