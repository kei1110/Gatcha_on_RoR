# frozen_string_literal: true

require "rails_helper"

RSpec.describe Withdrawable do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:requester) { create(:user, organization: org) }
  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:host) { WithdrawalTestRecord.create!(requester:, approval_status: :approved) }

  def withdrawal_assignment(decision: :approved)
    host.approval_assignments.create!(organization: org, approver:, position: 1,
                                      purpose: :withdrawal, decision:, acted_at: (decision == :pending ? nil : Time.current))
  end

  describe "AASM 撤回遷移（§13.2）" do
    it "approved → request_withdrawal で withdrawal_requested・DB 整数 4（R-whiny ③）" do
      host.withdrawal_reason = "誤申請のため"
      host.request_withdrawal!
      expect(host.reload.approval_status).to eq("withdrawal_requested")
      expect(host).to be_withdrawal_requested
    end

    it "withdrawal_requested → approve_withdrawal（全段 approved）で withdrawn" do
      host.update!(approval_status: :withdrawal_requested, withdrawal_reason: "x")
      withdrawal_assignment(decision: :approved)
      expect(host.all_stages_approved?).to be true
      host.approve_withdrawal!
      expect(host).to be_withdrawn
    end

    it "withdrawal_requested → reject_withdrawal で approved 復帰" do
      host.update!(approval_status: :withdrawal_requested, withdrawal_reason: "x")
      host.reject_withdrawal!
      expect(host).to be_approved
    end

    it "withdrawal_requested では approve/reject が未定義＝InvalidTransition（§7.6 構造防御）" do
      host.update!(approval_status: :withdrawal_requested, withdrawal_reason: "x")
      expect { host.approve! }.to raise_error(AASM::InvalidTransition)
      expect { host.reject! }.to raise_error(AASM::InvalidTransition)
    end

    it "撤回世代が既にあれば再撤回不可（D6・no_prior_withdrawal_round? guard）" do
      withdrawal_assignment(decision: :rejected)
      host.update!(approval_status: :approved)
      expect { host.request_withdrawal! }.to raise_error(AASM::InvalidTransition)
    end
  end

  describe "whiny_persistence 継承（R-whiny ④）" do
    # 遷移先が withdrawal_requested ゆえ presence 検証（if: :withdrawal_requested?）が target 状態で発火。
    # save 失敗時に whiny_persistence が false でなく例外を上げることを決定的に検証。
    it "save 失敗時に false でなく RecordInvalid を上げ、状態はロールバック" do
      host.withdrawal_reason = nil   # 遷移先 withdrawal_requested で presence 違反
      expect { host.request_withdrawal! }.to raise_error(ActiveRecord::RecordInvalid)
      expect(host.reload).to be_approved
    end
  end

  describe "withdrawal_reason presence（R-presence）" do
    it "withdrawal_requested では withdrawal_reason 必須" do
      host.approval_status = :withdrawal_requested
      host.withdrawal_reason = nil
      expect(host).not_to be_valid
      expect(host.errors[:withdrawal_reason]).to be_present
    end
  end

  describe "HWR 隔離（D7・R 回帰）" do
    it "HolidayWorkRequest は撤回イベントを獲得しない（respond_to? false）" do
      expect(HolidayWorkRequest.new.respond_to?(:request_withdrawal)).to be false
    end

    it "HolidayWorkRequest は states 0–3 のみで正常ロード（enum 0–5 許容）" do
      hwr = build(:holiday_work_request)
      expect(hwr).to be_applying
      expect(HolidayWorkRequest.approval_statuses.keys).to include("withdrawal_requested")  # enum は持つ
    end
  end
end
