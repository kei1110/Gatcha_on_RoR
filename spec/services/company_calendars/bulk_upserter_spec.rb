# frozen_string_literal: true

require "rails_helper"

RSpec.describe CompanyCalendars::BulkUpserter do
  let(:org) { create(:organization) }

  def row(date, day_type: "holiday", name: "祝日", counts: false, line: 2)
    { line:, date: Date.parse(date), day_type:, name:, counts_as_paid_leave: counts }
  end

  def upsert(rows, allow_demotion: false, organization: org)
    described_class.new(organization:, allow_demotion:).call(rows)
  end

  it "作成・更新の混在を 1 トランザクションで取り込み件数を返す" do
    ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-01-01", name: "旧名") }
    result = upsert([ row("2026-01-01", name: "元日"), row("2026-02-11", name: "建国記念の日", line: 3) ])

    expect(result).to be_success
    expect(result.created_count).to eq(1)
    expect(result.updated_count).to eq(1)
    expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.find_by!(date: "2026-01-01").name }).to eq("元日")
  end

  it "1 行でも不正なら全件不採用（DB 不変・行番号付きエラー）" do
    result = upsert([ row("2026-01-01"), row("2026-02-11", name: nil, line: 5) ]) # holiday の name 欠落

    expect(result).not_to be_success
    expect(result.errors.map(&:line)).to eq([ 5 ])
    expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.count }).to eq(0)
  end

  it "他テナントの同一日付には影響しない（cross-tenant 鏡像）" do
    other_org = create(:organization)
    other = ActsAsTenant.with_tenant(other_org) { create(:company_calendar, date: "2026-01-01", name: "他社") }

    result = upsert([ row("2026-01-01", name: "元日") ])
    expect(result.created_count).to eq(1) # 他社行の update でなく自社行の create
    expect(other.reload.name).to eq("他社")
  end

  it "without_tenant 文脈でも自テナントにのみ書く（fail-open 遮断・設計 §3）" do
    result = ActsAsTenant.without_tenant { upsert([ row("2026-01-01") ]) }
    expect(result).to be_success
    expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.find_by!(date: "2026-01-01") }).to be_present
  end

  it "organization: nil は ArgumentError" do
    expect { described_class.new(organization: nil) }.to raise_error(ArgumentError)
  end

  describe "降格検出（35% 保護 — 非対称ガード・設計 §3）" do
    before do
      ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-05-10", day_type: :legal_holiday) }
    end

    it "legal_holiday → 他種別は allow_demotion なしでエラー・ありで成功" do
      result = upsert([ row("2026-05-10", day_type: "holiday", name: "祝日") ])
      expect(result).not_to be_success
      expect(result.errors.first.message).to include("法定休日")

      result = upsert([ row("2026-05-10", day_type: "holiday", name: "祝日") ], allow_demotion: true)
      expect(result).to be_success
    end

    it "労働者有利方向（holiday → legal_holiday・legal_holiday 同値再取込）はフラグ不要（対照）" do
      ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-01-01") } # holiday
      result = upsert([ row("2026-01-01", day_type: "legal_holiday", name: nil),
                        row("2026-05-10", day_type: "legal_holiday", name: nil, line: 3) ])
      expect(result).to be_success
    end
  end

  it "行数上限 2,000 を超えるとファイルエラー" do
    rows = (1..2_001).map { |n| row("2026-01-01", line: n) } # 中身は検証前に弾かれる
    result = upsert(rows)
    expect(result).not_to be_success
    expect(result.errors.first.message).to include("2000")
    expect(result.errors.first.line).to be_nil
  end
end
