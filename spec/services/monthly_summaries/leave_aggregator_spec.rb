# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::LeaveAggregator do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:user) { create(:user, organization: org) }
  let(:paid_type) { create(:leave_type, system_type: :annual, paid_leave: true, allow_half_day: true) }
  let(:unpaid_type) { create(:leave_type, system_type: :other, paid_leave: false, allow_half_day: true) }

  def period(year_month) = AttendancePeriod.new(organization: org, year_month:)

  def assign_pattern(hours, start_date: Date.new(2026, 1, 1))
    create(:user_work_pattern, user:, start_date:,
           work_pattern: create(:work_pattern, standard_work_hours: hours))
  end

  def leave_ar(date, status:, type:, **attrs)
    create(:attendance_record, user:, work_date: date, status:, clock_in: nil, leave_type: type, **attrs)
  end

  before { org.setting.update!(closing_day: 31) }

  it "paid 全休 1 日 = paid 1.0 / total_leave_hours = standard_work_hours" do
    assign_pattern(8)
    leave_ar(Date.new(2026, 3, 2), status: :on_leave, type: paid_type)
    result = described_class.call(user:, period: period("2026-03"))
    expect(result[:paid_leave_days_used]).to eq(1)
    expect(result[:total_leave_hours]).to eq(8)
  end

  it "unpaid は paid に乗らないが total_leave_hours には乗る（全種別）" do
    assign_pattern(8)
    leave_ar(Date.new(2026, 3, 2), status: :on_leave, type: unpaid_type)
    result = described_class.call(user:, period: period("2026-03"))
    expect(result[:paid_leave_days_used]).to eq(0)
    expect(result[:total_leave_hours]).to eq(8)
  end

  it "半休（afternoon_half・打刻なし）= 0.5 日 / standard_work_hours ÷2" do
    assign_pattern(8)
    leave_ar(Date.new(2026, 3, 2), status: :afternoon_half, type: paid_type)
    result = described_class.call(user:, period: period("2026-03"))
    expect(result[:paid_leave_days_used]).to eq(BigDecimal("0.5"))
    expect(result[:total_leave_hours]).to eq(4)
  end

  it "standard_work_hours=7 のパターンは full leave 7h" do
    assign_pattern(7)
    leave_ar(Date.new(2026, 3, 2), status: :on_leave, type: paid_type)
    expect(described_class.call(user:, period: period("2026-03"))[:total_leave_hours]).to eq(7)
  end

  it "未割当日（effective パターンなし）は hours 0h・paid は計上" do
    leave_ar(Date.new(2026, 3, 2), status: :on_leave, type: paid_type) # 割当なし
    result = described_class.call(user:, period: period("2026-03"))
    expect(result[:paid_leave_days_used]).to eq(1)
    expect(result[:total_leave_hours]).to eq(0)
  end

  it "半休+打刻 AR は work_pattern スナップショットを優先（effective でなく snapshot）" do
    snapshot = create(:work_pattern, standard_work_hours: 6)
    assign_pattern(8) # effective は 8h だが snapshot 優先なら 3h（6÷2）
    create(:attendance_record, :done, user:, work_date: Date.new(2026, 3, 2),
           status: :afternoon_half, leave_type: paid_type, work_pattern: snapshot)
    expect(described_class.call(user:, period: period("2026-03"))[:total_leave_hours]).to eq(3)
  end

  it "period.range 外の leave AR は計上しない（月跨ぎ per-day）" do
    assign_pattern(8)
    leave_ar(Date.new(2026, 4, 1), status: :on_leave, type: paid_type) # 翌期
    result = described_class.call(user:, period: period("2026-03"))
    expect(result[:paid_leave_days_used]).to eq(0)
    expect(result[:total_leave_hours]).to eq(0)
  end

  it "他社の同日 leave AR を混ぜない（テナント分離）" do
    assign_pattern(8)
    leave_ar(Date.new(2026, 3, 2), status: :on_leave, type: paid_type)
    other = create(:organization)
    ActsAsTenant.with_tenant(other) do
      ou = create(:user, organization: other)
      ot = create(:leave_type, organization: other, paid_leave: true)
      create(:attendance_record, user: ou, work_date: Date.new(2026, 3, 2),
             status: :on_leave, clock_in: nil, leave_type: ot)
    end
    expect(described_class.call(user:, period: period("2026-03"))[:paid_leave_days_used]).to eq(1)
  end
end
