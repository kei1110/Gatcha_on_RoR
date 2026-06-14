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
end
