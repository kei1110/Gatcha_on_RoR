# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvable do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:requester) { create(:user, organization: org) }
  let(:approver1) { create(:user, :manager_role, organization: org) }
  let(:approver2) { create(:user, :hr_admin, organization: org) }
  let(:host) { ApprovalTestRecord.create!(requester:) }

  def add_assignment(position:, approver:, decision: :pending, acted_at: nil)
    host.approval_assignments.create!(organization: org, approver:, position:, decision:, acted_at:)
  end

  describe "初期状態（§7.7）" do
    it "新規作成で applying" do
      expect(host).to be_applying
      expect(host.approval_status).to eq("applying")
    end
  end

  describe "enum 整数マッピング（凍結）" do
    it "0–5 完全一致（4/5 は 2-5 撤回・予約を宣言）" do
      expect(ApprovalTestRecord.approval_statuses).to eq(
        "applying" => 0, "approved" => 1, "rejected" => 2, "canceled" => 3,
        "withdrawal_requested" => 4, "withdrawn" => 5
      )
    end
  end

  describe "active_purpose / awaiting_decision?（2-5）" do
    it "applying は approval 世代・awaiting_decision? true" do
      expect(host.active_purpose).to eq(:approval)
      expect(host.awaiting_decision?).to be true
    end

    it "current_approval_position は active_purpose（approval）でスコープ" do
      host.approval_assignments.create!(organization: org, approver: approver1, position: 1, purpose: :approval, decision: :pending)
      expect(host.current_approval_position).to eq(1)
    end
  end

  describe "AASM 遷移" do
    it "approve（最終段階）で approved" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      expect(host.all_stages_approved?).to be true
      host.approve!
      expect(host).to be_approved
    end

    it "reject で rejected" do
      host.reject!
      expect(host).to be_rejected
    end

    it "cancel で canceled" do
      host.cancel!
      expect(host).to be_canceled
    end

    it "terminal からは InvalidTransition" do
      host.reject!
      expect { host.approve! }.to raise_error(AASM::InvalidTransition)
    end

    it "全段階 approved でなければ approve! の guard で弾く" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      add_assignment(position: 2, approver: approver2, decision: :pending)
      expect(host.all_stages_approved?).to be false
      expect { host.approve! }.to raise_error(AASM::InvalidTransition)
    end

    it "撤回イベントは未定義（2-5）" do
      expect(host).not_to respond_to(:request_withdrawal!)
    end
  end

  describe "段階導出ヘルパ" do
    it "current_approval_position は最小の pending 段階" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      add_assignment(position: 2, approver: approver2, decision: :pending)
      expect(host.current_approval_position).to eq(2)
    end

    it "current_approval_position は pending 皆無なら nil" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      expect(host.current_approval_position).to be_nil
    end

    it "all_stages_approved? は rejected を含むと false" do
      add_assignment(position: 1, approver: approver1, decision: :rejected, acted_at: Time.current)
      expect(host.all_stages_approved?).to be false
    end

    it "all_stages_approved? は assignment 皆無なら false" do
      expect(host.all_stages_approved?).to be false
    end
  end

  describe "§7.3 #5 AASM 限定（最小回帰）" do
    it "enum bang で直接 approved にしても guard を経ない（迂回経路の存在を固定）" do
      # bang は AASM 迂回ゆえ承認エンジン外から呼ばない契約。ここでは「迂回し得る」事実を回帰固定し、
      # 正規経路（approve!）は guard を経ることと対比する
      host.approved!
      expect(host).to be_approved      # bang は guard を経ずに状態を変える＝呼んではならない
    end
  end

  describe "副作用 hook と導出ヘルパ（2-2b）" do
    it "apply_approval_effects! は既定 no-op（nil 返し）" do
      expect(host.apply_approval_effects!(acting_user: approver1)).to be_nil
    end

    it "single_stage? は assignment 1 件で true / 2 件で false" do
      add_assignment(position: 1, approver: approver1)
      expect(host.single_stage?).to be true
      add_assignment(position: 2, approver: approver2)
      expect(host.single_stage?).to be false
    end

    it "pending_approver は現段階の approver（stage1 approved 後は stage2）" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      add_assignment(position: 2, approver: approver2)
      expect(host.pending_approver).to eq(approver2)
    end

    it "pending_approver は pending 皆無なら nil" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      expect(host.pending_approver).to be_nil
    end
  end
end
