# frozen_string_literal: true

# 打刻（1-1 設計 §4）。操作対象は常に current_user — params を一切消費しない（SPEC §3.5）。
# 応答は redirect 一本（既存パターン合流・1-1 設計 §4 で Turbo Stream を不採用とした決定）
class ClockingsController < ApplicationController
  def clock_in
    authorize :clocking, :clock_in?
    result = Clockings::ClockIn.call(user: current_user)
    interval = interval_check(result)
    notify_interval_shortage(result.record, interval) if interval&.violation?
    redirect_with result, t(".success"), warning: interval_warning(interval)
  end

  def clock_out
    authorize :clocking, :clock_out?
    redirect_with Clockings::ClockOut.call(user: current_user), t(".success")
  end

  private

  # 出勤 commit 後の勤務間インターバル判定（§6.9・best-effort・打刻をブロックしない = 鉄則 6）
  def interval_check(result)
    return nil unless result.success?

    Clockings.check_interval_safely(record: result.record, actor: current_user)
  end

  def interval_warning(interval)
    return nil unless interval&.violation?

    t("clockings.interval_warning",
      threshold: current_user.organization.setting.rest_interval_hours,
      shortage: interval.shortage_minutes)
  end

  # 直属 manager への情報提供通知（§6.9・§9.2）。manager 不在（トップ階層）は skip。
  # commit 後 best-effort（§9.5 — 通知失敗が打刻応答を覆さない・absence_confirmations 同型）
  def notify_interval_shortage(record, interval)
    manager = current_user.manager
    return if manager.nil?

    Notifier.call(
      target_user: manager, subject_user: current_user,
      priority: :informational, source_type: :interval_shortage,
      title: "勤務間インターバル不足",
      body: "#{current_user.name} さんの #{record.work_date} の出勤で勤務間インターバルが" \
            "不足しました（不足 #{interval.shortage_minutes} 分）。"
    )
  rescue StandardError => e
    Rails.logger.error(
      "[Notifier] producer 通知失敗 source_type=interval_shortage user=#{current_user.id}: #{e.class}: #{e.message}"
    )
  end

  # 書き込み系の redirect は一律 see_other（Turbo は 302 だとメソッドを保持して再発行する — RAILS_GOTCHAS）。
  # warning は成功時のみ alert に載せる（インターバル警告 — 打刻成功 notice と併存）
  def redirect_with(result, success_message, warning: nil)
    if result.success?
      flash[:alert] = warning if warning
      redirect_to root_path, notice: success_message, status: :see_other
    else
      redirect_to root_path, alert: t("clockings.errors.#{result.error}"), status: :see_other
    end
  end
end
