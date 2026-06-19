# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApprovalAssignmentPolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:dept) { create(:user, :manager_role, organization: org, manager: hr) }
  let(:boss) { create(:user, :manager_role, organization: org, manager: dept) }
  let(:emp)  { create(:user, organization: org, manager: boss) }
  let(:host) { ApprovalTestRecord.create!(requester: emp).tap { |h| Approvals::Start.call(h) } }
  let(:record) { host.approval_assignments.find_by(position: 1) } # 現段階 = boss

  context "現段階の担当者本人" do
    let(:actor) { boss }
    it { is_expected.to permit_actions(%i[approve reject]) }
  end

  context "申請者本人（自己承認 #1）" do
    let(:actor) { emp }
    before { record.update_column(:approver_id, emp.id) } # emp を担当者に差し替え
    it { is_expected.to forbid_actions(%i[approve reject]) }
  end

  context "現段階でない担当者（stage2 を先に）" do
    let(:actor) { dept }
    let(:record) { host.approval_assignments.find_by(position: 2) }
    it { is_expected.to forbid_actions(%i[approve reject]) }
  end

  context "第三者" do
    let(:actor) { create(:user, :manager_role, organization: org) }
    it { is_expected.to forbid_actions(%i[approve reject]) }
  end

  context "terminal な approvable" do
    let(:actor) { boss }
    before { Approvals::Reject.call(approvable: host, approver: boss, comment: "却下") }
    it "却下後は不可" do
      expect(subject.approve?).to be(false)
    end
  end

  context "却下後の残 pending 段階（host=rejected・stage2 は pending のまま）" do
    let(:actor)  { dept }
    let(:record) { host.approval_assignments.find_by(position: 2) }
    before { Approvals::Reject.call(approvable: host, approver: boss, comment: "却下") }

    it "host が rejected なら残 pending 段階の担当者でも forbid（条件 b applying? 単独を固定）" do
      expect(subject.approve?).to be(false)
      expect(subject.reject?).to be(false)
    end
  end

  context "決裁済 assignment" do
    let(:actor) { boss }
    before { Approvals::Approve.call(approvable: host, approver: boss) }
    it "再決裁は不可（pending でない）" do
      expect(described_class.new(boss, record.reload).approve?).to be(false)
    end
  end

  describe "Scope" do
    def resolved_for(actor) = ApprovalAssignmentPolicy::Scope.new(actor, ApprovalAssignment).resolve

    it "自分が approver の pending のみ返す" do
      host # stage1=boss(pending), stage2=dept(pending)
      expect(resolved_for(boss)).to contain_exactly(host.approval_assignments.find_by(position: 1))
    end

    it "決裁済（approved）は除外する" do
      Approvals::Approve.call(approvable: host, approver: boss)
      expect(resolved_for(boss)).to be_empty
    end

    it "他者の pending は含めない" do
      host
      expect(resolved_for(dept)).to contain_exactly(host.approval_assignments.find_by(position: 2))
      expect(resolved_for(dept)).not_to include(host.approval_assignments.find_by(position: 1))
    end

    it "他テナントの pending を漏らさない" do
      host
      other_org = create(:organization)
      other_assignment = ActsAsTenant.with_tenant(other_org) do
        oemp = create(:user, organization: other_org)
        oboss = create(:user, :manager_role, organization: other_org)
        oemp.update!(manager: oboss)
        h = ApprovalTestRecord.create!(requester: oemp).tap { |x| Approvals::Start.call(x) }
        h.approval_assignments.find_by(position: 1)
      end
      expect(resolved_for(boss)).not_to include(other_assignment)
    end
  end

  describe "actionable?（撤回承認・2-5）" do
    let(:wh) { WithdrawalTestRecord.create!(requester: emp, approval_status: :withdrawal_requested, withdrawal_reason: "x") }
    let!(:asg) { wh.approval_assignments.create!(organization: org, approver: boss, position: 1, purpose: :withdrawal, decision: :pending) }

    it "撤回世代の現段階担当者は actionable" do
      expect(described_class.new(boss, asg).approve?).to be true
    end

    it "host が approved（awaiting でない）なら non-actionable" do
      wh.update_column(:approval_status, 1)
      expect(described_class.new(boss, asg.reload).approve?).to be false
    end
  end

  describe "#index?" do
    it "ログインユーザーに許可" do
      expect(described_class.new(boss, ApprovalAssignment).index?).to be true
    end
  end
end
