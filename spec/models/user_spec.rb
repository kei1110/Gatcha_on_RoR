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

  describe "ガード① 最後のアクティブ hr_admin 保護（0b-1 設計 §3）" do
    let!(:admin) { create(:user, :hr_admin) }

    context "組織唯一のアクティブ hr_admin のとき" do
      it "降格を拒否する（自分でも他人でも同じバリデーション）" do
        admin.role = :employee
        expect(admin).not_to be_valid
        expect(admin.errors[:base]).to include("組織最後の管理者は降格・無効化できません")
      end

      it "無効化を拒否する" do
        admin.active = false
        expect(admin).not_to be_valid
      end

      it "降格と無効化の同時変更も拒否する" do
        admin.assign_attributes(role: :employee, active: false)
        expect(admin).not_to be_valid
      end

      it "role/active に触れない更新は許可する" do
        admin.name = "改名 太郎"
        expect(admin).to be_valid
      end

      it "他に hr_admin はいるが inactive のとき、救済要員に数えず拒否する" do
        create(:user, :hr_admin, active: false)
        admin.role = :employee
        expect(admin).not_to be_valid
      end
    end

    context "他にアクティブな hr_admin がいるとき" do
      before { create(:user, :hr_admin) }

      it "自己降格を許可する" do
        admin.role = :employee
        expect(admin).to be_valid
      end

      it "無効化を許可する" do
        admin.active = false
        expect(admin).to be_valid
      end
    end

    it "鏡像: 他テナントの hr_admin は救済要員に数えない" do
      ActsAsTenant.with_tenant(create(:organization)) { create(:user, :hr_admin) }
      admin.role = :employee
      expect(admin).not_to be_valid
    end

    it "without_tenant 文脈（console/seed 相当）でも保護される — fail-open しない" do
      ActsAsTenant.with_tenant(create(:organization)) { create(:user, :hr_admin) }
      ActsAsTenant.without_tenant do
        reloaded = User.find(admin.id)
        reloaded.role = :employee
        expect(reloaded).not_to be_valid
      end
    end
  end

  describe "ガード② 部下持ち無効化のブロック（0b-1 設計 §3）" do
    let!(:boss) { create(:user, :manager_role) }
    let!(:other_admin) { create(:user, :hr_admin) } # ガード①と切り離すための救済要員

    it "アクティブな部下がいる間は無効化を拒否し、人数をメッセージに含める" do
      create_list(:user, 2, manager: boss)
      boss.active = false
      expect(boss).not_to be_valid
      expect(boss.errors[:base])
        .to include("アクティブな部下が 2 名います。先に上長を付け替えてください")
    end

    it "部下が全員 inactive なら無効化できる（active 条件漏れの過剰拒否を検出）" do
      create(:user, manager: boss, active: false)
      boss.active = false
      expect(boss).to be_valid
    end

    it "部下がいなければ無効化できる" do
      boss.active = false
      expect(boss).to be_valid
    end
  end

  describe "ガード③ 上長の自己参照・循環の拒否（0b-1 設計 §3）" do
    it "自分自身を上長に指定できない" do
      user = create(:user)
      user.manager_id = user.id
      expect(user).not_to be_valid
      expect(user.errors[:manager_id]).to include("は循環しています")
    end

    it "2 ノード循環 A→B→A を拒否する" do
      a = create(:user)
      b = create(:user, manager: a)
      a.manager_id = b.id
      expect(a).not_to be_valid
      expect(a.errors[:manager_id]).to include("は循環しています")
    end

    it "3 ノード循環 A→B→C→A を拒否する" do
      a = create(:user)
      b = create(:user, manager: a)
      c = create(:user, manager: b)
      a.manager_id = c.id
      expect(a).not_to be_valid
      expect(a.errors[:manager_id]).to include("は循環しています")
    end

    it "正当な長鎖（深さ 10）は valid（深さ定数を持たないことの確認）" do
      chain = [ create(:user) ]
      9.times { chain << create(:user, manager: chain.last) }
      newcomer = build(:user, manager: chain.last)
      expect(newcomer).to be_valid
    end
  end

  describe "ガード④ 非アクティブ上長の指定拒否（0b-1 設計 §3・ガード②の代入側対称）" do
    it "inactive なユーザーを上長に指定できない" do
      retired = create(:user, active: false)
      expect(build(:user, manager: retired)).not_to be_valid
    end

    it "active なユーザーは上長に指定できる" do
      expect(build(:user, manager: create(:user))).to be_valid
    end

    it "非アクティブ上長を持ったままの再有効化を拒否する（無効化→再有効化の迂回路を塞ぐ）" do
      boss = create(:user, :manager_role)
      member = create(:user, manager: boss)
      member.update!(active: false)
      boss.update!(active: false) # アクティブな部下がいないので適法
      member.active = true
      expect(member).not_to be_valid
      expect(member.errors[:manager_id]).to include("は在籍中（アクティブ）のユーザーである必要があります")
    end
  end

  describe "招待用の内部パスワード（0b-1 設計 §2-1）" do
    it "パスワード未指定の作成は不可知ランダムパスワードで通る" do
      user = User.new(name: "招待 花子", email: "invited@example.com", employee_code: "E900")
      expect(user.save).to be(true)
      expect(user.encrypted_password).to be_present
    end

    it "パスワード明示時は上書きしない（seeds 互換）" do
      user = create(:user, password: "knownpassword1!")
      expect(user.valid_password?("knownpassword1!")).to be(true)
    end
  end
end
