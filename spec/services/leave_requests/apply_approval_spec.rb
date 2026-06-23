# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::ApplyApproval do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org) }
  let(:paid_type) { create(:leave_type, system_type: :annual, paid_leave: true) }
  let(:unpaid_type) { create(:leave_type, system_type: :other, paid_leave: false, allow_half_day: true) }

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

  describe "AttendanceRecord upsert（§13.1 の 2-2b 担当遷移）" do
    it "全休は計上日ごとに on_leave AR を作成（打刻無・calc NULL）" do
      apply(leave(type: unpaid_type, days: 1))   # 2026-05-01（金）単日
      record = AttendanceRecord.find_by(user:, work_date: start_date)
      expect(record).to have_attributes(status: "on_leave", clock_in: nil)
      expect(record.actual_work_hours).to be_nil
    end

    it "除外日（土日）には AR を作らない" do
      # 2026-05-01(金)〜2026-05-04(月): 土(2)/日(3) 除外、金・月のみ計上
      apply(leave(type: unpaid_type, sd: Date.new(2026, 5, 1), ed: Date.new(2026, 5, 4), days: 2))
      expect(AttendanceRecord.where(user:).pluck(:work_date))
        .to contain_exactly(Date.new(2026, 5, 1), Date.new(2026, 5, 4))
    end

    it "月跨ぎは各 AR が自分の月の work_date を持つ" do
      # 2026-05-29(金)〜2026-06-01(月): 5/29 金・6/1 月が計上（5/30 土・5/31 日 除外）
      apply(leave(type: unpaid_type, sd: Date.new(2026, 5, 29), ed: Date.new(2026, 6, 1), days: 2))
      dates = AttendanceRecord.where(user:).pluck(:work_date)
      expect(dates).to contain_exactly(Date.new(2026, 5, 29), Date.new(2026, 6, 1))
    end

    it "打刻済（clocked_out）の日に午前半休が承認されると status 更新 + 遅刻免除" do
      pattern = create(:work_pattern, start_time: "09:00", end_time: "18:00", break_minutes: 60)
      existing = create(:attendance_record, user:, work_pattern: pattern, status: :clocked_out,
                        work_date: start_date,
                        clock_in: Time.utc(2026, 5, 1, 1),    # JST 10:00（本来遅刻）
                        clock_out: Time.utc(2026, 5, 1, 9))   # JST 18:00
      apply(leave(type: unpaid_type, half: :morning))
      expect(existing.reload).to have_attributes(status: "morning_half", is_late: false)
    end

    it "AttendanceHistory(leave_approved) を actor=承認者・source=申請で 1 行記録" do
      expect { apply(leave(type: unpaid_type, days: 1)) }
        .to change { AttendanceHistory.where(event_type: :leave_approved).count }.by(1)
      history = AttendanceHistory.find_by(event_type: :leave_approved)
      expect(history).to have_attributes(actor_id: approver.id, source: have_attributes(id: anything),
                                         user_id: user.id)
    end
  end

  describe "代休 LeaveRequest 消費（D2 一般化）" do
    let(:org) { create(:organization) }
    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
    let(:user) { create(:user, organization: org) }
    let(:approver) { create(:user, :manager_role, organization: org) }
    let(:comp) { create(:leave_type, system_type: :compensatory_leave, paid_leave: false, organization: org) }
    let(:fy) { org.fiscal_year_for(Date.new(2026, 6, 7)) }

    def consume(days:, start_date: Date.new(2026, 6, 7))
      lr = create(:leave_request, organization: org, requester: user, leave_type: comp,
                                  start_date:, end_date: start_date, days_requested: days,
                                  approval_status: :approved)
      described_class.call(leave_request: lr, acting_user: approver)
    end

    it "残高ありで取得すると used_days が減算される" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 2)
      consume(days: 1)
      expect(LeaveBalance.find_by(user:, leave_type: comp, fiscal_year: fy).used_days).to eq(1)
    end

    it "残高超過は OverBalanceError + used_days 不変 + AR/history 未作成" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 1)
      expect { consume(days: 2) }.to raise_error(Approvals::OverBalanceError)
      bal = LeaveBalance.find_by(user:, leave_type: comp, fiscal_year: fy)
      expect(bal.used_days).to eq(0)
      expect(AttendanceRecord.where(user:, work_date: Date.new(2026, 6, 7))).to be_empty
    end

    it "境界（消費 == 残高）は成功" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 1)
      expect { consume(days: 1) }.not_to raise_error
    end

    it "代休 LeaveBalance は carry_over_days=0 を維持（繰越対象外・R8）" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 2)
      consume(days: 1)
      expect(LeaveBalance.find_by(user:, leave_type: comp, fiscal_year: fy).carry_over_days).to eq(0)
    end
  end

  describe "年度跨ぎ（§6.2 start_date 年度に統一）" do
    it "start_date の年度の残高にのみ加算する" do
      # 3月決算（4月開始）想定でも robust に: start_date 年度の残高だけ動く
      fy_start = org.fiscal_year_for(Date.new(2026, 5, 1))
      this_year = create(:leave_balance, user:, leave_type: paid_type, fiscal_year: fy_start,
                         granted_days: 20, used_days: 0)
      apply(leave(type: paid_type, sd: Date.new(2026, 5, 1), ed: Date.new(2026, 5, 1), days: 1))
      expect(this_year.reload.used_days).to eq(BigDecimal("1"))
    end
  end

  describe "leave_type_id の AR 焼き込み（3-3a）" do
    it "paid 種別: 作成する休暇 AR に leave_type_id を set" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, granted_days: 20, used_days: 0)
      apply(leave(type: paid_type, days: 1))
      rec = AttendanceRecord.find_by(user:, work_date: start_date)
      expect(rec.leave_type_id).to eq(paid_type.id)
    end

    it "非 paid 種別でも leave_type_id を set" do
      apply(leave(type: unpaid_type, days: 1))
      rec = AttendanceRecord.find_by(user:, work_date: start_date)
      expect(rec.leave_type_id).to eq(unpaid_type.id)
    end
  end
end
