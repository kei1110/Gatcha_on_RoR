# frozen_string_literal: true

# 欠勤確定の取消 headless policy（`authorize :absence_cancellation, :create?`・AbsenceConfirmationPolicy 同型）。
# 認可は二層: ① role ゲート（本 policy）② 対象ゲート（controller の policy_scope.find → 404）。
class AbsenceCancellationPolicy < ApplicationPolicy
  def create? = manager_or_admin?

  # 取消対象社員のロスター（over User）。AbsenceConfirmationPolicy::Scope と違い **active で絞らない** —
  # 取消は過去の確定を直す操作で、対象が退職・無効化済みでも直せなければならない（設計 §4.6）。
  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.hr_admin?
        scope.where(organization_id: user.organization_id)
      elsif user.manager?
        scope.where(organization_id: user.organization_id, manager_id: user.id)
      else
        scope.none
      end
    end
  end

  private

  def manager_or_admin? = user.manager? || user.hr_admin?
end
