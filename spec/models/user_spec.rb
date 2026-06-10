require "rails_helper"

RSpec.describe User, type: :model do
  describe "email" do
    it "is unique within tenant" do
      create(:user, email: "a@example.com")
      expect(build(:user, email: "a@example.com")).not_to be_valid
    end

    it "allows same email in another tenant (鏡像)" do
      create(:user, email: "a@example.com")
      other_org = create(:organization)
      ActsAsTenant.with_tenant(other_org) do
        expect(build(:user, email: "a@example.com")).to be_valid
      end
    end

    it "is enforced by composite unique index at DB level" do
      user = create(:user, email: "a@example.com")
      dup = build(:user, email: "a@example.com", organization: user.organization)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "is normalized to lowercase" do
      expect(create(:user, email: "Mixed@Example.COM").email).to eq("mixed@example.com")
    end
  end

  describe "employee_code" do
    it "is unique within tenant but free across tenants" do
      create(:user, employee_code: "E001")
      expect(build(:user, employee_code: "E001")).not_to be_valid
      ActsAsTenant.with_tenant(create(:organization)) do
        expect(build(:user, employee_code: "E001")).to be_valid
      end
    end
  end

  describe "#active_for_authentication?" do
    it "rejects retired users (active=false)" do
      expect(build(:user, active: false).active_for_authentication?).to be(false)
    end
  end

  describe "role" do
    it "defaults to employee and is distinct from exempt_from_overtime" do
      user = create(:user)
      expect(user).to be_employee
      expect(user.exempt_from_overtime).to be(false)
    end
  end

  describe "require_tenant canary" do
    it "raises on unscoped query (恒久 regression)" do
      ActsAsTenant.test_tenant = nil
      expect { User.count }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
    end
  end

  describe "manager 同一テナント強制（SPEC §3.6(2)）" do
    it "accepts a manager in the same organization" do
      boss = create(:user, :manager_role)
      expect(build(:user, manager: boss)).to be_valid
    end

    it "rejects a manager from another tenant with errors[:manager_id]" do
      other_org = create(:organization)
      foreign_boss = ActsAsTenant.with_tenant(other_org) { create(:user, :manager_role) }
      user = build(:user, manager_id: foreign_boss.id)
      expect(user).not_to be_valid
      # 属性まで assert — 偶然の別エラーで赤くなる「素通り」を防ぐ
      expect(user.errors[:manager_id]).to be_present
    end

    it "is enforced by composite FK even when validation is bypassed" do
      other_org = create(:organization)
      foreign_boss = ActsAsTenant.with_tenant(other_org) { create(:user, :manager_role) }
      victim = create(:user)
      expect {
        victim.update_column(:manager_id, foreign_boss.id)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
