# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompanyCalendarResolver do
  let(:org) { create(:organization) }
  let(:resolver) { described_class.new(organization: org) }

  before do
    ActsAsTenant.with_tenant(org) do
      create(:company_calendar, date: "2026-01-01", day_type: :holiday, name: "元日")
      create(:company_calendar, date: "2026-01-04", day_type: :legal_holiday) # 日曜
    end
  end

  describe "#day_type" do
    it "登録日はレコードの値・未登録日は ISO 曜日フォールバック（§4.7）" do
      expect(resolver.day_type(Date.new(2026, 1, 1))).to eq(:holiday)
      expect(resolver.day_type(Date.new(2026, 1, 4))).to eq(:legal_holiday)
      # 未登録: 2026-01-05 月 / 2026-01-10 土 / 2026-01-11 日
      expect(resolver.day_type(Date.new(2026, 1, 5))).to eq(:weekday)
      expect(resolver.day_type(Date.new(2026, 1, 10))).to eq(:saturday)
      expect(resolver.day_type(Date.new(2026, 1, 11))).to eq(:sunday)
    end

    it "他テナントの登録日は拾わない（without_tenant 文脈でも自テナント解決）" do
      ActsAsTenant.with_tenant(create(:organization)) do
        create(:company_calendar, date: "2026-01-05", day_type: :company_holiday, name: "他社休業")
      end
      result = ActsAsTenant.without_tenant { resolver.day_type(Date.new(2026, 1, 5)) }
      expect(result).to eq(:weekday)
    end
  end

  describe "#registered?" do
    it "登録由来かフォールバック由来かを判別（Phase 1 の 35% 警告の手がかり — 設計 §3）" do
      expect(resolver.registered?(Date.new(2026, 1, 4))).to be(true)
      expect(resolver.registered?(Date.new(2026, 1, 11))).to be(false)
    end
  end

  describe "#day_types（範囲一括）" do
    it "範囲内の全日付を解決した Hash を返す（未登録日はフォールバック済み）" do
      result = resolver.day_types(Date.new(2026, 1, 1), Date.new(2026, 1, 5))
      expect(result).to eq(
        Date.new(2026, 1, 1) => :holiday,
        Date.new(2026, 1, 2) => :weekday,
        Date.new(2026, 1, 3) => :saturday,
        Date.new(2026, 1, 4) => :legal_holiday,
        Date.new(2026, 1, 5) => :weekday)
    end
  end

  it "organization: nil は ArgumentError" do
    expect { described_class.new(organization: nil) }.to raise_error(ArgumentError)
  end
end
