# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::Withdraw do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org) }
  let(:paid_type) { create(:leave_type, system_type: :annual, paid_leave: true, allow_half_day: true) }
  let(:comp_type) { create(:leave_type, system_type: :compensatory_leave, paid_leave: false) }
  let(:start_date) { Date.new(2026, 5, 1) }   # 金曜
  let(:fiscal_year) { org.fiscal_year_for(start_date) }

  def leave(type:, half: :none, days: 1)
    create(:leave_request, requester: user, leave_type: type, start_date:, end_date: start_date,
           half_day_type: half, days_requested: days, approval_status: :withdrawal_requested, withdrawal_reason: "誤申請")
  end
  def withdraw(lr) = described_class.call(leave_request: lr, acting_user: approver)

  it "paid 撤回で used_days を減算（往復で 0 復帰）" do
    bal = create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, granted_days: 20, used_days: 1)
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    withdraw(leave(type: paid_type, days: 1))
    expect(bal.reload.used_days).to eq(BigDecimal("0"))
  end

  it "代休（compensatory・paid_leave=false）撤回でも減算（R2・balance_tracked?）" do
    bal = create(:leave_balance, user:, leave_type: comp_type, fiscal_year:, granted_days: 5, used_days: 1)
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    withdraw(leave(type: comp_type, days: 1))
    expect(bal.reload.used_days).to eq(BigDecimal("0"))
  end

  it "無打刻 on_leave 日は AR を destroy" do
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    withdraw(leave(type: paid_type, days: 1).tap { create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1) })
    expect(AttendanceRecord.find_by(user:, work_date: start_date)).to be_nil
  end

  it "打刻が残る半休日は clocked_out へ戻し destroy しない（R3）" do
    create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
    rec = create(:attendance_record, :done, user:, work_date: start_date, status: :afternoon_half)
    withdraw(create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                    half_day_type: :afternoon, days_requested: BigDecimal("0.5"),
                    approval_status: :withdrawal_requested, withdrawal_reason: "x"))
    expect(rec.reload.status).to eq("clocked_out")
    expect(rec.clock_in).to be_present
  end

  it "leave_withdrawn 履歴を 1 行記録" do
    create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    expect { withdraw(leave(type: paid_type, days: 1)) }
      .to change { AttendanceHistory.where(event_type: :leave_withdrawn).count }.by(1)
  end

  describe "leave_type_id クリア（3-3a・F3）" do
    it "打刻ありの半休戻しで leave_type_id を nil に戻す" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
      rec = create(:attendance_record, :done, user:, work_date: start_date,
                   status: :afternoon_half, leave_type: paid_type)
      withdraw(create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                      half_day_type: :afternoon, days_requested: BigDecimal("0.5"),
                      approval_status: :withdrawal_requested, withdrawal_reason: "x"))
      rec.reload
      expect(rec.status).to eq("clocked_out")
      expect(rec.leave_type_id).to be_nil
    end

    it "clocked 済日への全休 stale 戻しでも leave_type_id クリア（line-104）" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
      rec = create(:attendance_record, :done, user:, work_date: start_date,
                   status: :on_leave, leave_type: paid_type)
      withdraw(leave(type: paid_type, days: 1))
      rec.reload
      expect(rec.status).to eq("clocked_out")
      expect(rec.leave_type_id).to be_nil
    end
  end
end
