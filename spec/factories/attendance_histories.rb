FactoryBot.define do
  factory :attendance_history do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user
    actor { association(:user, :manager_role) }
    event_type { :proxy_clock }
    event_date { Date.new(2026, 6, 13) }
  end
end
