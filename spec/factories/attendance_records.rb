FactoryBot.define do
  factory :attendance_record do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user
    work_date { Date.new(2026, 6, 1) }
    clock_in { Time.utc(2026, 6, 1, 0) } # JST 09:00（unique [user_id, work_date] — 同一 user の複数行は work_date を明示すること）
    status { :working }

    trait :done do
      status { :clocked_out }
      clock_out { clock_in + 9.hours }
    end
  end
end
