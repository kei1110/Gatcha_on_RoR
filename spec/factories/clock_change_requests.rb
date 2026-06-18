# frozen_string_literal: true

FactoryBot.define do
  factory :clock_change_request do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    requester { association(:user) }
    attendance_record { association(:attendance_record, :done, user: requester) }
    change_type { :clock_in }
    new_clock_in { Time.utc(2026, 6, 1, 1) }   # JST 10:00
    reason { "打刻修正のため" }
  end
end
