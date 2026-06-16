# frozen_string_literal: true

FactoryBot.define do
  factory :leave_request do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    requester { association(:user) }
    leave_type { association(:leave_type) }
    start_date { Date.new(2026, 5, 1) }
    end_date { Date.new(2026, 5, 1) }
    half_day_type { :none }
    days_requested { 1 }
  end
end
