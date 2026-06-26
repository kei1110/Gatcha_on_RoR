# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationDispatchTenantJob, type: :job do
  include ActiveJob::TestHelper

  let(:org) { create(:organization) }

  def delivery(status:, scheduled_at:, channel: :email, organization: org)
    ActsAsTenant.with_tenant(organization) do
      n = create(:notification)
      create(:notification_delivery, notification: n, status:, scheduled_at:, channel:)
    end
  end

  it "当該テナントの due な email pending のみ email job へ" do
    due = delivery(status: :pending, scheduled_at: 1.hour.ago)
    delivery(status: :pending, scheduled_at: 1.hour.from_now) # 未来 → 拾わない
    delivery(status: :sent, scheduled_at: 1.hour.ago)         # sent → 拾わない
    delivery(status: :error, scheduled_at: 1.hour.ago)        # error → 拾わない

    expect {
      described_class.perform_now(org.id)
    }.to have_enqueued_job(NotificationEmailJob)
      .with(organization_id: org.id, delivery_id: due.id)
      .exactly(1).times
  end

  it "他テナントの due pending を拾わない（クロステナント漏洩ゼロ・§3.6）" do
    other = create(:organization)
    delivery(status: :pending, scheduled_at: 1.hour.ago, organization: other)

    expect {
      described_class.perform_now(org.id)
    }.not_to have_enqueued_job(NotificationEmailJob)
  end
end
