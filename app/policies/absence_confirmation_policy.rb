# frozen_string_literal: true

# 欠勤確定の headless policy（`authorize :absence_confirmation, :index?` — ProxyClockingPolicy 同型）。
# 認可は二層: ① role ゲート（本 policy）② 対象ゲート（controller の policy_scope.find → 404）。
# 「対象が部下か」は Scope.find に委譲する（SPEC §3.4・設計 §12③）。
class AbsenceConfirmationPolicy < ApplicationPolicy
  def index?  = manager_or_admin?
  def create? = manager_or_admin?

  # 確定対象社員のロスター（over User）。ProxyClockingPolicy::Scope と違い **自分を除外しない** —
  # manager_id: nil の候補（トップ階層・hr_admin 自身）は hr_admin のみが確定できる必要がある（§12⑧）。
  # manager 側は「直属部下」条件が自分を自然に除外する（manager_id: 自分 ≠ 自分）。
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
      base.where(active: true) # 候補は User.active にしか生えない（4-2b）
    end
  end

  private

  def manager_or_admin? = user.manager? || user.hr_admin?
end
