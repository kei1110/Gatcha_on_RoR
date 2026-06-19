# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveType, type: :model do
  describe "name（3 点セット・gen-spec 規約）" do
    it "is unique within tenant" do
      create(:leave_type, name: "有給休暇")
      expect(build(:leave_type, name: "有給休暇")).not_to be_valid
    end

    it "allows same name in another tenant (鏡像)" do
      create(:leave_type, name: "有給休暇")
      ActsAsTenant.with_tenant(create(:organization)) do
        expect(build(:leave_type, name: "有給休暇")).to be_valid
      end
    end

    it "is enforced by composite unique index at DB level" do
      lt = create(:leave_type, name: "有給休暇")
      dup = build(:leave_type, name: "有給休暇", organization: lt.organization)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "system_type" do
    it "全 6 値を受け付け、不正値は invalid（enum validate: true — ArgumentError 500 にしない）" do
      %i[annual substitute_holiday compensatory_leave child_care paternity_leave other].each do |t|
        expect(build(:leave_type, system_type: t)).to be_valid
      end
      lt = build(:leave_type, system_type: "bogus")
      expect(lt).not_to be_valid
    end

    it "presence（name / system_type）" do
      lt = LeaveType.new
      lt.valid?
      expect(lt.errors[:name]).to be_present
      expect(lt.errors[:system_type]).to be_present
    end

    it "整数マッピングを固定（DB 値依存のリオーダー事故検知）" do
      expect(LeaveType.system_types).to eq(
        "annual" => 0, "substitute_holiday" => 1, "compensatory_leave" => 2,
        "child_care" => 3, "paternity_leave" => 4, "other" => 5)
    end

    it "全 enum 値に ja.yml の表示名がある（訳語欠落の検知）" do
      LeaveType.system_types.keys.each do |key|
        expect(I18n.exists?("leave_types.system_types.#{key}")).to be(true), "missing: #{key}"
      end
    end
  end

  describe "#balance_tracked?" do
    let(:org) { create(:organization) }

    def lt(system_type:, paid_leave:)
      build(:leave_type, organization: org, system_type:, paid_leave:)
    end

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "paid_leave=true は system_type 不問で true" do
      expect(lt(system_type: :annual, paid_leave: true)).to be_balance_tracked
      expect(lt(system_type: :other,  paid_leave: true)).to be_balance_tracked
    end

    it "compensatory_leave は paid_leave=false でも true（D2 新挙動）" do
      expect(lt(system_type: :compensatory_leave, paid_leave: false)).to be_balance_tracked
    end

    it "substitute_holiday かつ paid_leave=false は false（v1 デッド項除外）" do
      expect(lt(system_type: :substitute_holiday, paid_leave: false)).not_to be_balance_tracked
    end

    it "substitute_holiday かつ paid_leave=true は true（Codex C3・述語列挙では閉じない）" do
      expect(lt(system_type: :substitute_holiday, paid_leave: true)).to be_balance_tracked
    end

    it "annual/child_care/paternity_leave/other は paid_leave=false なら false" do
      %i[annual child_care paternity_leave other].each do |st|
        expect(lt(system_type: st, paid_leave: false)).not_to be_balance_tracked
      end
    end
  end
end
