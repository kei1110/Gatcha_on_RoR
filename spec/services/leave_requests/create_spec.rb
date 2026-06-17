# spec/services/leave_requests/create_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::Create do
  let(:org) { create(:organization, fiscal_year_end_month: 3) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  # 承認ルート: employee → 直属 manager → その manager（§7.2）。manager 必須
  let(:dept_head) { create(:user, :manager_role, organization: org) }
  let(:manager) { create(:user, :manager_role, organization: org, manager: dept_head) }
  let(:requester) { create(:user, organization: org, manager:) }
  let(:leave_type) { create(:leave_type) }

  def call(**over)
    described_class.call(
      requester:, leave_type:, start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 1), half_day_type: :none, reason: "私用", **over
    )
  end

  it "申請を作成し days_requested をサーバ確定・Start で assignment 生成" do
    record = call
    expect(record).to be_persisted
    expect(record.days_requested).to eq(BigDecimal("1"))   # 2026-05-01 は weekday
    expect(record.approval_assignments.count).to be >= 1
    expect(record.approval_status).to eq("applying")
  end

  it "全除外範囲（取得日数 0）は RecordInvalid・未永続" do
    expect {
      call(start_date: Date.new(2026, 5, 2), end_date: Date.new(2026, 5, 3))   # 土日
    }.to raise_error(ActiveRecord::RecordInvalid)
    expect(LeaveRequest.count).to eq(0)
  end

  describe "manager 未設定（RouteError ロールバック）" do
    let(:requester) { create(:user, organization: org, manager: nil) }

    it "host・assignment ともに未永続（count 双方不変）" do
      expect { call rescue nil }.not_to change { [ LeaveRequest.count, ApprovalAssignment.count ] }
      expect { call }.to raise_error(Approvals::RouteError)
    end
  end
end
