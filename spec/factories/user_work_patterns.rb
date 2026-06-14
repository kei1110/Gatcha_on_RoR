# frozen_string_literal: true

FactoryBot.define do
  factory :user_work_pattern do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user
    work_pattern
    start_date { Date.new(2026, 4, 1) }
  end
end
