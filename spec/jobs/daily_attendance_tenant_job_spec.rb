# frozen_string_literal: true

require "rails_helper"

RSpec.describe DailyAttendanceTenantJob, type: :job do
  it "with_tenant(org) 内で Detect.call(date: org.today.prev_day) を呼ぶ" do
    org = create(:organization)

    expect(AttendanceAnomalies::Detect).to receive(:call) do |date:|
      expect(date).to eq(org.today.prev_day)
      expect(ActsAsTenant.current_tenant).to eq(org) # §3.6 テナント文脈内
    end

    described_class.perform_now(org.id)
  end

  it "org 削除済み（nil）なら何もしない（§11⑪ 削除レース耐性）" do
    expect(AttendanceAnomalies::Detect).not_to receive(:call)
    expect { described_class.perform_now(-1) }.not_to raise_error
  end
end
