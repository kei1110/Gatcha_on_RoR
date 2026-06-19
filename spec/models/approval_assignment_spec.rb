# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApprovalAssignment do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:requester) { create(:user, organization: org) }
  let(:approver)  { create(:user, :manager_role, organization: org) }
  # polymorphic approvable のスタブ（同テナントの任意 AR）
  let(:approvable) { create(:attendance_record, organization: org, user: requester) }

  def build_assignment(**attrs)
    described_class.new(organization: org, approvable:, approver:, position: 1, decision: :pending, **attrs)
  end

  # 監査拒否相当の DB 例外を savepoint 隔離（transactional fixtures の example tx 道連れ防止）
  def in_savepoint
    ActiveRecord::Base.transaction(requires_new: true) { yield }
  end

  describe "作成" do
    it "有効なら保存できる" do
      expect { build_assignment.save! }.to change(described_class, :count).by(1)
    end
  end

  describe "position" do
    it "1/2 以外は無効" do
      a = build_assignment(position: 3)
      expect(a).to be_invalid
      expect(a.errors[:position]).to be_present
    end

    it "同一 approvable で position 重複は無効" do
      build_assignment(position: 1).save!
      dup = build_assignment(position: 1, approver: create(:user, :hr_admin, organization: org))
      expect(dup).to be_invalid
      expect(dup.errors[:position]).to be_present
    end
  end

  describe "decision" do
    it "不正な値は ArgumentError でなく検証で弾く（毒入力）" do
      # Rails 8 + validate: true: 代入時は例外を出さず、validate で弾く
      a = build_assignment
      a.decision = "bogus"
      expect(a).to be_invalid
      expect(a.errors[:decision]).to be_present
    end

    it "決裁後の再変更を拒否（approved→rejected）" do
      a = build_assignment(decision: :approved, acted_at: Time.current).tap(&:save!)
      a.decision = :rejected
      expect(a).to be_invalid
      expect(a.errors[:decision]).to be_present
    end

    it "pending→approved の update は許可される" do
      a = build_assignment.tap(&:save!)
      a.decision = :approved
      a.acted_at = Time.current
      expect(a).to be_valid
    end
  end

  describe "acted_at 整合" do
    it "pending なのに acted_at 有りは無効" do
      a = build_assignment(decision: :pending, acted_at: Time.current)
      expect(a).to be_invalid
      expect(a.errors[:acted_at]).to be_present
    end

    it "decision 済なのに acted_at なしは無効" do
      a = build_assignment(decision: :approved, acted_at: nil)
      expect(a).to be_invalid
      expect(a.errors[:acted_at]).to be_present
    end
  end

  describe "テナント分離（approver）" do
    it "他テナントの approver を拒否（association 経路）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, :manager_role, organization: other) }
      a = build_assignment(approver: foreign)
      expect(a).to be_invalid
      expect(a.errors[:approver]).to be_present
    end

    it "他テナント approver_id の直接代入を拒否（fail-closed）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, :manager_role, organization: other) }
      a = build_assignment.tap { |rec| rec.approver = nil; rec.approver_id = foreign.id }
      expect(a.approver).to be_nil          # スコープ外ゆえ nil 解決
      expect(a).to be_invalid
      expect(a.errors[:approver]).to be_present
    end
  end

  describe "テナント分離（approvable・polymorphic の唯一の構造防衛）" do
    it "他テナントの approvable を拒否" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:attendance_record, organization: other, user: create(:user, organization: other))
      end
      a = build_assignment(approvable: foreign)
      expect(a).to be_invalid
      expect(a.errors[:approvable]).to be_present
    end

    it "他テナント approvable_id の直接代入を拒否（fail-closed）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:attendance_record, organization: other, user: create(:user, organization: other))
      end
      a = build_assignment.tap do |rec|
        rec.approvable = nil
        rec.approvable_type = "AttendanceRecord"
        rec.approvable_id = foreign.id
      end
      expect(a.approvable).to be_nil
      expect(a).to be_invalid
      expect(a.errors[:approvable]).to be_present
    end
  end

  describe "DB 最終防衛" do
    it "position 重複は UNIQUE 制約で弾く（検証迂回時）" do
      build_assignment(position: 1).save!
      dup = build_assignment(position: 1, approver: create(:user, :hr_admin, organization: org))
      expect { in_savepoint { dup.save!(validate: false) } }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "purpose 世代分離（2-5）" do
    let(:org) { create(:organization) }
    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
    let(:host) { ApprovalTestRecord.create!(requester: create(:user, organization: org)) }
    let(:approver) { create(:user, :manager_role, organization: org) }

    it "同一 approvable に approval/withdrawal 世代で同 position を共存できる" do
      a = host.approval_assignments.create!(organization: org, approver:, position: 1, purpose: :approval, decision: :pending)
      b = host.approval_assignments.build(organization: org, approver:, position: 1, purpose: :withdrawal, decision: :pending)
      expect(b).to be_valid
      expect { b.save! }.not_to raise_error
      expect(a.purpose_approval?).to be true
    end

    it "同一 purpose 内では position 重複を拒否（モデル検証）" do
      host.approval_assignments.create!(organization: org, approver:, position: 1, purpose: :withdrawal, decision: :pending)
      dup = host.approval_assignments.build(organization: org, approver:, position: 1, purpose: :withdrawal, decision: :pending)
      expect(dup).not_to be_valid
      expect(dup.errors[:position]).to be_present
    end
  end
end
