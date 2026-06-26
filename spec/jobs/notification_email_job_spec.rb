# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationEmailJob, type: :job do
  include ActiveJob::TestHelper

  let(:org) { create(:organization, subdomain: "acme") }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user, email: "u@example.com") } }
  let(:notification) { ActsAsTenant.with_tenant(org) { create(:notification, target_user: user) } }
  let(:delivery) do
    ActsAsTenant.with_tenant(org) { create(:notification_delivery, notification:, status: :pending) }
  end

  before { ActionMailer::Base.deliveries.clear }

  it "pending を送信し status: sent にする（テナント再確立）" do
    expect {
      described_class.perform_now(organization_id: org.id, delivery_id: delivery.id)
    }.to change { ActionMailer::Base.deliveries.size }.by(1)
    expect(delivery.reload).to be_sent
    expect(delivery.retry_count).to eq(0)
  end

  it "sent 済は二重送信しない（冪等）" do
    ActsAsTenant.with_tenant(org) { delivery.update!(status: :sent) }
    expect {
      described_class.perform_now(organization_id: org.id, delivery_id: delivery.id)
    }.not_to change { ActionMailer::Base.deliveries.size }
    expect(delivery.reload).to be_sent # error に落ちていない
  end

  it "削除済み delivery は無視（早期 return）" do
    missing_id = delivery.id
    ActsAsTenant.with_tenant(org) { delivery.destroy! }
    expect {
      described_class.perform_now(organization_id: org.id, delivery_id: missing_id)
    }.not_to change { ActionMailer::Base.deliveries.size }
  end

  it "transient 失敗はリトライされ、回復すれば最終的に送信される" do
    call_count = 0
    allow(NotificationMailer).to receive(:notify) do
      call_count += 1
      raise Net::OpenTimeout if call_count == 1 # 初回だけ失敗

      instance_double(ActionMailer::MessageDelivery, deliver_now: true) # リトライは成功
    end
    perform_enqueued_jobs do
      described_class.perform_later(organization_id: org.id, delivery_id: delivery.id)
    end
    expect(call_count).to be >= 2          # 再試行された
    expect(delivery.reload).to be_sent     # 最終的に成功
    expect(delivery.retry_count).to be >= 1 # retry_count ミラーが再試行回数を反映
  end

  it "リトライ枯渇で status: error 確定（executions ミラー）" do
    allow(NotificationMailer).to receive(:notify).and_raise(Net::OpenTimeout)
    perform_enqueued_jobs do
      described_class.perform_later(organization_id: org.id, delivery_id: delivery.id)
    end
    expect(delivery.reload).to be_error
    expect(delivery.retry_count).to eq(described_class::MAX_ATTEMPTS - 1) # 3
  end
end
