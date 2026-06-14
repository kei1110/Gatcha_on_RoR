# frozen_string_literal: true

module Admin
  # 素の CRUD マスタ専用基底（0b-2 設計 §0 — UserPolicy は招待条件があるため継承しない。
  # 0b-3 CompanyCalendar=import あり・0b-5 OrganizationSetting=singleton の異型は
  # この基底に押し込めず個別に判断する）
  class MasterPolicy < ApplicationPolicy
    def index? = hr_admin?
    def show? = hr_admin?
    def create? = hr_admin?
    def update? = hr_admin?
    def deactivate? = hr_admin?
    def activate? = hr_admin?

    class Scope < ApplicationPolicy::Scope
      # 組織のマスタ全件（inactive 含む — 再有効化 UI の前提）。
      # organization_id 明示 = without_tenant 文脈の fail-open 遮断（user_policy と同型の二重防衛）
      def resolve = scope.where(organization_id: user.organization_id)
    end

    private

    def hr_admin? = user.hr_admin?
  end
end
