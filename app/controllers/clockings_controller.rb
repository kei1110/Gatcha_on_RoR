# 打刻（1-1 設計 §4）。操作対象は常に current_user — params を一切消費しない（SPEC §3.5）。
# 応答は redirect 一本（既存パターン合流・1-1 設計 §4 で Turbo Stream を不採用とした決定）
class ClockingsController < ApplicationController
  def clock_in
    authorize :clocking, :clock_in?
    redirect_with Clockings::ClockIn.call(user: current_user), t(".success")
  end

  def clock_out
    authorize :clocking, :clock_out?
    redirect_with Clockings::ClockOut.call(user: current_user), t(".success")
  end

  private

  # 書き込み系の redirect は一律 see_other（Turbo は 302 だとメソッドを保持して再発行する — RAILS_GOTCHAS）
  def redirect_with(result, success_message)
    if result.success?
      redirect_to root_path, notice: success_message, status: :see_other
    else
      redirect_to root_path, alert: t("clockings.errors.#{result.error}"), status: :see_other
    end
  end
end
