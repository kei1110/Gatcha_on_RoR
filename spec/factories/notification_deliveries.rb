# frozen_string_literal: true

FactoryBot.define do
  factory :notification_delivery do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    notification { association(:notification) }
    channel { :email }
    scheduled_at { Time.current }
    status { :pending }
    retry_count { 0 }
  end
end
