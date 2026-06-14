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
      pending("Approvals::Reject は Task 9 で実装・T9 で pending 解除")
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
end
