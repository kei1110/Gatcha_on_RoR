# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbsenceConfirmationPolicy do
  let(:org) { create(:organization) }
  let(:other_org) { create(:organization, subdomain: "other") }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)      { create(:user, :hr_admin) }
  let(:manager) { create(:user, :manager_role, manager: hr) }
  let(:sub)     { create(:user, manager: manager) }
  let(:stranger) { create(:user, manager: hr) } # 同一テナント・manager の部下でない
  let(:employee) { create(:user) }

  describe "role ゲート" do
    it "hr_admin は index/create 可" do
      policy = described_class.new(hr, :absence_confirmation)
      expect(policy.index?).to be(true)
      expect(policy.create?).to be(true)
    end

    it "manager は index/create 可" do
      policy = described_class.new(manager, :absence_confirmation)
      expect(policy.index?).to be(true)
      expect(policy.create?).to be(true)
    end

    it "一般社員は index/create 不可" do
      policy = described_class.new(employee, :absence_confirmation)
      expect(policy.index?).to be(false)
      expect(policy.create?).to be(false)
    end
  end

  describe "Scope（確定対象社員のロスター）" do
    def resolve(actor) = described_class::Scope.new(actor, User).resolve

    it "manager は直属部下のみ（非部下は含まない）" do
      expect(resolve(manager)).to include(sub)
      expect(resolve(manager)).not_to include(stranger)
    end

    it "manager は自分自身を含まない（自己確定の防止）" do
      expect(resolve(manager)).not_to include(manager)
    end

    it "hr_admin は組織全員を含む（自分自身も — manager_id: nil の候補は hr_admin のみ確定可・§12⑧）" do
      expect(resolve(hr)).to include(hr, manager, sub, stranger)
    end

    it "hr_admin でも他テナントの社員は含まない（default_scope を外しても閉じる）" do
      outsider = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      # hr/sub は without_tenant に入る前（= org のテナント文脈が有効なうち）に確定させる。
      # 遅延 let のまま without_tenant 内で初参照すると factory の organization がテナント文脈を失い、
      # sub の生成過程（manager: manager → manager: hr）で組織不一致エラーになる。
      hr_admin = hr
      subordinate = sub

      ActsAsTenant.without_tenant do
        expect(resolve(hr_admin)).not_to include(outsider)
        expect(resolve(hr_admin)).to include(subordinate)
      end
    end

    it "退職者（active: false）は含まない" do
      retired = create(:user, manager: manager, active: false)
      expect(resolve(manager)).not_to include(retired)
    end

    it "一般社員は空" do
      expect(resolve(employee)).to be_empty
    end
  end
end
