# frozen_string_literal: true

FactoryBot.define do
  factory :approval_assignment do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    approver { association(:user) }
    position { 1 }
    purpose { :approval }
    decision { :pending }
    acted_at { nil }

    # acted_at_consistency_with_decision: pending でない決裁には acted_at 必須・pending は nil 必須。
    # テスト側が decision: :approved 等を渡した際に acted_at を自動補完する。
    after(:build) do |aa|
      if aa.decision.to_s != "pending" && aa.acted_at.nil?
        aa.acted_at = Time.current
      end
    end
  end
end
