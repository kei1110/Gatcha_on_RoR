# frozen_string_literal: true

FactoryBot.define do
  factory :company_calendar do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    sequence(:date) { |n| Date.new(2026, 1, 1) + n } # テナント内 unique ゆえ sequence 必須
    day_type { :holiday }
    name { "祝日" } # holiday は name 必須
  end
end
