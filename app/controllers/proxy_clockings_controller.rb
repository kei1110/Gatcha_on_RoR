# frozen_string_literal: true

# 代理打刻（1-3 設計 §5）。manager(直接部下) / hr_admin(全員) が対象社員に代わり打刻。
# 対象は policy_scope.find で解決 → scope 外は RecordNotFound → 404（IDOR 対策・SPEC §3.4）。
class ProxyClockingsController < ApplicationController
  def index
    authorize :proxy_clocking, :index?
    @targets = roster.order(:employee_code).to_a
    @today = current_user.organization.today
    ids = @targets.map(&:id)
    # 打刻状態を 1 クエリ先読み（per-row N+1 回避・§R-10）
    @open = AttendanceRecord.working_within(Clockings.window(@today))
                            .where(user_id: ids).index_by(&:user_id)
    @done_today = AttendanceRecord.where(user_id: ids, work_date: @today)
                                  .where.not(status: :working).index_by(&:user_id)
  end

  def clock_in
    authorize :proxy_clocking, :clock_in?
    target = roster.find(params[:id])
    result = Clockings::ProxyClockIn.call(operator: current_user, target_user: target,
                                          reason: params[:proxy_clock_reason])
    interval = nil
    if result.success?
      notify_proxy_clocked(target, kind: "出勤", remedy: "退勤打刻の後に打刻変更申請で修正できます")
      interval = Clockings.check_interval_safely(record: result.record, actor: current_user)
      notify_target_interval(target, result.record, interval) if interval&.violation?
    end
    redirect_with(result, t(".success"), warning: interval_warning(target, interval))
  end

  def clock_out
    authorize :proxy_clocking, :clock_out?
    target = roster.find(params[:id])
    result = Clockings::ProxyClockOut.call(operator: current_user, target_user: target,
                                           reason: params[:proxy_clock_reason])
    notify_proxy_clocked(target, kind: "退勤", remedy: "打刻変更申請で修正できます") if result.success?
    redirect_with(result, t(".success"))
  end

  private

  # policy_scope(User) 単独は top-level UserPolicy 不在で NotDefinedError ゆえ
  # policy_scope_class を明示（§R・§5 設計）。verify_policy_scoped も満たす
  def roster = policy_scope(User, policy_scope_class: ProxyClockingPolicy::Scope)

  # 本人への代理打刻通知（§9.1・設計 §13③ — 暫定バナーを置換する恒久解決）。
  # remedy は「その時点で実際に可能な操作」のみ約束する（§11③ 虚偽 remedy 禁止 —
  # CCR は clocked_out 記録が前提ゆえ、出勤直後は「退勤後に」と案内する）。
  # commit 後 best-effort（§9.5 — 通知失敗が打刻応答を覆さない）
  def notify_proxy_clocked(target, kind:, remedy:)
    Notifier.call(
      target_user: target, subject_user: current_user,
      priority: :informational, source_type: :proxy_clocked,
      title: "勤怠が代理で打刻されました",
      body: "#{current_user.name} さんがあなたの#{kind}を代理で打刻しました。" \
            "時刻が異なる場合は、#{remedy}。"
    )
  rescue StandardError => e
    Rails.logger.error(
      "[Notifier] producer 通知失敗 source_type=proxy_clocked user=#{target.id}: #{e.class}: #{e.message}"
    )
  end

  # 本人への通知（設計 §13② — 本人打刻時の「画面警告」の代替送達。flash は操作者にしか見えない）
  def notify_target_interval(target, record, interval)
    Notifier.call(
      target_user: target, subject_user: current_user,
      priority: :informational, source_type: :interval_shortage,
      title: "勤務間インターバル不足",
      body: "#{record.work_date} の出勤で勤務間インターバルが不足しています" \
            "（不足 #{interval.shortage_minutes} 分）。休息を確保してください。"
    )
  rescue StandardError => e
    Rails.logger.error(
      "[Notifier] producer 通知失敗 source_type=interval_shortage user=#{target.id}: #{e.class}: #{e.message}"
    )
  end

  def interval_warning(target, interval)
    return nil unless interval&.violation?

    t("proxy_clockings.interval_warning",
      name: target.name,
      threshold: current_user.organization.setting.rest_interval_hours,
      shortage: interval.shortage_minutes)
  end

  # 書込系 redirect は一律 see_other（Turbo 302 メソッド保持・RAILS_GOTCHAS）。
  # warning は成功時のみ alert に載せる（対象社員のインターバル警告 — 操作者向け）
  def redirect_with(result, success_message, warning: nil)
    if result.success?
      flash[:alert] = warning if warning
      redirect_to proxy_clockings_path, notice: success_message, status: :see_other
    else
      redirect_to proxy_clockings_path, alert: t("proxy_clockings.errors.#{result.error}"), status: :see_other
    end
  end
end
