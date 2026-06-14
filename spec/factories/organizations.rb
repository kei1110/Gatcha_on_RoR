# frozen_string_literal: true

FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Org #{n}" }
    sequence(:subdomain) { |n| "org#{n}" } # グローバル unique ゆえ sequence 必須
  end
end
