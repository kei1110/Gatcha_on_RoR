# frozen_string_literal: true

FactoryBot.define do
  factory :holiday_work_request do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    requester { association(:user) }
    compensation_leave_type do
      association(:leave_type, system_type: :compensatory_leave, organization:)
    end
    work_date { Date.new(2026, 6, 7) } # 日曜（ISO フォールバックで :sunday＝平日以外）
    reason { "休日対応のため" }
  end
end
