# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::Reject do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:dept) { create(:user, :manager_role, organization: org, manager: hr) }
  let(:boss) { create(:user, :manager_role, organization: org, manager: dept) }
  let(:emp)  { create(:user, organization: org, manager: boss) }     # route: [boss, dept]
  let(:host) { ApprovalTestRecord.create!(requester: emp).tap { |h| Approvals::Start.call(h) } }

  def reject(approver:, comment: "却下理由", **kw)
    described_class.call(approvable: host, approver:, comment:, **kw)
  end

  it "どの段階でも全体却下になる" do
    reject(approver: boss)
    expect(host.reload).to be_rejected
  end

  it "却下理由(comment)が空なら拒否" do
    expect { reject(approver: boss, comment: nil) }.to raise_error(ArgumentError)
  end

  it "却下後も残 pending は残置（行を消さない）" do
    reject(approver: boss)
    expect(host.approval_assignments.find_by(position: 2).decision).to eq("pending")
  end

  it "却下後に他段階承認者が approve できない（terminal）" do
    reject(approver: boss)
    expect { Approvals::Approve.call(approvable: host, approver: dept) }
      .to raise_error(AASM::InvalidTransition)
  end

  it "現段階でない承認者は NotCurrentApprover" do
    expect { reject(approver: dept) }.to raise_error(Approvals::NotCurrentApprover)
  end

  it "#1 直接: approver が requester 本人なら SelfApprovalError" do
    host.approval_assignments.find_by(position: 1).update_column(:approver_id, emp.id)
    expect { reject(approver: emp) }.to raise_error(Approvals::SelfApprovalError)
  end

  it "代理 pin: acting_user != approver は ProxyNotSupported" do
    expect { reject(approver: boss, acting_user: dept) }.to raise_error(Approvals::ProxyNotSupported)
  end

  describe "撤回却下の撃ち分け（2-5・副作用なし）" do
    let(:requester) { emp }
    let(:approver1) { boss }
    let(:wh) { WithdrawalTestRecord.create!(requester:, approval_status: :withdrawal_requested, withdrawal_reason: "誤申請") }

    it "撤回世代を reject すると approved へ復帰（reject_withdrawal）" do
      wh.approval_assignments.create!(organization: org, approver: approver1, position: 1, purpose: :withdrawal, decision: :pending)
      described_class.call(approvable: wh, approver: approver1, comment: "却下理由")
      expect(wh.reload).to be_approved
    end
  end
end
