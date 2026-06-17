# frozen_string_literal: true

FactoryBot.define do
  factory :leave_balance do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user { association(:user) }
    leave_type { association(:leave_type) }   # 既定 system_type :other / paid_leave false
    fiscal_year { "2026" }
    granted_days { 20 }
    carry_over_days { 0 }
    used_days { 0 }
  end
end
