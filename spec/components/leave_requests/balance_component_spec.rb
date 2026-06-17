# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::BalanceComponent, type: :component do
  def result(remaining_after:, paid_leave: true)
    LeaveRequests::Estimate::Result.new(
      days_requested: BigDecimal("1"), fiscal_year: "2026", paid_leave:,
      confirmed_remaining: BigDecimal("10"), provisional_remaining: BigDecimal("5"), remaining_after:
    )
  end

  it "positive は通常表示（警告文言なし）" do
    render_inline(described_class.new(estimate: result(remaining_after: BigDecimal("4"))))
    expect(page).not_to have_text("使い切ります")
    expect(page).to have_text("5")   # 仮残高
  end

  it "zero はアンバー + 定文言" do
    render_inline(described_class.new(estimate: result(remaining_after: BigDecimal("0"))))
    expect(page).to have_text("今年度の有給を使い切ります")
    expect(page).to have_css(".text-amber-600, .bg-amber-50", visible: :all)
  end

  it "negative は赤警告" do
    render_inline(described_class.new(estimate: result(remaining_after: BigDecimal("-2"))))
    expect(page).to have_css(".text-red-600, .bg-red-50", visible: :all)
  end

  it "非 paid_leave 種別は残高ブロックを描画しない" do
    render_inline(described_class.new(estimate: result(remaining_after: nil, paid_leave: false)))
    expect(page).not_to have_text("残")
  end
end
