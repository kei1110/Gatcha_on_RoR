# frozen_string_literal: true

module LeaveRequests
  # 残高 2 段階表示（SPEC §6.2・Phase 2-2a 設計 §4.3）。状態は Estimate::Result#status が決定。
  # paid_leave 種別のみ描画。erb にロジックを散らさない。
  class BalanceComponent < ViewComponent::Base
    STATE = {
      positive: { css: "text-gray-700", note: nil },
      zero: { css: "text-amber-600 bg-amber-50 px-2 py-1 rounded", note: "今年度の有給を使い切ります" },
      negative: { css: "text-red-600 bg-red-50 px-2 py-1 rounded", note: "残高が不足しています（承認者の判断で申請可）" }
    }.freeze

    def initialize(estimate:)
      @estimate = estimate
    end

    def render? = @estimate.paid_leave

    def confirmed = @estimate.confirmed_remaining
    def provisional = @estimate.provisional_remaining
    def remaining_after = @estimate.remaining_after
    def style = STATE.fetch(@estimate.status)
  end
end
