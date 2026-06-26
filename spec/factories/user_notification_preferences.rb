# frozen_string_literal: true

FactoryBot.define do
  factory :user_notification_preference do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user { association(:user) }
    quiet_hours_enabled { true }
    quiet_hours_start { 19 }
    quiet_hours_end { 8 }
    holiday_block_enabled { true }
  end
end
