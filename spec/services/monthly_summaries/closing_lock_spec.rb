# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::ClosingLock, type: :model do
  # model spec ゆえ test_tenant 自動。closing_day はデフォルト 31。
  let(:user) { create(:user) }
  let(:march) { Date.new(2026, 3, 10) }

  def summary_for(label, status, **attrs)
    create(:monthly_attendance_summary, user:, year_month: label, status:, **attrs)
  end

  describe ".locked?" do
    it "summary 行が無ければ unlocked（締めていない＝締まっていない）" do
      expect(described_class.locked?(user:, dates: march)).to be(false)
    end

    it "submitted は locked" do
      summary_for("2026-03", :submitted)
      expect(described_class.locked?(user:, dates: march)).to be(true)
    end

    it "finalized は locked" do
      summary_for("2026-03", :finalized)
      expect(described_class.locked?(user:, dates: march)).to be(true)
    end

    it "deferred は unlocked" do
      summary_for("2026-03", :deferred, deferral_reason: "差戻し理由")
      expect(described_class.locked?(user:, dates: march)).to be(false)
    end

    it "aggregating は unlocked" do
      summary_for("2026-03", :aggregating)
      expect(described_class.locked?(user:, dates: march)).to be(false)
    end

    it "別 user の submitted は引かない" do
      other = create(:user)
      create(:monthly_attendance_summary, user: other, year_month: "2026-03", status: :submitted)
      expect(described_class.locked?(user:, dates: march)).to be(false)
    end

    it "Range で複数期に跨り 1 期だけ locked なら true" do
      summary_for("2026-04", :submitted) # 4 月だけ締め
      range = Date.new(2026, 3, 25)..Date.new(2026, 4, 5)
      expect(described_class.locked?(user:, dates: range)).to be(true)
    end

    it "Range で全期 unlocked なら false" do
      range = Date.new(2026, 3, 25)..Date.new(2026, 4, 5)
      expect(described_class.locked?(user:, dates: range)).to be(false)
    end

    it "Array でも判定できる" do
      summary_for("2026-03", :submitted)
      expect(described_class.locked?(user:, dates: [ Date.new(2026, 3, 1), Date.new(2026, 3, 31) ])).to be(true)
    end

    it "他テナントの summary を引かない（with_tenant スコープ）" do
      # user は test_tenant 所属。別 org に同 user は作れないため、別 org の別 user で submitted を作っても
      # locked? は user の org スコープで引くため false（クロステナント遮断の実証）
      other_org = create(:organization)
      ActsAsTenant.with_tenant(other_org) do
        ou = create(:user)
        create(:monthly_attendance_summary, user: ou, year_month: "2026-03", status: :submitted)
      end
      expect(described_class.locked?(user:, dates: march)).to be(false)
    end
  end
end
