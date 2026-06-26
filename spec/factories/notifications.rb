# frozen_string_literal: true

FactoryBot.define do
  factory :notification do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    target_user { association(:user) }
    subject_user { nil }
    title { "申請が承認されました" }
    body { "あなたの休暇申請が承認されました。" }
    priority { :informational }
    source_type { :request_approved }
  end
end
