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

  describe "対象外の new_* をクリア（Codex review・申請種別と表示/反映の不一致防止）" do
    it "change_type=clock_in は new_clock_out をクリア（対象外入力を保存しない）" do
      ccr = build_ccr(change_type: :clock_in, new_clock_in: Time.utc(2026, 6, 1, 0),
                      new_clock_out: Time.utc(2026, 6, 1, 10))
      ccr.valid?
      expect(ccr.new_clock_in).to eq(Time.utc(2026, 6, 1, 0))
      expect(ccr.new_clock_out).to be_nil
    end

    it "change_type=clock_out は new_clock_in をクリア" do
      ccr = build_ccr(change_type: :clock_out, new_clock_in: Time.utc(2026, 6, 1, 0),
                      new_clock_out: Time.utc(2026, 6, 1, 10))
      ccr.valid?
      expect(ccr.new_clock_out).to eq(Time.utc(2026, 6, 1, 10))
      expect(ccr.new_clock_in).to be_nil
    end

    it "change_type=both は両方保持" do
      ccr = build_ccr(change_type: :both, new_clock_in: Time.utc(2026, 6, 1, 0),
                      new_clock_out: Time.utc(2026, 6, 1, 10))
      ccr.valid?
      expect(ccr.new_clock_in).to eq(Time.utc(2026, 6, 1, 0))
      expect(ccr.new_clock_out).to eq(Time.utc(2026, 6, 1, 10))
    end
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

  describe "resulting_times_consistent（片側変更の in/out 反転防止）" do
    # record の clock_in = Time.utc(2026,6,1,0)、clock_out = Time.utc(2026,6,1,9)

    it "clock_out 単独で new_clock_out が既存 clock_in より前なら invalid" do
      expect(
        build_ccr(change_type: :clock_out, new_clock_in: nil,
                  new_clock_out: Time.utc(2026, 5, 31, 23))   # clock_out(23:00) < clock_in(00:00)
      ).to be_invalid
    end

    it "clock_in 単独で new_clock_in が既存 clock_out より後なら invalid" do
      expect(
        build_ccr(change_type: :clock_in,
                  new_clock_in: Time.utc(2026, 6, 1, 10))   # clock_in(10:00) > clock_out(09:00)
      ).to be_invalid
    end

    it "正常な片側変更（clock_in を既存 clock_out 以前に修正）は valid" do
      expect(
        build_ccr(change_type: :clock_in, new_clock_in: Time.utc(2026, 6, 1, 1))
      ).to be_valid
    end
  end

  describe "new_entry 拒否（Phase 4-2 まで）" do
    it "change_type=new_entry は invalid" do
      ccr = build(:clock_change_request, organization: org, requester: user,
                  attendance_record: nil, change_type: :new_entry, reason: "新規")
      expect(ccr).to be_invalid
      expect(ccr.errors[:change_type]).to be_present
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

    it "他テナントの attendance_record を拒否（association）" do
      other_org = create(:organization)
      other_record = ActsAsTenant.with_tenant(other_org) do
        create(:attendance_record, :done, user: create(:user, organization: other_org))
      end
      ccr = build(:clock_change_request, organization: org, requester: user, attendance_record: other_record)
      expect(ccr).to be_invalid
      expect(ccr.errors[:attendance_record]).to include("は同一組織でなければなりません")
    end
  end

  it "approval_status は初期 applying" do
    expect(build_ccr.tap(&:validate)).to be_applying
  end

  describe "#apply_approval_effects!（2-3・委譲）" do
    it "ApplyApproval へ委譲する" do
      c = build(:clock_change_request, requester: user, attendance_record: record)
      actor = build(:user, :manager_role)
      expect(ClockChangeRequests::ApplyApproval).to receive(:call).with(clock_change_request: c, acting_user: actor)
      c.apply_approval_effects!(acting_user: actor)
    end
  end

  describe "締めステータスによる作成制限（§6.7・3-2）" do
    let(:requester) { create(:user) }

    it "対象 AR の work_date が submitted 月なら invalid" do
      ar = create(:attendance_record, :done, user: requester, work_date: Date.new(2026, 5, 1))
      create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :submitted)
      ccr = build(:clock_change_request, requester:, attendance_record: ar)
      expect(ccr).not_to be_valid
      expect(ccr.errors[:base]).to include(a_string_including("締め済み"))
    end

    it "attendance_record 不在なら closing_target_dates 空 → 締め制限を通す（偽陽性ロック防止）" do
      ccr = build(:clock_change_request, requester:, attendance_record: nil)
      # 他検証で invalid になるが base の締めエラーは出ない
      ccr.valid?
      expect(ccr.errors[:base]).not_to include(a_string_including("締め済み"))
    end
  end
end
