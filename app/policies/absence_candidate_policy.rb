# frozen_string_literal: true

# 欠勤候補の可視範囲と却下(dismiss)の認可（設計 §5.1・§12③）。
# MonthlyAttendanceSummaryPolicy::Scope 同型だが **manager に自分の候補は見せない**（部下のみ）。
# hr_admin は組織全体（自身の候補を含む・§12⑧）。organization_id 明示（without_tenant 耐性）。
class AbsenceCandidatePolicy < ApplicationPolicy
  # 却下＝候補 destroy（監査に残さない ephemeral・§11④）。対象ゲートは Scope.find が担う
  def destroy? = user.manager? || user.hr_admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.hr_admin?
        scope.where(organization_id: user.organization_id)
      elsif user.manager?
        subordinate_ids = User.where(organization_id: user.organization_id, manager_id: user.id).select(:id)
        scope.where(organization_id: user.organization_id, user_id: subordinate_ids)
      else
        scope.none
      end
    end
  end
end
