require "rails_helper"

RSpec.describe Admin::UserPolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let!(:record) { create(:user) }

  context "hr_admin" do
    let(:actor) { create(:user, :hr_admin) }

    it { is_expected.to permit_actions(%i[index show new create edit update deactivate activate]) }

    it "destroy は hr_admin でも不可（物理削除なし・deactivate 方式の固定）" do
      expect(subject.destroy?).to be(false)
    end

    describe "resend_invitation?（サーバ側強制・0b-1 設計 §2-5）" do
      it "未受諾（sign_in_count 0）かつ active なら許可" do
        expect(subject.resend_invitation?).to be(true)
      end

      it "ログイン済み（受諾済）には拒否 — トークン強制発行を塞ぐ" do
        record.update_column(:sign_in_count, 1)
        expect(subject.resend_invitation?).to be(false)
      end

      it "inactive には拒否" do
        record.update_column(:active, false)
        expect(subject.resend_invitation?).to be(false)
      end
    end
  end

  context "manager" do
    let(:actor) { create(:user, :manager_role) }
    it { is_expected.to forbid_actions(%i[index show new create edit update deactivate activate resend_invitation]) }
  end

  context "employee" do
    let(:actor) { create(:user) }
    it { is_expected.to forbid_actions(%i[index show new create edit update deactivate activate resend_invitation]) }
  end

  describe "Scope" do
    it "組織全員（inactive 含む）を返し、他テナントを漏らさない" do
      actor    = create(:user, :hr_admin)
      member   = create(:user)
      inactive = create(:user, active: false)
      ActsAsTenant.with_tenant(create(:organization)) { create(:user) }

      resolved = described_class::Scope.new(actor, User.all).resolve
      expect(resolved).to contain_exactly(actor, member, inactive, record)
    end
  end
end
