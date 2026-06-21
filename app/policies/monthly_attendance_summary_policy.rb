# frozen_string_literal: true

# 締めの認可（SPEC §6.6・§3.4・3-2 設計 §4.1）。
# 提出=本人 or hr_admin（代理・§4.1）／確定・差戻し=直属 manager or hr_admin。
# 注: SPEC §4.1 の「階層述語（例 subordinate_of?）」は未実装ゆえ ProxyClockingPolicy 同型の
# 直属 manager で action 述語と Scope を一致させる（多段は Phase 5 ダッシュボードまで YAGNI）。
class MonthlyAttendanceSummaryPolicy < ApplicationPolicy
  def index? = user.present?
  def show? = own? || manages? || user.hr_admin?
  def submit? = own? || user.hr_admin?
  def finalize? = manages? || user.hr_admin?
  def defer? = finalize?
  def bulk_finalize? = user.manager? || user.hr_admin? # class-level（対象は Scope 交差で固定）

  private

  def own? = record.user_id == user.id
  def manages? = record.user.manager_id == user.id

  class Scope < ApplicationPolicy::Scope
    # 自分 + 直属部下（§3.4・ProxyClockingPolicy 同型）。organization_id 明示（without_tenant 耐性）。
    def resolve
      if user.hr_admin?
        scope.where(organization_id: user.organization_id)
      else
        subordinate_ids = User.where(organization_id: user.organization_id, manager_id: user.id).select(:id)
        scope.where(organization_id: user.organization_id, user_id: subordinate_ids)
             .or(scope.where(organization_id: user.organization_id, user_id: user.id))
      end
    end
  end
end
