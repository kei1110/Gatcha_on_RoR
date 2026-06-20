# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlyAttendanceSummary do
  let(:org) { ActsAsTenant.test_tenant } # support/tenant.rb が既定テナントを設定
  let(:user) { create(:user, organization: org) }

  it "有効な属性で valid" do
    expect(build(:monthly_attendance_summary, user:, year_month: "2026-03")).to be_valid
  end

  describe "year_month format" do
    it "厳密に YYYY-MM のみ valid" do
      expect(build(:monthly_attendance_summary, user:, year_month: "2026-03")).to be_valid
      [ "2026-13", "2026-3", "2026-00", "202603", "" ].each do |bad|
        expect(build(:monthly_attendance_summary, user:, year_month: bad)).to be_invalid
      end
    end
  end

  describe "テナント内 uniqueness（同 user 同 year_month）" do
    it "同一 user・同一 year_month は衝突" do
      create(:monthly_attendance_summary, user:, year_month: "2026-03")
      dup = build(:monthly_attendance_summary, user:, year_month: "2026-03")
      expect(dup).to be_invalid
    end
  end

  describe "user_must_belong_to_same_organization（Critical・§3.6）" do
    it "他組織の user を代入で invalid" do
      other_user = ActsAsTenant.with_tenant(create(:organization)) { create(:user) }
      summary = build(:monthly_attendance_summary, user: other_user, year_month: "2026-03")
      expect(summary).to be_invalid
      expect(summary.errors[:user]).to include("は同一組織でなければなりません")
    end
  end

  describe "numericality" do
    it "集計列の負値は invalid" do
      expect(build(:monthly_attendance_summary, user:, total_work_hours: -1)).to be_invalid
    end
  end

  describe "テナントスコープ" do
    it "他社行は default_scope で見えない" do
      create(:monthly_attendance_summary, user:, year_month: "2026-03")
      other = create(:organization)
      ActsAsTenant.with_tenant(other) do
        expect(MonthlyAttendanceSummary.count).to eq(0)
      end
    end
  end
end
