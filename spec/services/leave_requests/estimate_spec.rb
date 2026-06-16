# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::Estimate do
  let(:org) { create(:organization, fiscal_year_end_month: 3) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:user) { create(:user, organization: org) }
  let(:paid) { create(:leave_type, system_type: :annual, paid_leave: true, allow_half_day: true) }

  def call(start_date:, end_date:, half: :none, leave_type: paid, requester: user)
    described_class.call(requester:, leave_type:, start_date:, end_date:, half_day_type: half)
  end

  it "weekday の単日全休は 1 日・年度は start_date 基準" do
    r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))   # 金曜
    expect(r.days_requested).to eq(BigDecimal("1"))
    expect(r.fiscal_year).to eq("2026")
  end

  describe "残高 2 段階" do
    before { create(:leave_balance, user:, leave_type: paid, fiscal_year: "2026", granted_days: 10, granted_on: Date.new(2026, 4, 1)) }

    it "確定 = granted+carry-used、仮残高は applying を引く" do
      create(:leave_request, requester: user, leave_type: paid, approval_status: :applying,
             start_date: Date.new(2026, 5, 7), end_date: Date.new(2026, 5, 7), days_requested: 2)
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(r.confirmed_remaining).to eq(BigDecimal("10"))
      expect(r.provisional_remaining).to eq(BigDecimal("8"))   # 10 - 2(applying)
      expect(r.remaining_after).to eq(BigDecimal("7"))         # 8 - 1(今回)
      expect(r.status).to eq(:positive)
    end

    it "申請後 0 はアンバー(:zero)、負は赤(:negative)" do
      create(:leave_request, requester: user, leave_type: paid, approval_status: :applying,
             start_date: Date.new(2026, 5, 7), end_date: Date.new(2026, 5, 7), days_requested: 9)
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))   # 仮 1, 申請後 0
      expect(r.status).to eq(:zero)
    end
  end

  describe "仮残高のスコープ隔離（MPR・過小残高バグ防止）" do
    before { create(:leave_balance, user:, leave_type: paid, fiscal_year: "2026", granted_days: 10, granted_on: Date.new(2026, 4, 1)) }

    # 他テナントの applying は acts_as_tenant の default_scope が構造的に除外（このクエリは org 文脈下）。
    # ここでは同テナント内の取りこぼし（他 user / 他 leave_type / 他年度）を pin する
    it "他 user / 他 leave_type / 他年度の applying を巻き込まない" do
      other_user = create(:user, organization: org)
      other_type = create(:leave_type, system_type: :annual, paid_leave: true)
      create(:leave_request, requester: other_user, leave_type: paid, approval_status: :applying,
             start_date: Date.new(2026, 5, 7), end_date: Date.new(2026, 5, 7), days_requested: 3)
      create(:leave_request, requester: user, leave_type: other_type, approval_status: :applying,
             start_date: Date.new(2026, 5, 7), end_date: Date.new(2026, 5, 7), days_requested: 3)
      create(:leave_request, requester: user, leave_type: paid, approval_status: :applying,
             start_date: Date.new(2027, 5, 7), end_date: Date.new(2027, 5, 7), days_requested: 3)   # 翌年度
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(r.provisional_remaining).to eq(BigDecimal("10"))   # どれも引かれない
    end

    it "approved/rejected/canceled は仮残高に効かない" do
      %i[approved rejected canceled].each do |st|
        create(:leave_request, requester: user, leave_type: paid, approval_status: st,
               start_date: Date.new(2026, 5, 7), end_date: Date.new(2026, 5, 7), days_requested: 1)
      end
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(r.provisional_remaining).to eq(BigDecimal("10"))
    end
  end

  describe "残高の有無・種別" do
    it "残高未生成は 0 扱い" do
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(r.confirmed_remaining).to eq(BigDecimal("0"))
    end

    it "非 paid_leave 種別は残高 nil・status nil" do
      other = create(:leave_type, system_type: :other, paid_leave: false)
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1), leave_type: other)
      expect(r.paid_leave).to be(false)
      expect(r.confirmed_remaining).to be_nil
      expect(r.status).to be_nil
    end
  end

  describe "入力契約" do
    it "半休 × 複数日は見積りエラー（calculator 呼出前 fail-closed）" do
      expect {
        call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 2), half: :morning)
      }.to raise_error(ArgumentError)
    end
  end
end
