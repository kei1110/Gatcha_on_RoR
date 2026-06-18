# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::ApplyApproval do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org) }
  let(:paid_type) { create(:leave_type, system_type: :annual, paid_leave: true) }
  let(:unpaid_type) { create(:leave_type, system_type: :other, paid_leave: false) }

  # start_date の年度（決算月に依らず robust に算出）
  let(:start_date) { Date.new(2026, 5, 1) }   # 金曜（fallback weekday）
  let(:fiscal_year) { org.fiscal_year_for(start_date) }

  def leave(type:, sd: start_date, ed: start_date, half: :none, days: 1)
    create(:leave_request, requester: user, leave_type: type,
           start_date: sd, end_date: ed, half_day_type: half, days_requested: days)
  end

  def apply(lr) = described_class.call(leave_request: lr, acting_user: approver)

  describe "残高加算（paid・§4.10 ハード拒否）" do
    it "paid 種別は used_days に days_requested を加算" do
      balance = create(:leave_balance, user:, leave_type: paid_type,
                       fiscal_year:, granted_days: 20, used_days: 3)
      apply(leave(type: paid_type, days: 1))
      expect(balance.reload.used_days).to eq(BigDecimal("4"))
    end

    it "残高超過は OverBalanceError で拒否し used_days を変えない" do
      balance = create(:leave_balance, user:, leave_type: paid_type,
                       fiscal_year:, granted_days: 5, carry_over_days: 0, used_days: 5)
      expect { apply(leave(type: paid_type, days: 1)) }
        .to raise_error(Approvals::OverBalanceError)
      expect(balance.reload.used_days).to eq(BigDecimal("5"))
    end

    it "残高行が無い paid 種別は over-balance（available=0）" do
      expect { apply(leave(type: paid_type, days: 1)) }
        .to raise_error(Approvals::OverBalanceError)
    end

    it "非 paid 種別は残高を一切触らない（balance 行が無くても成功）" do
      expect { apply(leave(type: unpaid_type, days: 1)) }.not_to raise_error
    end

    it "over-balance では AR も history も作られない（残高→AR→history の順序契約を固定）" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, granted_days: 0, used_days: 0)
      expect { apply(leave(type: paid_type, days: 1)) }.to raise_error(Approvals::OverBalanceError)
      expect(AttendanceRecord.count).to eq(0)
      expect(AttendanceHistory.count).to eq(0)
    end
  end
end
