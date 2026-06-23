# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::Csv::DailyDetailExporter do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:user) { create(:user) }

  def csv(records) = described_class.call(records: records, time_zone: "Tokyo").to_a.join

  it "BOM + ヘッダ行で始まる" do
    expect(csv([])).to start_with("﻿日付,出勤,退勤,")
  end

  it "出勤日: 日付/時刻(組織TZ)/実労働/残業/深夜/遅刻早退/状態" do
    rec = create(:attendance_record, user:, work_date: Date.new(2026, 3, 5), status: :clocked_out,
                 clock_in: Time.utc(2026, 3, 5, 0), clock_out: Time.utc(2026, 3, 5, 9),
                 actual_work_hours: BigDecimal("8.0"), legal_overtime_hours: BigDecimal("0.0"),
                 scheduled_overtime_hours: 0, deep_night_hours: BigDecimal("0.0"),
                 is_late: true, late_minutes: 15, is_early_leave: false, early_leave_minutes: 0)
    row = csv([ rec ]).split("\r\n").last
    expect(row).to eq("2026-03-05,09:00,18:00,8.0,0.0,0.0,15,0,退勤済")
  end

  it "全休日: 計算 8 列 NULL は空セル・状態は全休" do
    rec = create(:attendance_record, user:, work_date: Date.new(2026, 3, 6), status: :on_leave, clock_in: nil)
    row = csv([ rec ]).split("\r\n").last
    expect(row).to eq("2026-03-06,,,,,,,,全休")
  end
end
