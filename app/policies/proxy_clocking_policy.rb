# 代理打刻の headless policy（authorize :proxy_clocking, :clock_in? — ClockingPolicy 同型）。
# 認可は二層: ① role ゲート（本 policy）② 対象ゲート（controller の policy_scope.find→404）。
# clock_in?/clock_out? は record 非依存ゆえ「対象が部下か」は Scope.find に委譲（SPEC §3.4・§R-8）。
class ProxyClockingPolicy < ApplicationPolicy
  def index?     = manager_or_admin?
  def clock_in?  = manager_or_admin?
  def clock_out? = manager_or_admin?

  # ロスター = 代理打刻の対象集合。在籍者・自分除外（自分は通常打刻）。
  # organization_id 明示（without_tenant 文脈耐性・Admin::UserPolicy::Scope と同型）
  class Scope < ApplicationPolicy::Scope
    def resolve
      base =
        if user.hr_admin?
          scope.where(organization_id: user.organization_id)
        elsif user.manager?
          scope.where(organization_id: user.organization_id, manager_id: user.id)
        else
          scope.none
        end
      base.where(active: true).where.not(id: user.id)
    end
  end

  private

  def manager_or_admin? = user.manager? || user.hr_admin?
end
