# frozen_string_literal: true

FactoryBot.define do
  factory :monthly_attendance_summary do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user
    year_month { "2026-03" }
  end
end
