# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ApprovalAssignments", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:hr)      { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:dept)    { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: hr) } }
  let!(:boss)    { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: dept) } }
  let!(:emp)     { ActsAsTenant.with_tenant(org) { create(:user, manager: boss) } }   # route: [boss, dept]
  let!(:leave_type) { ActsAsTenant.with_tenant(org) { create(:leave_type, paid_leave: false) } }

  # emp の休暇申請を 1 件起票（承認エンジン起動済）
  let!(:leave) do
    ActsAsTenant.with_tenant(org) do
      LeaveRequests::Create.call(requester: emp, leave_type:, start_date: Date.new(2026, 5, 1),
                                 end_date: Date.new(2026, 5, 1), half_day_type: "none", reason: "私用")
    end
  end
  def assignment_for(position) = ActsAsTenant.with_tenant(org) { leave.approval_assignments.find_by(position:) }

  describe "GET index" do
    it "現段階の担当者には actionable な assignment を表示" do
      sign_in boss
      get approval_assignments_url(host: tenant_host(org))
      expect(response.body).to include(emp.name)
    end

    it "現段階でない担当者（dept）には何も出さない" do
      sign_in dept
      get approval_assignments_url(host: tenant_host(org))
      expect(response.body).not_to include(emp.name)
    end
  end

  describe "PATCH approve（一周）" do
    it "承認で AR 作成・残高消費なし（非 paid）・履歴記録・status approved" do
      sign_in boss
      patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org))
      sign_in dept
      patch approve_approval_assignment_url(assignment_for(2), host: tenant_host(org))

      ActsAsTenant.with_tenant(org) do
        expect(leave.reload.approval_status).to eq("approved")
        expect(AttendanceRecord.find_by(user: emp, work_date: Date.new(2026, 5, 1)).status).to eq("on_leave")
        expect(AttendanceHistory.where(event_type: :leave_approved).count).to eq(1)
      end
    end

    it "他テナント/他人の assignment は 404" do
      sign_in dept
      patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org))  # stage1 は boss 担当
      expect(response).to have_http_status(:not_found)
    end

    it "別 organization（他テナント）の assignment は acts_as_tenant default_scope で 404" do
      other_org = create(:organization)
      other_leave = ActsAsTenant.with_tenant(other_org) do
        lt   = create(:leave_type, paid_leave: false)
        mgr  = create(:user, :manager_role)
        emp2 = create(:user, manager: mgr)
        LeaveRequests::Create.call(requester: emp2, leave_type: lt,
                                   start_date: Date.new(2026, 5, 6),
                                   end_date: Date.new(2026, 5, 6),
                                   half_day_type: "none", reason: "他社テスト")
      end
      other_asgn = ActsAsTenant.with_tenant(other_org) { other_leave.approval_assignments.first }

      sign_in boss
      patch approve_approval_assignment_url(other_asgn, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH approve（over-balance ハード拒否）" do
    let!(:paid_type) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :annual, paid_leave: true) } }
    let!(:paid_leave) do
      ActsAsTenant.with_tenant(org) do
        LeaveRequests::Create.call(requester: emp, leave_type: paid_type, start_date: Date.new(2026, 5, 1),
                                   end_date: Date.new(2026, 5, 1), half_day_type: "none", reason: "有給")
      end
    end
    def paid_assignment(pos) = ActsAsTenant.with_tenant(org) { paid_leave.approval_assignments.find_by(position: pos) }

    it "残高ゼロの paid を最終承認すると alert + DB 無変化（status は applying のまま）" do
      sign_in boss
      patch approve_approval_assignment_url(paid_assignment(1), host: tenant_host(org))
      sign_in dept
      patch approve_approval_assignment_url(paid_assignment(2), host: tenant_host(org))

      ActsAsTenant.with_tenant(org) do
        expect(paid_leave.reload.approval_status).to eq("applying")   # rollback で未確定
        expect(AttendanceRecord.where(user: emp).count).to eq(0)
        expect(AttendanceHistory.where(event_type: :leave_approved).count).to eq(0)
        expect(paid_assignment(2).decision).to eq("pending")          # assignment も巻き戻る
        expect(LeaveBalance.count).to eq(0)                           # rollback で balance 行も未作成
      end
      follow_redirect!
      expect(response.body).to include("残高不足")
    end
  end

  describe "PATCH reject" do
    it "理由付き却下で rejected" do
      sign_in boss
      patch reject_approval_assignment_url(assignment_for(1), host: tenant_host(org)),
            params: { comment: "今回は見送り" }
      ActsAsTenant.with_tenant(org) { expect(leave.reload.approval_status).to eq("rejected") }
    end

    it "理由無しの却下は alert（rejected にしない）" do
      sign_in boss
      patch reject_approval_assignment_url(assignment_for(1), host: tenant_host(org)), params: { comment: "" }
      ActsAsTenant.with_tenant(org) { expect(leave.reload.approval_status).to eq("applying") }
    end
  end
end
