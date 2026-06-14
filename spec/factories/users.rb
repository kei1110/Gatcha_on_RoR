# frozen_string_literal: true

FactoryBot.define do
  factory :user do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:employee_code) { |n| "E#{format('%03d', n)}" }
    name { "テスト 太郎" }
    password { "password123!" }
    role { :employee }

    trait :manager_role do
      role { :manager }
    end

    trait :hr_admin do
      role { :hr_admin }
    end
  end
end
