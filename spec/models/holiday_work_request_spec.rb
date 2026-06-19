# frozen_string_literal: true

require "rails_helper"

RSpec.describe HolidayWorkRequest do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:requester) { create(:user, organization: org) }
  let(:comp) { create(:leave_type, system_type: :compensatory_leave, organization: org) }

  def build_hwr(**attrs)
    build(:holiday_work_request, organization: org, requester:, compensation_leave_type: comp, **attrs)
  end

  def in_savepoint
    ActiveRecord::Base.transaction(requires_new: true) { yield }
  end

  describe "work_date は平日以外のみ" do
    it "日曜（未登録・ISO フォールバック）は valid" do
      expect(build_hwr(work_date: Date.new(2026, 6, 7))).to be_valid
    end

    it "登録済 legal_holiday は valid" do
      create(:company_calendar, organization: org, date: Date.new(2026, 5, 4),
                                day_type: :legal_holiday, name: "みどりの日")
      expect(build_hwr(work_date: Date.new(2026, 5, 4))).to be_valid
    end

    it "平日（月曜）は invalid" do
      hwr = build_hwr(work_date: Date.new(2026, 6, 8)) # 月曜
      expect(hwr).to be_invalid
      expect(hwr.errors[:work_date]).to be_present
    end

    it "work_date 未入力は presence エラー（resolver を呼ばない）" do
      hwr = build_hwr(work_date: nil)
      expect(hwr).to be_invalid
      expect(hwr.errors[:work_date]).to include("を入力してください")
    end
  end

  describe "compensation_leave_type は代休限定（D3）" do
    it "compensatory_leave は valid" do
      expect(build_hwr(compensation_leave_type: comp)).to be_valid
    end

    it "substitute_holiday は invalid（振替退行防止）" do
      sub = create(:leave_type, system_type: :substitute_holiday, organization: org)
      hwr = build_hwr(compensation_leave_type: sub)
      expect(hwr).to be_invalid
      expect(hwr.errors[:compensation_leave_type]).to be_present
    end

    it "annual は invalid" do
      annual = create(:leave_type, system_type: :annual, organization: org)
      expect(build_hwr(compensation_leave_type: annual)).to be_invalid
    end
  end

  describe "同一日重複禁止" do
    it "applying の重複は invalid" do
      create(:holiday_work_request, organization: org, requester:, work_date: Date.new(2026, 6, 7))
      expect(build_hwr(work_date: Date.new(2026, 6, 7))).to be_invalid
    end

    it "canceled 後の同日再申請は valid" do
      create(:holiday_work_request, organization: org, requester:,
                                    work_date: Date.new(2026, 6, 7), approval_status: :canceled)
      expect(build_hwr(work_date: Date.new(2026, 6, 7))).to be_valid
    end

    it "rejected 後の同日再申請は valid" do
      create(:holiday_work_request, organization: org, requester:,
                                    work_date: Date.new(2026, 6, 7), approval_status: :rejected)
      expect(build_hwr(work_date: Date.new(2026, 6, 7))).to be_valid
    end

    it "DB partial unique が二層目（applying 2 件目を弾く）" do
      create(:holiday_work_request, organization: org, requester:, work_date: Date.new(2026, 6, 7))
      dup = build_hwr(work_date: Date.new(2026, 6, 7))
      expect { in_savepoint { dup.save!(validate: false) } }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "テナント越境 FK（二層）" do
    let(:other_org) { create(:organization) }

    it "他テナント requester は model 検証で invalid" do
      other_user = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      hwr = build_hwr(requester: other_user)
      expect(hwr).to be_invalid
      expect(hwr.errors[:requester]).to include("は同一組織でなければなりません")
    end

    it "他テナント requester は DB FK で弾く" do
      other_user = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      hwr = build_hwr(requester: other_user)
      hwr.requester_id = other_user.id
      expect { in_savepoint { hwr.save!(validate: false) } }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "他テナント compensation_leave_type は model 検証で invalid" do
      other_comp = ActsAsTenant.with_tenant(other_org) do
        create(:leave_type, system_type: :compensatory_leave, organization: other_org)
      end
      hwr = build_hwr(compensation_leave_type: other_comp)
      expect(hwr).to be_invalid
      expect(hwr.errors[:compensation_leave_type]).to include("は同一組織でなければなりません")
    end

    it "他テナント compensation_leave_type は DB FK で弾く" do
      other_comp = ActsAsTenant.with_tenant(other_org) do
        create(:leave_type, system_type: :compensatory_leave, organization: other_org)
      end
      hwr = build_hwr(compensation_leave_type: other_comp)
      hwr.compensation_leave_type_id = other_comp.id
      expect { in_savepoint { hwr.save!(validate: false) } }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe "Approvable lifecycle" do
    it "初期は applying" do
      expect(build_hwr.approval_status).to eq("applying")
    end

    it "reject! で rejected へ" do
      hwr = create(:holiday_work_request, organization: org, requester:)
      hwr.reject!
      expect(hwr).to be_rejected
    end

    it "cancel! で canceled へ" do
      hwr = create(:holiday_work_request, organization: org, requester:)
      hwr.cancel!
      expect(hwr).to be_canceled
    end
  end
end
