# frozen_string_literal: true

require "rails_helper"

RSpec.describe "撤回フロー", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:hr)   { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:dept) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: hr) } }
  let!(:boss) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: dept) } }
  let!(:emp)  { ActsAsTenant.with_tenant(org) { create(:user, manager: boss) } }   # route: [boss, dept]
  let!(:leave_type) { ActsAsTenant.with_tenant(org) { create(:leave_type, paid_leave: false) } }

  # 承認済の休暇を用意（申請 → boss approve → dept approve）
  let!(:leave) do
    ActsAsTenant.with_tenant(org) do
      lr = LeaveRequests::Create.call(requester: emp, leave_type:, start_date: Date.new(2026, 5, 1),
                                      end_date: Date.new(2026, 5, 1), half_day_type: "none", reason: "私用")
      Approvals::Approve.call(approvable: lr, approver: boss)
      Approvals::Approve.call(approvable: lr, approver: dept)
      lr.reload
    end
  end

  it "撤回申請 → 2 段承認 → withdrawn + AR 復元（一周）" do
    sign_in emp
    patch request_withdrawal_leave_request_url(leave, host: tenant_host(org)),
          params: { leave_request: { withdrawal_reason: "誤申請" } }
    expect(ActsAsTenant.with_tenant(org) { leave.reload }).to be_withdrawal_requested

    w1, w1_approver = ActsAsTenant.with_tenant(org) do
      a = leave.approval_assignments.find_by(purpose: :withdrawal, position: 1)
      [ a, a.approver ]
    end
    sign_in w1_approver
    patch approve_approval_assignment_url(w1, host: tenant_host(org))
    w2, w2_approver = ActsAsTenant.with_tenant(org) do
      a = leave.approval_assignments.find_by(purpose: :withdrawal, position: 2)
      [ a, a.approver ]
    end
    sign_in w2_approver
    patch approve_approval_assignment_url(w2, host: tenant_host(org))

    expect(ActsAsTenant.with_tenant(org) { leave.reload }).to be_withdrawn
    expect(ActsAsTenant.with_tenant(org) { AttendanceRecord.find_by(user: emp, work_date: Date.new(2026, 5, 1)) }).to be_nil
  end

  it "撤回却下 → approved 復帰で履歴が二重化しない" do
    sign_in emp
    patch request_withdrawal_leave_request_url(leave, host: tenant_host(org)),
          params: { leave_request: { withdrawal_reason: "誤申請" } }
    w1, w1_approver = ActsAsTenant.with_tenant(org) do
      a = leave.approval_assignments.find_by(purpose: :withdrawal, position: 1)
      [ a, a.approver ]
    end
    sign_in w1_approver
    expect {
      patch reject_approval_assignment_url(w1, host: tenant_host(org)), params: { comment: "却下理由" }
    }.not_to change { ActsAsTenant.with_tenant(org) { AttendanceHistory.count } }
    expect(ActsAsTenant.with_tenant(org) { leave.reload }).to be_approved
  end

  it "他人の撤回申請は 404" do
    other = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in other
    patch request_withdrawal_leave_request_url(leave, host: tenant_host(org)),
          params: { leave_request: { withdrawal_reason: "x" } }
    expect(response).to have_http_status(:not_found)
  end
end
