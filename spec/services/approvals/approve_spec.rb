# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::Approve do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:dept) { create(:user, :manager_role, organization: org, manager: hr) }
  let(:boss) { create(:user, :manager_role, organization: org, manager: dept) }
  let(:emp)  { create(:user, organization: org, manager: boss) }     # route: [boss, dept]
  let(:host) { ApprovalTestRecord.create!(requester: emp).tap { |h| Approvals::Start.call(h) } }

  def approve(approver:, **kw) = described_class.call(approvable: host, approver:, **kw)

  describe "段階進行" do
    it "stage1 承認後も applying を維持（premature approve! を撃たない）" do
      approve(approver: boss)
      expect(host.reload).to be_applying
      expect(host.approval_assignments.find_by(position: 1).decision).to eq("approved")
    end

    it "最終段階の承認で approved になる" do
      approve(approver: boss)
      approve(approver: dept)
      expect(host.reload).to be_approved
    end

    it "単段ルートは 1 回の承認で approved" do
      top = create(:user, :manager_role, organization: org)
      solo = create(:user, organization: org, manager: top)
      h = ApprovalTestRecord.create!(requester: solo).tap { |x| Approvals::Start.call(x) }
      described_class.call(approvable: h, approver: top)
      expect(h.reload).to be_approved
    end
  end

  describe "自己承認防止" do
    it "#1 直接: approver が requester 本人なら SelfApprovalError" do
      # emp 自身を stage1 approver に差し替えて検証
      host.approval_assignments.find_by(position: 1).update_column(:approver_id, emp.id)
      expect { approve(approver: emp) }.to raise_error(Approvals::SelfApprovalError)
    end

    it "#2 代理: acting_user が requester なら SelfApprovalError" do
      # acting_user pin を外すため approver は正当な boss、acting_user に requester を渡す → まず pin で弾く前に
      # pin より自己承認を優先したくないので、ここは acting_user==approver の正当系に requester を混ぜない。
      # 代理の自己承認は pin 解除後（§7.5）の経路ゆえ、2-1 では #2 は pin で到達不能であることを下の pin テストで担保する。
      skip "2-1 は acting_user==approver を pin。#2 単独は §7.5 で検証"
    end

    it "代理 pin: acting_user != approver は ProxyNotSupported" do
      expect { approve(approver: boss, acting_user: dept) }.to raise_error(Approvals::ProxyNotSupported)
    end
  end

  describe "段階順序 / 現段階担当" do
    it "現段階でない承認者は NotCurrentApprover" do
      expect { approve(approver: dept) }.to raise_error(Approvals::NotCurrentApprover) # stage2 を先に
    end

    it "第三者は NotCurrentApprover" do
      stranger = create(:user, :manager_role, organization: org)
      expect { approve(approver: stranger) }.to raise_error(Approvals::NotCurrentApprover)
    end
  end

  describe "terminal / 残 pending バイパス防止" do
    it "却下後の残 pending を approve しても applying? ガードで弾く" do
      Approvals::Reject.call(approvable: host, approver: boss, comment: "却下")
      expect(host.reload).to be_rejected
      expect { approve(approver: dept) }.to raise_error(AASM::InvalidTransition)
      expect(host.approval_assignments.find_by(position: 2).decision).to eq("pending") # 黙って approved にしない
    end

    it "同一 assignment の二重承認は 2 回目で弾く（冪等）" do
      approve(approver: boss)
      expect { approve(approver: boss) }.to raise_error(Approvals::NotCurrentApprover)
    end
  end

  describe "副作用 hook（2-2b）" do
    it "最終承認時のみ apply_approval_effects! を撃つ（acting_user 付き）" do
      approve(approver: boss) # stage1（非最終）— 撃たない
      expect(host).to receive(:apply_approval_effects!).with(acting_user: dept).once
      approve(approver: dept) # stage2（最終）
    end

    it "非最終段階（stage1）では撃たない" do
      expect(host).not_to receive(:apply_approval_effects!)
      approve(approver: boss)
    end

    it "単段ルートは 1 回の承認で撃つ" do
      top = create(:user, :manager_role, organization: org)
      solo = create(:user, organization: org, manager: top)
      h = ApprovalTestRecord.create!(requester: solo).tap { |x| Approvals::Start.call(x) }
      expect(h).to receive(:apply_approval_effects!).with(acting_user: top).once
      described_class.call(approvable: h, approver: top)
    end
  end

  describe "締め再チェック（§6.6・Approach A・3-2）" do
    let(:approver) { create(:user, :manager_role, organization: org) } # トップ（manager 無し→単段ルート）
    let(:requester) { create(:user, organization: org, manager: approver) }

    context "LeaveRequest（LR）" do
      let(:lt) { create(:leave_type, organization: org) } # paid_leave: false → balance 追跡なし
      let(:lr) do
        LeaveRequests::Create.call(
          requester:, leave_type: lt,
          start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1),
          half_day_type: :none, reason: "締め再チェック検証"
        )
      end

      it "対象月が submitted なら ClosingLockedError（ConflictError サブクラス）" do
        lr # LR 作成（ロック前）
        create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :submitted)
        expect {
          Approvals::Approve.call(approvable: lr, approver:)
        }.to raise_error(Approvals::ClosingLockedError)
        expect(Approvals::ClosingLockedError.ancestors).to include(Approvals::ConflictError)
      end

      it "unlocked なら approve は正常進行（guard が常時 raise でない）" do
        expect { Approvals::Approve.call(approvable: lr, approver:) }.not_to raise_error
      end
    end

    context "ClockChangeRequest（CCR）" do
      let(:ar) do
        create(:attendance_record, :done, user: requester, organization: org,
               work_date: Date.new(2026, 5, 1),
               clock_in: Time.utc(2026, 5, 1, 0), clock_out: Time.utc(2026, 5, 1, 9))
      end
      let(:ccr) do
        ClockChangeRequests::Create.call(
          requester:, attendance_record: ar, change_type: :clock_in,
          new_clock_in: Time.utc(2026, 5, 1, 0, 30), new_clock_out: nil, reason: "修正"
        )
      end

      it "対象月が submitted なら ClosingLockedError" do
        ccr # CCR 作成（ロック前）
        create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :submitted)
        expect {
          Approvals::Approve.call(approvable: ccr, approver:)
        }.to raise_error(Approvals::ClosingLockedError)
      end
    end

    context "HolidayWorkRequest（HWR）" do
      let(:comp_lt) { create(:leave_type, organization: org, system_type: :compensatory_leave) }
      let(:hwr) do
        HolidayWorkRequests::Create.call(
          requester:, work_date: Date.new(2026, 5, 3), # 日曜
          compensation_leave_type: comp_lt, reason: "休日対応"
        )
      end

      it "対象月が submitted なら ClosingLockedError" do
        hwr # HWR 作成（ロック前）
        create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :submitted)
        expect {
          Approvals::Approve.call(approvable: hwr, approver:)
        }.to raise_error(Approvals::ClosingLockedError)
      end
    end
  end

  describe "撤回承認の撃ち分け（2-5）" do
    let(:requester) { emp }
    let(:approver1) { boss }
    let(:wh) { WithdrawalTestRecord.create!(requester:, approval_status: :withdrawal_requested, withdrawal_reason: "誤申請") }

    it "撤回世代を全段 approve すると withdrawn（approve_withdrawal を撃つ）" do
      wh.approval_assignments.create!(organization: org, approver: approver1, position: 1, purpose: :withdrawal, decision: :pending)
      described_class.call(approvable: wh, approver: approver1)
      expect(wh.reload).to be_withdrawn
    end
  end
end
