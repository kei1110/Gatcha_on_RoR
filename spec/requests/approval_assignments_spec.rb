# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ApprovalAssignments", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:hr)      { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:dept)    { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: hr) } }
  let!(:boss)    { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: dept) } }
  # name は factory デフォルト（"テスト 太郎"）と衝突させない — グローバルナビが current_user.name を
  # 全画面表示するため、emp.name が承認者の名と同名だと not_to include(emp.name) が誤発火する
  let!(:emp)     { ActsAsTenant.with_tenant(org) { create(:user, manager: boss, name: "申請 太郎") } } # route: [boss, dept]
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

  describe "CCR（打刻変更）の承認（2-3）" do
    let!(:ccr_record) do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, :done, user: emp, work_date: Date.new(2026, 6, 1),
               clock_in: Time.utc(2026, 6, 1, 1), clock_out: Time.utc(2026, 6, 1, 9),
               work_pattern: create(:work_pattern))
      end
    end
    let!(:ccr) do
      ActsAsTenant.with_tenant(org) do
        ClockChangeRequests::Create.call(requester: emp, attendance_record: ccr_record,
                                         change_type: "clock_in", new_clock_in: Time.utc(2026, 6, 1, 0),
                                         new_clock_out: nil, reason: "修正")
      end
    end
    def ccr_assignment(pos) = ActsAsTenant.with_tenant(org) { ccr.approval_assignments.find_by(position: pos) }

    it "インボックスに CCR 行が型別描画される" do
      sign_in boss
      get approval_assignments_url(host: tenant_host(org))
      expect(response.body).to include("打刻変更")
    end

    it "承認で記録時刻更新 + 履歴記録（一周）" do
      sign_in boss
      patch approve_approval_assignment_url(ccr_assignment(1), host: tenant_host(org))
      sign_in dept
      patch approve_approval_assignment_url(ccr_assignment(2), host: tenant_host(org))
      ActsAsTenant.with_tenant(org) do
        expect(ccr_record.reload.clock_in).to eq(Time.utc(2026, 6, 1, 0))
        expect(AttendanceHistory.where(event_type: :clock_change_approved).count).to eq(1)
      end
    end

    it "競合（申請後に記録変更）承認で alert + DB 無変化" do
      sign_in boss
      patch approve_approval_assignment_url(ccr_assignment(1), host: tenant_host(org))
      ActsAsTenant.with_tenant(org) { ccr_record.update_column(:clock_in, Time.utc(2026, 6, 1, 2)) }
      sign_in dept
      patch approve_approval_assignment_url(ccr_assignment(2), host: tenant_host(org))
      ActsAsTenant.with_tenant(org) do
        expect(ccr.reload.approval_status).to eq("applying")           # rollback
        expect(ccr_record.reload.clock_in).to eq(Time.utc(2026, 6, 1, 2))
        expect(AttendanceHistory.where(event_type: :clock_change_approved).count).to eq(0)
      end
      follow_redirect!
      expect(response.body).to include("一致しません")
    end
  end

  describe "PATCH approve（締め由来 ClosingLockedError 分岐・3-2）" do
    it "締め済み月の承認は締め由来の flash を出す（ClosingLockedError）" do
      ActsAsTenant.with_tenant(org) do
        create(:monthly_attendance_summary, user: emp, year_month: "2026-05", status: :submitted)
      end
      sign_in boss
      patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org))
      follow_redirect!
      expect(response.body).to include("締め済み")
    end
  end

  describe "HolidayWorkRequest の承認（2-4）" do
    let(:org) { create(:organization) }
    let(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, organization: org) } }
    let(:requester) { ActsAsTenant.with_tenant(org) { create(:user, organization: org, manager:) } }
    let(:comp) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :compensatory_leave, organization: org) } }
    let(:hwr) do
      ActsAsTenant.with_tenant(org) do
        HolidayWorkRequests::Create.call(requester:, work_date: Date.new(2026, 6, 7),
                                         compensation_leave_type: comp, reason: "x")
      end
    end

    before do
      host! "#{org.subdomain}.example.com"
      sign_in manager
    end

    it "インボックスに HWR 行が出る" do
      hwr
      get approval_assignments_path
      expect(response.body).to include("休日出勤").and include(requester.name)
    end

    it "承認すると代休残高が +1 される" do
      assignment = ActsAsTenant.with_tenant(org) do
        hwr.approval_assignments.find_by(position: hwr.current_approval_position)
      end
      patch approve_approval_assignment_path(assignment)
      balance = ActsAsTenant.with_tenant(org) do
        LeaveBalance.find_by(user: requester, leave_type: comp, fiscal_year: org.fiscal_year_for(Date.new(2026, 6, 7)))
      end
      expect(balance.granted_days).to eq(1)
    end
  end

  describe "producer 接続（承認/却下 → requester 通知・§5.4）" do
    include ActiveJob::TestHelper

    # 正例の broadcast は .at_least(:once)：Notifier.call は同一 stream に prepend + 件数 replace の
    # 2 件を broadcast するため（既定の have_broadcasted_to は exactly 1 を期待）。不発火の判別は
    # 負例 not_to have_broadcasted_to が担う。
    it "終端承認（全段）で requester に request_approved 通知 + broadcast" do
      sign_in boss
      patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org)) # 中間（pos1）
      sign_in dept
      expect {
        patch approve_approval_assignment_url(assignment_for(2), host: tenant_host(org)) # 終端（pos2）
      }.to have_broadcasted_to(emp.to_gid_param).at_least(:once)
      ActsAsTenant.with_tenant(org) do
        n = Notification.where(target_user: emp, source_type: :request_approved)
        expect(n.count).to eq(1)
        expect(n.first.priority).to eq("informational")
        expect(n.first.subject_user_id).to eq(emp.id)
      end
    end

    it "中間段階（pos1 のみ承認・applying）では通知ゼロ" do
      sign_in boss
      expect {
        patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org))
      }.not_to have_broadcasted_to(emp.to_gid_param)
      ActsAsTenant.with_tenant(org) do
        expect(leave.reload.approval_status).to eq("applying")
        expect(Notification.where(target_user: emp).count).to eq(0)
      end
    end

    it "却下で requester に request_rejected 通知" do
      sign_in boss
      expect {
        patch reject_approval_assignment_url(assignment_for(1), host: tenant_host(org), params: { comment: "却下理由" })
      }.to have_broadcasted_to(emp.to_gid_param).at_least(:once)
      ActsAsTenant.with_tenant(org) do
        expect(leave.reload.approval_status).to eq("rejected")
        n = Notification.where(target_user: emp, source_type: :request_rejected)
        expect(n.count).to eq(1)
        expect(n.first.priority).to eq("informational")
      end
    end

    it "通知失敗は承認の成功応答を覆さない（§9.5 ログのみ・rescue 反転防止）" do
      # Notifier が RecordInvalid を投げても、approve の rescue ActiveRecord::RecordInvalid に
      # 落ちて「承認できませんでした」と反転しないこと（承認 tx は既に commit 済）。
      allow(Notifier).to receive(:call).and_raise(ActiveRecord::RecordInvalid) # 承認 rescue が掴む種類
      sign_in boss
      patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org))
      sign_in dept
      patch approve_approval_assignment_url(assignment_for(2), host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(flash[:notice]).to eq("承認しました") # 反転していない
      expect(flash[:alert]).to be_nil
      expect(ActsAsTenant.with_tenant(org) { leave.reload.approval_status }).to eq("approved") # 承認は commit 済
    end
  end

  describe "producer の幻通知防止（over-balance rollback・§9③）" do
    let!(:paid_type) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :annual, paid_leave: true) } }
    let!(:paid_leave) do
      ActsAsTenant.with_tenant(org) do
        LeaveRequests::Create.call(requester: emp, leave_type: paid_type, start_date: Date.new(2026, 5, 1),
                                   end_date: Date.new(2026, 5, 1), half_day_type: "none", reason: "有給")
      end
    end
    def paid_assignment(pos) = ActsAsTenant.with_tenant(org) { paid_leave.approval_assignments.find_by(position: pos) }

    it "残高ゼロの最終承認は rollback → Notification 0 件・broadcast 0 件（幻ベルなし）" do
      sign_in boss
      patch approve_approval_assignment_url(paid_assignment(1), host: tenant_host(org))
      sign_in dept
      expect {
        patch approve_approval_assignment_url(paid_assignment(2), host: tenant_host(org)) # OverBalanceError → rollback
      }.not_to have_broadcasted_to(emp.to_gid_param)
      ActsAsTenant.with_tenant(org) do
        expect(paid_leave.reload.approval_status).to eq("applying") # rollback で applying のまま
        expect(Notification.where(target_user: emp).count).to eq(0)
      end
    end
  end
end
