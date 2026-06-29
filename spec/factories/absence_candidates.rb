# frozen_string_literal: true

FactoryBot.define do
  factory :absence_candidate do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user { association(:user) }
    target_date { Date.new(2026, 5, 1) }
    notified_on { nil }
  end
end
