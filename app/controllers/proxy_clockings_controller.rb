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
    redirect_with(
      Clockings::ProxyClockIn.call(operator: current_user, target_user: target, reason: params[:proxy_clock_reason]),
      t(".success")
    )
  end

  def clock_out
    authorize :proxy_clocking, :clock_out?
    target = roster.find(params[:id])
    redirect_with(
      Clockings::ProxyClockOut.call(operator: current_user, target_user: target, reason: params[:proxy_clock_reason]),
      t(".success")
    )
  end

  private

  # policy_scope(User) 単独は top-level UserPolicy 不在で NotDefinedError ゆえ
  # policy_scope_class を明示（§R・§5 設計）。verify_policy_scoped も満たす
  def roster = policy_scope(User, policy_scope_class: ProxyClockingPolicy::Scope)

  # 書込系 redirect は一律 see_other（Turbo 302 メソッド保持・RAILS_GOTCHAS）
  def redirect_with(result, success_message)
    if result.success?
      redirect_to proxy_clockings_path, notice: success_message, status: :see_other
    else
      redirect_to proxy_clockings_path, alert: t("proxy_clockings.errors.#{result.error}"), status: :see_other
    end
  end
end
