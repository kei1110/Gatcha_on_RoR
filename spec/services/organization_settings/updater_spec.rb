# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrganizationSettings::Updater do
  let(:org) { ActsAsTenant.test_tenant } # fiscal_year_end_month 既定 3

  def call(org_params: {}, setting_params: {})
    described_class.call(organization: org,
                         organization_params: org_params, setting_params: setting_params)
  end

  describe "成功経路" do
    it "決算月変更で既存カレンダーの fiscal_year を再計算し実変更数を返す" do
      calendar = create(:company_calendar, date: Date.new(2026, 1, 15)) # 3 月決算 → "2025"
      expect(calendar.fiscal_year).to eq("2025")

      result = call(org_params: { fiscal_year_end_month: 12 }) # 1 月始まり → "2026"
      expect(result.success?).to be(true)
      expect(result.recalculated_count).to eq(1)
      expect(calendar.reload.fiscal_year).to eq("2026")
    end

    it "決算月が変わらない保存では再計算しない（カウント 0・カレンダー不変）" do
      calendar = create(:company_calendar, date: Date.new(2026, 1, 15))

      result = call(setting_params: { closing_day: 25 })
      expect(result.success?).to be(true)
      expect(result.recalculated_count).to eq(0)
      expect(calendar.reload.fiscal_year).to eq("2025")
      expect(org.setting.reload.closing_day).to eq(25)
    end

    it "再計算しても fiscal_year が同値の行は実変更数に数えない" do
      create(:company_calendar, date: Date.new(2026, 1, 15))  # 3 月決算 "2025" → 6 月決算でも "2025"
      create(:company_calendar, date: Date.new(2026, 10, 1))  # "2026" → 6 月決算 "2026"（不変）

      result = call(org_params: { fiscal_year_end_month: 6 })
      expect(result.success?).to be(true)
      expect(result.recalculated_count).to eq(0) # 月は変わったが年度ラベルは両行とも同値
    end
  end

  describe "失敗経路" do
    it "両モデルの検証エラーを同時に集める（& の非短絡）" do
      result = call(org_params: { fiscal_year_end_month: 13 }, setting_params: { closing_day: 0 })
      expect(result.success?).to be(false)
      expect(result.organization.errors[:fiscal_year_end_month]).to be_present
      expect(result.setting.errors[:closing_day]).to be_present
      expect(org.reload.fiscal_year_end_month).to eq(3) # 保存されていない
    end

    it "再計算中の RecordInvalid は全体を巻き戻し failure（500 にしない 422 合流）" do
      create(:company_calendar, date: Date.new(2026, 1, 15))
      allow_any_instance_of(CompanyCalendar).to receive(:save!)
        .and_raise(ActiveRecord::RecordInvalid.new(CompanyCalendar.new))

      result = call(org_params: { fiscal_year_end_month: 12 })
      expect(result.success?).to be(false)
      expect(result.organization.errors[:base].join).to include("取り消しました")
      expect(org.reload.fiscal_year_end_month).to eq(3) # tx rollback 済み
    end
  end

  describe "テナント自己完結（SPEC §3.6）" do
    it "他テナントのカレンダーは再計算しない" do
      other_org = create(:organization)
      other_cal = ActsAsTenant.with_tenant(other_org) do
        create(:company_calendar, date: Date.new(2026, 1, 15))
      end

      call(org_params: { fiscal_year_end_month: 12 })
      expect(other_cal.reload.fiscal_year).to eq("2025") # 不変
    end
  end
end
