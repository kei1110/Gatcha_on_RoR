# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationDispatchJob, type: :job do
  include ActiveJob::TestHelper

  it "active org ごとに子ジョブを 1 件 enqueue（inactive は除外・§9⑩）" do
    org_a = create(:organization)
    org_b = create(:organization)
    inactive = create(:organization, active: false) # inactive → 除外

    # spec/support/tenant.rb の before(:each) が test_tenant を追加するため
    # 期待 enqueue 数は動的に取得（既存 active 数 = test_tenant + org_a + org_b）
    expected_count = Organization.active.count

    expect {
      described_class.perform_now
    }.to have_enqueued_job(NotificationDispatchTenantJob).exactly(expected_count).times

    expect(NotificationDispatchTenantJob).to have_been_enqueued.with(org_a.id)
    expect(NotificationDispatchTenantJob).to have_been_enqueued.with(org_b.id)
    expect(NotificationDispatchTenantJob).not_to have_been_enqueued.with(inactive.id)
  end
end
