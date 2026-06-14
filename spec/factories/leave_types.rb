# frozen_string_literal: true

FactoryBot.define do
  factory :leave_type do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    sequence(:name) { |n| "休暇種別#{n}" }
    system_type { :other }
  end
end
