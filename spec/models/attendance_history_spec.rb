require "rails_helper"

RSpec.describe AttendanceHistory do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:user)  { create(:user, organization: org) }
  let(:actor) { create(:user, :manager_role, organization: org) }

  def build_history(**attrs)
    described_class.new(user:, actor:, event_type: :proxy_clock,
                        event_date: Date.new(2026, 6, 13), **attrs)
  end

  # 監査拒否 example は requires_new で savepoint 隔離（RAISE EXCEPTION が
  # transactional fixtures の example tx を道連れ abort → 後続クエリが偽 FAIL する罠）
  def in_savepoint
    ActiveRecord::Base.transaction(requires_new: true) { yield }
  end

  describe "追記（INSERT）" do
    it "作成できる" do
      expect { build_history.save! }.to change(described_class, :count).by(1)
    end
  end

  describe "不変防御 層①② AR 経路" do
    it "層① 永続後は readonly?" do
      h = build_history.tap(&:save!)
      expect(h.readonly?).to be true
    end

    it "層① update! は ReadOnlyRecord" do
      h = build_history.tap(&:save!)
      expect { h.update!(note: "x") }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end

    it "層② destroy は ReadOnlyRecord（readonly? は destroy を止めないため必須）" do
      h = build_history.tap(&:save!)
      expect { h.destroy }.to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe "不変防御 層③ DB トリガー（AR/readonly? を迂回する経路）" do
    let!(:h) { build_history.tap(&:save!) }

    it "update_all を拒否" do
      expect { in_savepoint { described_class.where(id: h.id).update_all(note: "x") } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    it "delete_all を拒否" do
      expect { in_savepoint { described_class.where(id: h.id).delete_all } }
        .to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    it "raw SQL DELETE を拒否" do
      expect {
        in_savepoint { described_class.connection.execute("DELETE FROM attendance_histories WHERE id = #{h.id}") }
      }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end

    it "TRUNCATE を拒否" do
      expect {
        in_savepoint { described_class.connection.execute("TRUNCATE attendance_histories") }
      }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
    end
  end

  # update_columns は層③（DB トリガー）ではなく層①（readonly?）が捕捉する。
  # Rails 8.1 では update_columns が SQL 発行前に readonly? を事前チェックする（persistence.rb:622）ため、
  # 層③で実証済みと誤読されないよう独立 describe に分離。update_all/delete_all は readonly? を見ず層③が backstop。
  describe "update_columns（Rails 8.1 は層① readonly? が先行捕捉）" do
    let!(:h) { build_history.tap(&:save!) }

    it "ReadOnlyRecord を上げる" do
      expect { in_savepoint { h.update_columns(note: "x") } }
        .to raise_error(ActiveRecord::ReadOnlyRecord)
    end
  end

  describe "検証" do
    it "event_type の整数マッピングが固定（proxy_clock=7）" do
      expect(described_class.event_types["proxy_clock"]).to eq 7
      expect(described_class.event_types.values_at("clock_in", "interval_shortage")).to eq [ 0, 8 ]
    end

    it "proxy_clock は actor 必須" do
      h = build_history(actor: nil)
      expect(h).to be_invalid
      expect(h.errors[:actor_id]).to be_present
    end

    it "interval_shortage は actor 任意（Phase4 システムイベント）" do
      h = build_history(event_type: :interval_shortage, actor: nil)
      expect(h).to be_valid
    end

    it "他テナントの user を拒否" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
      h = build_history(user: foreign)
      expect(h).to be_invalid
      expect(h.errors[:user]).to be_present
    end

    it "他テナントの actor を拒否" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, :manager_role, organization: other) }
      h = build_history(actor: foreign)
      expect(h).to be_invalid
      expect(h.errors[:actor]).to be_present
    end

    # fail-closed 回帰: スコープ外 ID を整数で直接代入すると acts_as_tenant が actor を nil 解決するが、
    # actor_id 基点の検証が弾く（actor.nil? early return の fail-open を防ぐ・user.rb 同型）
    it "他テナント actor_id の直接代入を拒否（整数 ID 経路の fail-closed）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, :manager_role, organization: other) }
      h = build_history(actor: nil).tap { |rec| rec.actor_id = foreign.id }
      expect(h.actor).to be_nil   # スコープ外ゆえ association は nil 解決される
      expect(h).to be_invalid
      expect(h.errors[:actor]).to be_present
    end

    it "他テナントの source を拒否（polymorphic の唯一の構造防衛）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:attendance_record, organization: other, user: create(:user, organization: other))
      end
      h = build_history(source: foreign)
      expect(h).to be_invalid
      expect(h.errors[:source]).to be_present
    end

    # fail-closed 回帰（W-1）: polymorphic は複合 FK を張れず source 検証が唯一の構造防衛。
    # スコープ外 ID を source_id に直接代入すると acts_as_tenant が source を nil 解決するが、
    # source_id 基点の検証が弾く（source.nil? early return の fail-open を防ぐ・user/actor 同型）
    it "他テナント source_id の直接代入を拒否（polymorphic・整数 ID 経路の fail-closed）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:attendance_record, organization: other, user: create(:user, organization: other))
      end
      h = build_history.tap do |rec|
        rec.source_type = "AttendanceRecord"
        rec.source_id = foreign.id
      end
      expect(h.source).to be_nil   # スコープ外ゆえ association は nil 解決される
      expect(h).to be_invalid
      expect(h.errors[:source]).to be_present
    end
  end
end
