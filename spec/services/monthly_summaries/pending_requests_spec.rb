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

    it "applying の CCR が期間内（attendance_record.work_date が period 内）にあれば true" do
      ar = create(:attendance_record, :done, user:, work_date: Date.new(2026, 5, 15))
      create(:clock_change_request, requester: user, attendance_record: ar)
      expect(described_class.new(user:, period:).any?).to be(true)
    end

    it "applying の HWR が期間内（work_date が period 内）にあれば true" do
      create(:holiday_work_request, requester: user, work_date: Date.new(2026, 5, 3)) # 2026-05-03 は日曜
      expect(described_class.new(user:, period:).any?).to be(true)
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
