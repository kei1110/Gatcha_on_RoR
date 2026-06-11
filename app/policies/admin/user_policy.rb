module Admin
  class UserPolicy < ApplicationPolicy
    def index? = hr_admin?
    def show? = hr_admin?
    def create? = hr_admin?
    def update? = hr_admin?
    def deactivate? = hr_admin?
    def activate? = hr_admin?

    # sign_in_count == 0 を「未受諾」とみなす判定は sign_in_after_reset_password
    # 既定 true（受諾＝初回サインイン）に依存する（0b-1 設計 §2-5）
    def resend_invitation? = hr_admin? && record.sign_in_count.zero? && record.active?

    class Scope < ApplicationPolicy::Scope
      # 組織全員。inactive を含む（再有効化・招待再送 UI の前提 — 絞ると UI が壊れる）。
      # organization_id を明示 — without_tenant 文脈で呼ばれても全テナント横断にしない
      # （default scope に加えた明示防衛・user.rb の規約と同型）
      def resolve = scope.where(organization_id: user.organization_id)
    end

    private

    def hr_admin? = user.hr_admin?
  end
end
