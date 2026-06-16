# frozen_string_literal: true

module Admin
  # hr_admin 専用 残高 CRUD（Phase 2-2a 設計 §5/§6）。0b マスタと同じ MasterPolicy 継承。
  # new?/edit? は ApplicationPolicy 既定（create?/update? へ委譲）を継承するため明示不要
  class LeaveBalancePolicy < MasterPolicy
  end
end
