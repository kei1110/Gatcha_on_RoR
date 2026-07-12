# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::RouteResolver do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  # 階層: hr（hr_admin）← dept（manager・hr 配下）← boss（manager・dept 配下）← emp（employee）
  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:dept) { create(:user, :manager_role, organization: org, manager: hr) }
  let(:boss) { create(:user, :manager_role, organization: org, manager: dept) }

  def resolve(user) = described_class.call(requester: user)

  describe "employee ルート" do
    it "2 段: [直属上長, その上長]" do
      emp = create(:user, organization: org, manager: boss)
      expect(resolve(emp)).to eq([ boss, dept ])
    end

    it "上長に上長が無ければ単段に縮約" do
      top = create(:user, :manager_role, organization: org) # manager なし
      emp = create(:user, organization: org, manager: top)
      expect(resolve(emp)).to eq([ top ])
    end

    it "manager_id 未設定は RouteError(:manager_unset)" do
      emp = create(:user, organization: org, manager: nil)
      expect { resolve(emp) }.to raise_error(Approvals::RouteError) { |e| expect(e.reason).to eq(:manager_unset) }
    end
  end

  describe "manager ルート" do
    it "2 段: [部門長, チェーン上の hr_admin]" do
      mgr = create(:user, :manager_role, organization: org, manager: dept) # dept←hr
      expect(resolve(mgr)).to eq([ dept, hr ])
    end

    it "部門長が既に hr_admin なら単段に縮約" do
      mgr = create(:user, :manager_role, organization: org, manager: hr)
      expect(resolve(mgr)).to eq([ hr ])
    end

    it "チェーンに hr_admin が居なければ RouteError(:hr_admin_unset)" do
      top = create(:user, :manager_role, organization: org) # manager なし・hr 不在
      mgr = create(:user, :manager_role, organization: org, manager: top)
      expect { resolve(mgr) }.to raise_error(Approvals::RouteError) { |e| expect(e.reason).to eq(:hr_admin_unset) }
    end
  end

  describe "hr_admin 申請者エッジ（manager ルートに準拠）" do
    it "チェーン上に別 hr_admin が居れば 2 段" do
      requester_hr = create(:user, :hr_admin, organization: org, manager: dept) # dept←hr
      expect(resolve(requester_hr)).to eq([ dept, hr ])
    end

    it "直属上長が hr_admin なら単段縮約（first_hr_admin が stage1 と一致）" do
      requester_hr = create(:user, :hr_admin, organization: org, manager: hr) # 直属上長 hr が hr_admin
      expect(resolve(requester_hr)).to eq([ hr ])
    end
  end

  describe "テナント安全（クロステナント manager は解決しない）" do
    it "越境 manager_id を直接植えても Resolver は解決せず :manager_unset" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, :manager_role, organization: other) }
      emp = create(:user, organization: org)
      # 複合 FK（organization_id, manager_id）が DB レベルで越境を防ぐため、
      # disable_referential_integrity で FK チェックを一時停止して植える。
      # これは「セッション」ではなく `ALTER TABLE ... DISABLE TRIGGER ALL` ＝**テーブルに効く DDL** で、
      # Rails の実装に ensure が無い（ブロックが raise すると再有効化されない）。
      # ここが安全なのは transactional test の中だからで、example 末尾の ROLLBACK が DDL ごと巻き戻す。
      # `use_transactional_tests = false` の文脈で同じ書き方をすると test DB の FK が恒久的に死ぬ（RAILS_GOTCHAS）
      ActiveRecord::Base.connection.disable_referential_integrity do
        emp.update_column(:manager_id, foreign.id)
      end
      expect { resolve(emp.reload) }.to raise_error(Approvals::RouteError) { |e| expect(e.reason).to eq(:manager_unset) }
    end
  end
end
