# frozen_string_literal: true

FactoryBot.define do
  factory :reason_template do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    sequence(:label) { |n| "テンプレート#{n}" } # テナント内 unique ゆえ sequence
    template_text { "テンプレート本文" }
    applies_to { :both }
  end
end
