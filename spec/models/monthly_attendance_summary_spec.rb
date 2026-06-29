# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlyAttendanceSummary do
  let(:org) { ActsAsTenant.test_tenant } # support/tenant.rb が既定テナントを設定
  let(:user) { create(:user, organization: org) }

  it "有効な属性で valid" do
    expect(build(:monthly_attendance_summary, user:, year_month: "2026-03")).to be_valid
  end

  describe "year_month format" do
    it "厳密に YYYY-MM のみ valid" do
      expect(build(:monthly_attendance_summary, user:, year_month: "2026-03")).to be_valid
      [ "2026-13", "2026-3", "2026-00", "202603", "" ].each do |bad|
        expect(build(:monthly_attendance_summary, user:, year_month: bad)).to be_invalid
      end
    end
  end

  describe "テナント内 uniqueness（同 user 同 year_month）" do
    it "同一 user・同一 year_month は衝突" do
      create(:monthly_attendance_summary, user:, year_month: "2026-03")
      dup = build(:monthly_attendance_summary, user:, year_month: "2026-03")
      expect(dup).to be_invalid
    end
  end

  describe "user_must_belong_to_same_organization（Critical・§3.6）" do
    it "他組織の user を代入で invalid" do
      other_user = ActsAsTenant.with_tenant(create(:organization)) { create(:user) }
      summary = build(:monthly_attendance_summary, user: other_user, year_month: "2026-03")
      expect(summary).to be_invalid
      expect(summary.errors[:user]).to include("は同一組織でなければなりません")
    end
  end

  describe "numericality" do
    it "集計列の負値は invalid" do
      expect(build(:monthly_attendance_summary, user:, total_work_hours: -1)).to be_invalid
    end
  end

  describe "テナントスコープ" do
    it "他社行は default_scope で見えない" do
      create(:monthly_attendance_summary, user:, year_month: "2026-03")
      other = create(:organization)
      ActsAsTenant.with_tenant(other) do
        expect(MonthlyAttendanceSummary.count).to eq(0)
      end
    end
  end

  describe "締め状態機械（AASM・§13.4）" do
    let(:summary) { create(:monthly_attendance_summary) }

    it "初期状態は aggregating" do
      expect(summary).to be_aggregating
    end

    it "submit で aggregating → submitted" do
      summary.submit!
      expect(summary).to be_submitted
    end

    it "submit で deferred → submitted（再提出）" do
      summary.update!(status: :deferred, deferral_reason: "修正依頼")
      summary.submit!
      expect(summary).to be_submitted
    end

    it "finalize で submitted → finalized" do
      summary.submit!
      summary.finalize!
      expect(summary).to be_finalized
    end

    it "defer で submitted → deferred（reason 必須）" do
      summary.submit!
      summary.deferral_reason = "打刻漏れ"
      summary.defer!
      expect(summary).to be_deferred
    end

    it "defer で finalized → deferred（finalized は terminal でない）" do
      summary.submit!
      summary.finalize!
      summary.deferral_reason = "確定後の修正"
      summary.defer!
      expect(summary).to be_deferred
    end

    # 負例（fail-closed・偽テスト防止）
    it "aggregating から finalize! は InvalidTransition" do
      expect { summary.finalize! }.to raise_error(AASM::InvalidTransition)
    end

    it "aggregating から defer! は InvalidTransition" do
      expect { summary.defer! }.to raise_error(AASM::InvalidTransition)
    end

    it "finalized から submit! 直行は InvalidTransition（deferred 経由必須）" do
      summary.submit!
      summary.finalize!
      expect { summary.submit! }.to raise_error(AASM::InvalidTransition)
    end

    it "差戻しは aggregating へ戻さない（defer の遷移先は deferred のみ）" do
      summary.submit!
      summary.deferral_reason = "x"
      summary.defer!
      expect(summary).not_to be_aggregating
    end

    it "deferred で deferral_reason 空なら invalid（whiny_persistence で defer! 例外）" do
      summary.submit!
      summary.deferral_reason = nil
      expect { summary.defer! }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "resubmit 後も deferral_reason を保持する（監査痕）" do
      summary.update!(status: :deferred, deferral_reason: "修正依頼")
      summary.submit!
      expect(summary.deferral_reason).to eq("修正依頼")
      expect(summary).to be_valid
    end
  end

  describe "休暇集計列（3-3a）" do
    it "paid_leave_days_used / total_leave_hours を持ち default 0" do
      summary = create(:monthly_attendance_summary)
      expect(summary.paid_leave_days_used).to eq(0)
      expect(summary.total_leave_hours).to eq(0)
    end
  end

  describe "interval_violation_count（4-2）" do
    let(:org) { create(:organization) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "既定は 0" do
      mas = create(:monthly_attendance_summary, user: create(:user))
      expect(mas.interval_violation_count).to eq(0)
    end

    it "負値は無効" do
      mas = build(:monthly_attendance_summary, user: create(:user), interval_violation_count: -1)
      expect(mas).to be_invalid
      expect(mas.errors[:interval_violation_count]).to be_present
    end
  end
end
