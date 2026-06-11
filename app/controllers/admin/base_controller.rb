module Admin
  class BaseController < ApplicationController
    layout "admin"

    before_action :require_hr_admin

    private

    # 名前空間の外殻ガード（多層防御・0b-1 設計 §1）。authorize は呼ばない —
    # verify_authorized を満たした扱いにせず、各アクションのレコード authorize を強制し続ける
    def require_hr_admin
      raise Pundit::NotAuthorizedError, "hr_admin 専用領域" unless current_user&.hr_admin?
    end
  end
end
