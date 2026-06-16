# frozen_string_literal: true

module Admin
  # hr_admin 専用 残高 CRUD（Phase 2-2a 設計 §5/§6）。0b マスタと同じ MasterPolicy 継承
  class LeaveBalancePolicy < MasterPolicy
    # new?/edit? は基底に無いため明示（new→create?, edit→update? に委譲）
    def new? = create?
    def edit? = update?
  end
end
