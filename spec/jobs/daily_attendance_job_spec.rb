# frozen_string_literal: true

require "rails_helper"

RSpec.describe DailyAttendanceJob, type: :job do
  include ActiveJob::TestHelper

  it "active org ごとに子ジョブを 1 件 enqueue（inactive は除外・§3.6）" do
    org_a = create(:organization)
    org_b = create(:organization)
    inactive = create(:organization, active: false)

    # spec/support/tenant.rb の before が test_tenant を追加するため期待数は動的取得
    expected_count = Organization.active.count

    expect { described_class.perform_now }
      .to have_enqueued_job(DailyAttendanceTenantJob).exactly(expected_count).times

    expect(DailyAttendanceTenantJob).to have_been_enqueued.with(org_a.id)
    expect(DailyAttendanceTenantJob).to have_been_enqueued.with(org_b.id)
    expect(DailyAttendanceTenantJob).not_to have_been_enqueued.with(inactive.id)
  end
end
