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

  describe "#day_classifications" do
    let(:org) { create(:organization) }
    subject(:resolver) { described_class.new(organization: org) }

    it "登録日は day_type と counts_as_paid_leave を surface する" do
      ActsAsTenant.with_tenant(org) do
        create(:company_calendar, date: Date.new(2026, 5, 1), day_type: :company_holiday,
                                  counts_as_paid_leave: true, name: "創立記念日")
      end
      result = resolver.day_classifications(Date.new(2026, 5, 1), Date.new(2026, 5, 1))
      expect(result[Date.new(2026, 5, 1)]).to eq(day_type: :company_holiday, counts_as_paid_leave: true)
    end

    it "未登録日は ISO 曜日 fallback・counts_as_paid_leave は false" do
      # 2026-05-02 は土曜
      result = resolver.day_classifications(Date.new(2026, 5, 2), Date.new(2026, 5, 2))
      expect(result[Date.new(2026, 5, 2)]).to eq(day_type: :saturday, counts_as_paid_leave: false)
    end
  end

  describe "#next_business_day（猶予期限の基盤・§12①）" do
    let(:org) { create(:organization) }
    let(:resolver) { described_class.new(organization: org) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "翌日が稼働日ならその日を返す（2026-05-01 金 → 2026-05-02 土は休日ゆえ次の平日）" do
      # 未登録日は曜日 fallback（土=saturday / 日=sunday / 他=weekday）
      expect(resolver.next_business_day(Date.new(2026, 5, 1))).to eq(Date.new(2026, 5, 4)) # 月曜
    end

    it "翌日が平日ならその日を返す" do
      expect(resolver.next_business_day(Date.new(2026, 5, 4))).to eq(Date.new(2026, 5, 5)) # 火曜
    end

    it "連休を吸収する（登録済 company_holiday を跨いで次の稼働日）" do
      create(:company_calendar, date: Date.new(2026, 5, 4), day_type: :company_holiday, name: "連休")
      create(:company_calendar, date: Date.new(2026, 5, 5), day_type: :company_holiday, name: "連休")
      expect(resolver.next_business_day(Date.new(2026, 5, 1))).to eq(Date.new(2026, 5, 6)) # 水曜
    end

    it "起点日自身は稼働日でも返さない（翌日以降を探す）" do
      expect(resolver.next_business_day(Date.new(2026, 5, 7))).to eq(Date.new(2026, 5, 8))
    end

    it "先読み上限内に稼働日が無ければ nil（呼び出し側が fail-closed に倒す）" do
      from = Date.new(2026, 5, 2)
      (from..(from + 30)).each_with_index do |d, i|
        create(:company_calendar, date: d, day_type: :company_holiday, name: "長期休業#{i}")
      end
      expect(resolver.next_business_day(Date.new(2026, 5, 1))).to be_nil
    end
  end

  describe "HOLIDAY_DAY_TYPES（SSOT・Notifier は alias）" do
    it "休日 day_type の集合を凍結して公開する" do
      expect(described_class::HOLIDAY_DAY_TYPES)
        .to eq(%i[saturday sunday holiday legal_holiday company_holiday])
      expect(described_class::HOLIDAY_DAY_TYPES).to be_frozen
    end

    it "Notifier::HOLIDAY_DAY_TYPES は同一オブジェクト（重複定義を排除）" do
      expect(Notifier::HOLIDAY_DAY_TYPES).to equal(described_class::HOLIDAY_DAY_TYPES)
    end
  end
end
