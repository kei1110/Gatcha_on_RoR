# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequest do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def in_savepoint = ActiveRecord::Base.transaction(requires_new: true) { yield }

  it "有効なら保存でき、初期 approval_status は applying（Approvable）" do
    r = create(:leave_request)
    expect(r).to be_persisted
    expect(r.approval_status).to eq("applying")
  end

  describe "days_requested" do
    it "0 は拒否（空申請を通さない・MPR）" do
      r = build(:leave_request, days_requested: 0)
      expect(r).to be_invalid
      expect(r.errors[:days_requested]).to be_present
    end
  end

  describe "期間" do
    it "end < start は無効" do
      r = build(:leave_request, start_date: Date.new(2026, 5, 2), end_date: Date.new(2026, 5, 1))
      expect(r).to be_invalid
    end

    it "MAX_SPAN_DAYS 超は無効" do
      r = build(:leave_request, start_date: Date.new(2026, 1, 1),
                                end_date: Date.new(2026, 1, 1) + LeaveRequest::MAX_SPAN_DAYS + 1)
      expect(r).to be_invalid
    end
  end

  describe "半休排他（§4.9）" do
    it "half_day_type != none で start != end は無効" do
      lt = create(:leave_type, allow_half_day: true)
      r = build(:leave_request, leave_type: lt, half_day_type: :morning,
                                start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 2))
      expect(r).to be_invalid
    end

    it "half_day_type != none で単日は valid（過剰制約でない）" do
      lt = create(:leave_type, allow_half_day: true)
      r = build(:leave_request, leave_type: lt, half_day_type: :afternoon, days_requested: 0.5,
                                start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(r).to be_valid
    end

    it "none × 複数日は valid" do
      r = build(:leave_request, half_day_type: :none, days_requested: 2,
                                start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 2))
      expect(r).to be_valid
    end
  end

  describe "#apply_approval_effects!（2-2b・委譲）" do
    around { |ex| ActsAsTenant.with_tenant(create(:organization)) { ex.run } }

    it "ApplyApproval へ委譲する" do
      lr = build(:leave_request)
      actor = build(:user, :manager_role)
      expect(LeaveRequests::ApplyApproval).to receive(:call).with(leave_request: lr, acting_user: actor)
      lr.apply_approval_effects!(acting_user: actor)
    end
  end

  describe "半休可能種別（§6.2・MPR）" do
    it "allow_half_day=false の種別で半休は無効" do
      lt = create(:leave_type, allow_half_day: false)
      r = build(:leave_request, leave_type: lt, half_day_type: :morning, days_requested: 0.5)
      expect(r).to be_invalid
      expect(r.errors[:half_day_type]).to be_present
    end
  end

  describe "half_day_type 毒入力" do
    it "不正値は ArgumentError でなく検証で弾く（validate: true）" do
      r = build(:leave_request)
      r.half_day_type = "bogus"
      expect(r).to be_invalid
      expect(r.errors[:half_day_type]).to be_present
    end
  end

  describe "テナント越境（ID 基点 fail-closed）" do
    it "他テナントの requester は無効" do
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:user) }
      r = build(:leave_request)
      r.requester = outsider
      expect(r).to be_invalid
      expect(r.errors[:requester]).to be_present
    end

    it "他テナントの leave_type は無効" do
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:leave_type) }
      r = build(:leave_request)
      r.leave_type = outsider
      expect(r).to be_invalid
    end

    it "DB 最終防衛: validate:false の越境 requester_id は FK 違反" do
      other_org = create(:organization)
      outsider = ActsAsTenant.with_tenant(other_org) { create(:user) }
      expect {
        in_savepoint do
          record = build(:leave_request)
          record.requester_id = outsider.id
          record.save!(validate: false)
        end
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "DB 最終防衛: validate:false の越境 leave_type_id は FK 違反" do
      other_org = create(:organization)
      outsider = ActsAsTenant.with_tenant(other_org) { create(:leave_type) }
      expect {
        in_savepoint do
          record = build(:leave_request)
          record.leave_type_id = outsider.id
          record.save!(validate: false)
        end
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe "締めステータスによる作成制限（§6.7・3-2）" do
    let(:requester) { create(:user) }

    it "対象日が submitted 月なら作成 invalid" do
      create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :submitted)
      lr = build(:leave_request, requester:, start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(lr).not_to be_valid
      expect(lr.errors[:base]).to include(a_string_including("締め済み"))
    end

    it "対象日が aggregating 月なら作成 valid" do
      lr = build(:leave_request, requester:, start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1), days_requested: 1)
      expect(lr).to be_valid
    end

    it "月跨ぎで一部が締め済みなら all-or-nothing で弾く" do
      create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :finalized)
      lr = build(:leave_request, requester:, start_date: Date.new(2026, 4, 28), end_date: Date.new(2026, 5, 2), days_requested: 5)
      expect(lr).not_to be_valid
    end
  end
end
