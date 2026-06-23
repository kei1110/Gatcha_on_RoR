# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::Csv::SummaryExporter do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def csv(summaries) = described_class.call(summaries: summaries).to_a.join

  it "BOM + ヘッダ行で始まる" do
    out = csv([])
    expect(out).to start_with("﻿社員コード,氏名,")
    expect(out).to end_with("総休暇時間\r\n")
  end

  it "1 summary = 1 行・列順と値（社員コード/氏名先頭・小数ドット・管理監督者 1/0）" do
    user = create(:user, employee_code: "E042", name: "山田太郎", exempt_from_overtime: true)
    s = create(:monthly_attendance_summary, user:, year_month: "2026-03",
               scheduled_work_days: 20, work_days: 18, total_work_hours: BigDecimal("144.0"),
               total_overtime_hours: BigDecimal("8.5"), overtime_hours_over_60: BigDecimal("0.0"),
               holiday_work_hours: BigDecimal("0.0"), total_deep_night_hours: BigDecimal("1.5"),
               late_days: 1, early_leave_days: 0,
               paid_leave_days_used: BigDecimal("1.5"), total_leave_hours: BigDecimal("12.0"))
    row = csv([ s ]).split("\r\n").last
    expect(row).to eq("E042,山田太郎,20,18,144.0,8.5,0.0,0.0,1.5,1,1.5,1,0,12.0")
  end

  it "氏名の formula-injection を無害化（先頭 = は ' 前置）" do
    user = create(:user, employee_code: "E001", name: "=cmd()")
    s = create(:monthly_attendance_summary, user:, year_month: "2026-03")
    expect(csv([ s ])).to include("E001,\"'=cmd()\",").or include("E001,'=cmd(),")
  end
end
