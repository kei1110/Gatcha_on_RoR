# frozen_string_literal: true

require "rails_helper"

RSpec.describe Absences::GracePeriod do
  let(:org) { create(:organization, time_zone: "Asia/Tokyo") }
  let(:grace) { described_class.new(organization: org) }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  describe "#deadline" do
    it "notified_on の翌営業日 17:00（組織 TZ）を返す（2026-05-01 金 → 2026-05-04 月 17:00 JST）" do
      deadline = grace.deadline(Date.new(2026, 5, 1))
      expect(deadline).to eq(Time.utc(2026, 5, 4, 8)) # JST 17:00 = UTC 08:00
    end

    it "連休を吸収する" do
      create(:company_calendar, date: Date.new(2026, 5, 4), day_type: :company_holiday, name: "連休")
      create(:company_calendar, date: Date.new(2026, 5, 5), day_type: :company_holiday, name: "連休")
      expect(grace.deadline(Date.new(2026, 5, 1))).to eq(Time.utc(2026, 5, 6, 8))
    end

    it "notified_on が nil なら nil（next_business_day(nil) を計算しない）" do
      expect(grace.deadline(nil)).to be_nil
    end

    it "同一 notified_on の再問い合わせはカレンダーを再クエリしない（メモ化・N+1 解消）" do
      grace.deadline(Date.new(2026, 5, 1))
      expect(CompanyCalendar).not_to receive(:where)
      grace.deadline(Date.new(2026, 5, 1))
    end
  end

  describe "#elapsed?" do
    it "16:59 JST は未経過・17:01 JST は経過（境界の両側）" do
      expect(grace.elapsed?(Date.new(2026, 5, 1), Time.utc(2026, 5, 4, 7, 59))).to be(false)
      expect(grace.elapsed?(Date.new(2026, 5, 1), Time.utc(2026, 5, 4, 8, 1))).to be(true)
    end

    it "notified_on が nil なら常に未経過（fail-closed）" do
      expect(grace.elapsed?(nil)).to be(false)
    end
  end
end
