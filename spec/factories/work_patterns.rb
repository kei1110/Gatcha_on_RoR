FactoryBot.define do
  factory :work_pattern do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    sequence(:name) { |n| "日勤#{n}" }
    start_time { "09:00" }
    end_time { "18:00" }
    break_minutes { 60 }
    standard_work_hours { 8 }
  end
end
