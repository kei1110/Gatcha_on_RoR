# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClockChangeRequest do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:user) { create(:user, organization: org) }
  let(:record) { create(:attendance_record, :done, user:, work_date: Date.new(2026, 6, 1)) }

  def build_ccr(**attrs)
    build(:clock_change_request, requester: user, attendance_record: record, **attrs)
  end

  it "デフォルト（clock_in 変更）は valid" do
    expect(build_ccr).to be_valid
  end

  describe "change_type 別 new_clock_* presence" do
    it "clock_in は new_clock_in 必須" do
      expect(build_ccr(change_type: :clock_in, new_clock_in: nil)).to be_invalid
    end

    it "clock_out は new_clock_out 必須" do
      expect(build_ccr(change_type: :clock_out, new_clock_in: nil, new_clock_out: nil)).to be_invalid
    end

    it "both は両方必須・new_out > new_in" do
      expect(build_ccr(change_type: :both, new_clock_in: Time.utc(2026, 6, 1, 1),
                       new_clock_out: Time.utc(2026, 6, 1, 9))).to be_valid
      expect(build_ccr(change_type: :both, new_clock_in: Time.utc(2026, 6, 1, 9),
                       new_clock_out: Time.utc(2026, 6, 1, 1))).to be_invalid   # out <= in
    end
  end

  it "reason 必須" do
    expect(build_ccr(reason: "")).to be_invalid
  end

  describe "対象記録の制約" do
    it "on_leave 記録は拒否" do
      leave = create(:attendance_record, user:, status: :on_leave, clock_in: nil,
                     work_date: Date.new(2026, 6, 2))
      expect(build_ccr(attendance_record: leave)).to be_invalid
    end

    it "working 記録（clock_out 無）は拒否・clocked_out は許可" do
      working = create(:attendance_record, user:, status: :working, work_date: Date.new(2026, 6, 3))
      expect(build_ccr(attendance_record: working)).to be_invalid
      expect(build_ccr(attendance_record: record)).to be_valid   # :done = clocked_out
    end

    it "他人の記録は拒否" do
      other = create(:user, organization: org)
      others_record = create(:attendance_record, :done, user: other, work_date: Date.new(2026, 6, 4))
      expect(build_ccr(attendance_record: others_record)).to be_invalid
    end
  end

  describe "テナント越境（ID 基点 fail-closed）" do
    it "他テナントの requester / attendance_record を拒否（association）" do
      other_org = create(:organization)
      other_user = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      ccr = build(:clock_change_request, organization: org, requester: other_user, attendance_record: record)
      expect(ccr).to be_invalid
      expect(ccr.errors[:requester]).to be_present
    end
  end

  it "approval_status は初期 applying" do
    expect(build_ccr.tap(&:validate)).to be_applying
  end
end
