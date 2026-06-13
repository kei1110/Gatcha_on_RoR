# Phase 1-3: AttendanceHistory + 代理打刻 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 管理者が部下/全社員に代わって打刻でき、その全イベントを改竄不能な追記専用監査証跡（AttendanceHistory）に記録する。

**Architecture:** ① `attendance_histories` 追記専用テーブル＋3 段不変防御（`readonly?` / `before_*` / Postgres トリガー）を fx gem で schema.rb に捕捉。② 代理打刻は自己打刻と分離した `Clockings::ProxyClockIn/Out` サービス（operator≠current_user・打刻と履歴を同一 tx・再計算は commit 後）。③ 認可は `ProxyClockingPolicy`（manager=直接部下 / hr_admin=全員・IDOR は policy_scope.find→404）。④ 本人へは §12.1 ホームの最小バナーで周知（push は Phase 4）。

**Tech Stack:** Rails 8.1 / PostgreSQL 17 / fx 0.9 / acts_as_tenant / Pundit / ViewComponent / RSpec + FactoryBot / Hotwire(Turbo)

**設計の正本:** `docs/superpowers/specs/2026-06-13-phase1-3-attendance-history-proxy-clock-design.md`（特に §R 多視点レビュー反映）

---

## File Structure

**作成:**
- `db/functions/attendance_histories_immutable_v01.sql` — 不変トリガー関数（RAISE EXCEPTION）
- `db/triggers/attendance_histories_no_mutate_v01.sql` — BEFORE UPDATE OR DELETE 行トリガー
- `db/triggers/attendance_histories_no_truncate_v01.sql` — BEFORE TRUNCATE 文トリガー
- `db/migrate/*_create_attendance_histories.rb` — テーブル＋複合 FK＋index＋関数/トリガー
- `db/migrate/*_add_proxy_clock_columns_to_attendance_records.rb` — proxy_clock_reason / note
- `app/models/attendance_history.rb` — モデル＋3 段不変防御①②＋同一テナント検証
- `app/services/clockings/proxy_clock_in.rb` / `proxy_clock_out.rb` — 代理打刻サービス
- `app/policies/proxy_clocking_policy.rb` — 認可＋Scope（manager/hr_admin）
- `app/controllers/proxy_clockings_controller.rb` — ロスター＋代理打刻アクション
- `app/views/proxy_clockings/index.html.erb`
- `app/views/home/_proxy_clock_banner.html.erb` — 本人向け代理打刻バナー（R-6）
- `spec/factories/attendance_histories.rb`
- `spec/models/attendance_history_spec.rb`
- `spec/services/clockings/proxy_clock_in_spec.rb` / `proxy_clock_out_spec.rb`
- `spec/policies/proxy_clocking_policy_spec.rb`
- `spec/requests/proxy_clockings_spec.rb`
- `spec/system/proxy_clocking_spec.rb`

**変更:**
- `Gemfile` — `gem "fx"`
- `app/models/attendance_record.rb` — `enum :proxy_clock_reason`
- `app/services/clockings.rb` — `snapshot_pattern_id` / `append_note` / `recalculate_safely` / `record_history` / `proxy_note_fragment`
- `app/services/clockings/clock_in.rb` — `snapshot_pattern_id` へ寄せる（回帰）
- `app/services/clockings/clock_out.rb` — `recalculate_safely` へ寄せる（回帰）
- `app/controllers/home_controller.rb` / `app/views/home/show.html.erb` — バナー＋代理打刻ナビ
- `config/routes.rb` — `resources :proxy_clockings`
- `config/locales/ja.yml` — enum ラベル・メッセージ・ロスター見出し
- docs（SPEC / ROADMAP / RAILS_GOTCHAS / NOTES）

---

## Task 1: fx 導入 + attendance_histories テーブル + 不変トリガー

**Files:**
- Modify: `Gemfile`
- Create: `db/functions/attendance_histories_immutable_v01.sql`
- Create: `db/triggers/attendance_histories_no_mutate_v01.sql`
- Create: `db/triggers/attendance_histories_no_truncate_v01.sql`
- Create: `db/migrate/<ts>_create_attendance_histories.rb`

- [ ] **Step 1: fx を Gemfile に追加**

`Gemfile` の DB 系 gem 付近（`gem "pg"` の近く）に追記:

```ruby
# 追記専用テーブルのトリガー/関数を schema.rb にダンプし、テスト DB に再現する（SPEC §4.14）
gem "fx", "~> 0.9"
```

- [ ] **Step 2: bundle install**

Run: `bundle install`
Expected: `Bundle complete`。`fx` が `Gemfile.lock` に追加される。

- [ ] **Step 3: 不変トリガー関数の SQL を作成**

Create `db/functions/attendance_histories_immutable_v01.sql`:

```sql
CREATE OR REPLACE FUNCTION attendance_histories_immutable()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  -- OLD を参照しないため UPDATE/DELETE/TRUNCATE で共用できる（TRUNCATE は OLD 不在）
  RAISE EXCEPTION 'attendance_histories is append-only; % is blocked (SPEC 4.14, 5-year legal trail)', TG_OP
    USING ERRCODE = 'restrict_violation';
END;
$$;
```

- [ ] **Step 4: トリガー SQL を作成（行: UPDATE/DELETE、文: TRUNCATE）**

Create `db/triggers/attendance_histories_no_mutate_v01.sql`:

```sql
-- INSERT は append のため意図的に非対象（後続スライスが OR INSERT を足すと全 writer が死ぬ）
CREATE TRIGGER attendance_histories_no_mutate
  BEFORE UPDATE OR DELETE ON attendance_histories
  FOR EACH ROW
  EXECUTE FUNCTION attendance_histories_immutable();
```

Create `db/triggers/attendance_histories_no_truncate_v01.sql`:

```sql
-- 行トリガーがすり抜ける TRUNCATE を文トリガーで塞ぐ
CREATE TRIGGER attendance_histories_no_truncate
  BEFORE TRUNCATE ON attendance_histories
  FOR EACH STATEMENT
  EXECUTE FUNCTION attendance_histories_immutable();
```

- [ ] **Step 5: マイグレーションを生成**

Run: `bin/rails generate migration CreateAttendanceHistories`
Expected: `db/migrate/<ts>_create_attendance_histories.rb` 生成。

- [ ] **Step 6: マイグレーション本体を記述**

`db/migrate/<ts>_create_attendance_histories.rb` を以下に置き換え:

```ruby
class CreateAttendanceHistories < ActiveRecord::Migration[8.1]
  def change
    create_table :attendance_histories do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false   # 対象社員
      t.bigint :actor_id               # 操作者（NULL = Phase4 システム起因イベント）
      t.date :event_date, null: false
      t.integer :event_type, null: false
      t.string :source_type            # polymorphic 起因/被作用レコード
      t.bigint :source_id
      t.integer :previous_status
      t.integer :new_status
      t.timestamptz :previous_clock_in
      t.timestamptz :new_clock_in
      t.timestamptz :previous_clock_out
      t.timestamptz :new_clock_out
      t.boolean :previous_is_late
      t.boolean :new_is_late
      t.integer :previous_late_minutes
      t.integer :new_late_minutes
      t.boolean :previous_is_early_leave
      t.boolean :new_is_early_leave
      t.integer :previous_early_leave_minutes
      t.integer :new_early_leave_minutes
      t.text :note
      t.datetime :created_at, null: false   # 追記専用ゆえ updated_at は持たない（§4.14）
    end

    # クロステナント越境を DB 層で遮断（user_work_patterns と同じ複合 FK パターン・§3.6）
    add_foreign_key :attendance_histories, :users,
                    column: %i[organization_id user_id], primary_key: %i[organization_id id],
                    name: "ah_user_same_tenant"
    # actor は NULL 許容。MATCH SIMPLE 既定ゆえ actor_id NULL 時は非検査（Phase4 行を壊さない）。
    # MATCH FULL にしないこと（org 非NULL/actor NULL の正当な行を拒否する）— §R-2
    add_foreign_key :attendance_histories, :users,
                    column: %i[organization_id actor_id], primary_key: %i[organization_id id],
                    name: "ah_actor_same_tenant"

    add_index :attendance_histories, :organization_id
    add_index :attendance_histories, %i[organization_id user_id event_date],
              name: "idx_ah_user_event_date"   # 社員×勤務日の履歴参照（§7.6 復元・Phase2 消費）
    add_index :attendance_histories, %i[organization_id source_type source_id],
              name: "idx_ah_source"            # polymorphic 逆引き（org 前置・§R-13）
    add_index :attendance_histories, %i[organization_id actor_id],
              name: "idx_ah_actor"             # 操作者起点監査（§5-1 是正チェックリスト・§R-13）

    # 不変防御 ③（fx が schema.rb へ create_function/create_trigger をダンプ）
    create_function :attendance_histories_immutable
    create_trigger :attendance_histories_no_mutate, on: :attendance_histories
    create_trigger :attendance_histories_no_truncate, on: :attendance_histories
  end
end
```

- [ ] **Step 7: マイグレーション実行**

Run: `bin/rails db:migrate`
Expected: `attendance_histories` 作成。`db/schema.rb` に `create_function`・`create_trigger` 行が出力される（fx の dumper フック）。

- [ ] **Step 8: ハードゲート — schema ラウンドトリップ検証（§R-2/R-3/R-5）**

Run:
```bash
grep -c "create_trigger\|create_function" db/schema.rb     # 期待: >= 3（function1 + trigger2）
grep "add_exclusion_constraint" db/schema.rb               # 既存 exclusion constraint も共存することを確認
bin/rails db:test:prepare                                   # schema.rb をテスト DB へロード
RAILS_ENV=test bin/rails runner 'raise "trigger missing" unless ActiveRecord::Base.connection.execute(%q{SELECT 1 FROM pg_trigger WHERE tgname = '"'"'attendance_histories_no_mutate'"'"'}).any?; puts "OK: trigger present in test DB"'
```
Expected: `>= 3`、exclusion constraint 行あり、`OK: trigger present in test DB`（fx dumper × exclusion-patch 共存の実証）。

- [ ] **Step 9: コミット**

```bash
git add Gemfile Gemfile.lock db/functions db/triggers db/migrate db/schema.rb
git commit -m "feat: attendance_histories 追記専用テーブル + 不変トリガー（fx）"
```

---

## Task 2: AttendanceHistory モデル + 3 段不変防御 + 同一テナント検証

**Files:**
- Create: `app/models/attendance_history.rb`
- Create: `spec/factories/attendance_histories.rb`
- Test: `spec/models/attendance_history_spec.rb`

- [ ] **Step 1: factory を作成**

Create `spec/factories/attendance_histories.rb`:

```ruby
FactoryBot.define do
  factory :attendance_history do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user
    actor { association(:user, :manager_role) }
    event_type { :proxy_clock }
    event_date { Date.new(2026, 6, 13) }
  end
end
```

- [ ] **Step 2: 不変防御の failing test を書く（層①②③）**

Create `spec/models/attendance_history_spec.rb`:

```ruby
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
  # transactional fixtures の example tx を道連れ abort → 後続クエリが偽 FAIL する罠・§R-5）
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

    it "update_columns を拒否" do
      expect { in_savepoint { h.update_columns(note: "x") } }
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
end
```

- [ ] **Step 3: テスト失敗を確認**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb`
Expected: FAIL（`uninitialized constant AttendanceHistory`）

- [ ] **Step 4: モデルを実装**

Create `app/models/attendance_history.rb`:

```ruby
# 勤怠の全イベントを前後値つきで記録する追記専用監査証跡（SPEC §4.14・労基法 109 条 5 年保存）。
# 不変性は 3 段で担保: ① readonly? ② before_update/destroy ③ DB トリガー（fx）。
# 真の backstop は ③（update_all 等は ①② を素通りする）。①② は fast-fail。
# 本スライスの writer は proxy_clock のみ。残り event_type は Phase 2-4 が消費。
class AttendanceHistory < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user
  belongs_to :actor, class_name: "User", optional: true   # 操作者（§3.5 オーナー/操作者分離）
  belongs_to :source, polymorphic: true, optional: true

  # §4.14 が全 9 値を順序固定する taxonomy（AttendanceRecord.status の非宣言予約とは扱いが違う）。
  # 整数マッピングは append-only/凍結（リオーダ禁止 — 履歴の誤デコードを防ぐ・§R-13）
  enum :event_type, {
    clock_in: 0, clock_out: 1, leave_approved: 2, leave_withdrawn: 3,
    clock_change_approved: 4, absence_confirmed: 5, absence_to_paid: 6,
    proxy_clock: 7, interval_shortage: 8
  }, validate: true

  validates :event_date, presence: true
  validates :actor_id, presence: true, if: :proxy_clock?   # actor 必須群（不変ゆえ事前防御・§R-9）
  validate :user_must_belong_to_same_organization
  validate :actor_must_belong_to_same_organization
  validate :source_must_belong_to_same_organization

  # 層① — 永続後の UPDATE を AR レベルで封鎖（create は new_record ゆえ通る）
  def readonly? = persisted?

  # 層② — readonly? は destroy を止めないため before_destroy が本体。before_update は belt
  before_update  { raise ActiveRecord::ReadOnlyRecord, "AttendanceHistory is append-only" }
  before_destroy { raise ActiveRecord::ReadOnlyRecord, "AttendanceHistory is append-only" }

  private

  # 複合 FK が DB 層で弾くが、§3.6(2) はモデル検証も要求（クリーンなエラーで surface・user.rb 同型）
  def user_must_belong_to_same_organization
    return if user.nil? || user.organization_id == organization_id

    errors.add(:user, "は同一組織でなければなりません")
  end

  def actor_must_belong_to_same_organization
    return if actor.nil? || actor.organization_id == organization_id

    errors.add(:actor, "は同一組織でなければなりません")
  end

  # polymorphic は複合 FK を張れないため、モデル検証が source の唯一の構造防衛（§R-1）
  def source_must_belong_to_same_organization
    return if source.nil?
    return if source.respond_to?(:organization_id) && source.organization_id == organization_id

    errors.add(:source, "は同一組織でなければなりません")
  end
end
```

- [ ] **Step 5: テスト成功を確認**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb`
Expected: PASS（全 example 緑）

- [ ] **Step 6: 検証系の test を追加（enum 整数固定・actor 必須・同一テナント）**

`spec/models/attendance_history_spec.rb` の `RSpec.describe` 末尾に追記:

```ruby
  describe "検証" do
    it "event_type の整数マッピングが固定（proxy_clock=7）" do
      expect(described_class.event_types["proxy_clock"]).to eq 7
      expect(described_class.event_types.values_at("clock_in", "interval_shortage")).to eq [0, 8]
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

    it "他テナントの actor を拒否" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, :manager_role, organization: other) }
      h = build_history(actor: foreign)
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
  end
```

- [ ] **Step 7: テスト成功を確認**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb`
Expected: PASS

- [ ] **Step 8: コミット**

```bash
git add app/models/attendance_history.rb spec/factories/attendance_histories.rb spec/models/attendance_history_spec.rb
git commit -m "feat: AttendanceHistory モデル + 3段不変防御 + 同一テナント検証"
```

---

## Task 3: attendance_records カラム追加 + enum + 打刻共有部品

**Files:**
- Create: `db/migrate/<ts>_add_proxy_clock_columns_to_attendance_records.rb`
- Modify: `app/models/attendance_record.rb`
- Modify: `app/services/clockings.rb`
- Modify: `app/services/clockings/clock_in.rb`
- Modify: `app/services/clockings/clock_out.rb`
- Test: `spec/models/attendance_record_spec.rb`, `spec/services/clockings_spec.rb`

- [ ] **Step 1: マイグレーション生成**

Run: `bin/rails generate migration AddProxyClockColumnsToAttendanceRecords`

- [ ] **Step 2: マイグレーションを記述**

```ruby
class AddProxyClockColumnsToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :attendance_records, :proxy_clock_reason, :integer  # enum・NULL = 通常打刻
    add_column :attendance_records, :note, :text                   # 代理打刻/インターバル不足の追記先
  end
end
```

- [ ] **Step 3: マイグレーション実行**

Run: `bin/rails db:migrate`
Expected: 2 列追加。

- [ ] **Step 4: enum の failing test を書く**

`spec/models/attendance_record_spec.rb` の `RSpec.describe AttendanceRecord do ... end` 内に追記:

```ruby
  describe "proxy_clock_reason enum" do
    it "整数マッピングが固定" do
      expect(AttendanceRecord.proxy_clock_reasons).to eq(
        "system_failure" => 0, "unreachable" => 1, "forgot_punch" => 2, "other" => 3
      )
    end

    it "不正値は ArgumentError でなく検証エラー（毒入力対策）" do
      rec = build(:attendance_record)
      rec.proxy_clock_reason = "bogus"
      expect(rec).to be_invalid
    end
  end
```

- [ ] **Step 5: テスト失敗を確認**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb -e "proxy_clock_reason"`
Expected: FAIL

- [ ] **Step 6: AttendanceRecord に enum を追加**

`app/models/attendance_record.rb` の `enum :status, ...` 行の直後に追記:

```ruby
  # 代理打刻の理由（§6.1）。NULL = 通常打刻。permit する enum ゆえ validate:true で毒入力を 422 に
  enum :proxy_clock_reason,
       { system_failure: 0, unreachable: 1, forgot_punch: 2, other: 3 }, validate: true
```

- [ ] **Step 7: テスト成功を確認**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb -e "proxy_clock_reason"`
Expected: PASS

- [ ] **Step 8: Clockings 共有部品の test を書く**

Create `spec/services/clockings_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Clockings do
  describe ".append_note" do
    it "既存が空なら断片のみ" do
      expect(described_class.append_note(nil, "A")).to eq "A"
      expect(described_class.append_note("", "A")).to eq "A"
    end

    it "既存があれば ； で連結" do
      expect(described_class.append_note("A", "B")).to eq "A；B"
    end
  end
end
```

- [ ] **Step 9: テスト失敗を確認**

Run: `bundle exec rspec spec/services/clockings_spec.rb`
Expected: FAIL（`undefined method append_note`）

- [ ] **Step 10: Clockings に共有部品を追加**

`app/services/clockings.rb` の `def self.window(today) = (today - WINDOW_DAYS)..today` の下に追記:

```ruby
  # 出勤打刻のパターンスナップショット単一ソース（ClockIn / ProxyClockIn 共有・§4.8）
  def self.snapshot_pattern_id(user, date)
    user.user_work_patterns.effective_on(date).pick(:work_pattern_id)
  end

  # note の ； 連結（SPEC §6.1・代理打刻 / 4-2 インターバル不足が共有）
  def self.append_note(existing, fragment)
    existing.present? ? "#{existing}；#{fragment}" : fragment
  end

  # 計算 8 列の再計算を打刻保全しつつ実行（ClockOut / ProxyClockOut 共有・§R-4）。
  # 例外 = 実装バグだが打刻はブロックしない（8 列 NULL に閉じ Sentry へ・1-2 設計 R4）
  def self.recalculate_safely(record)
    Clockings::Recalculate.call(record:)
  rescue StandardError => e
    Rails.error.report(e, severity: :error,
                          context: { attendance_record_id: record.id }, source: "clockings")
  end

  # 代理打刻 note 断片の単一実装（§6.1 の定型文・永続データ）
  def self.proxy_note_fragment(operator:, organization:, kind:, reason:)
    zone = ActiveSupport::TimeZone[organization.time_zone]
    at = Time.current.in_time_zone(zone).strftime("%Y-%m-%d %H:%M")
    label = I18n.t("activerecord.attributes.attendance_record.proxy_clock_reasons.#{reason}")
    "代理打刻（#{kind}）：#{operator.name} が #{at} に実施（理由: #{label}）"
  end

  # AttendanceHistory 追記の単一入口（proxy_clock・将来の承認系が合流・§4.14）。
  # status は AttendanceRecord.statuses で整数化（文字列誤投入防止・§R-13）。
  # previous = 変更前スナップショット（create は nil）/ current = 確定後レコード
  def self.record_history(event_type:, organization:, user:, actor:, source:, note:, previous:, current:)
    AttendanceHistory.create!(
      organization:, user:, actor:, source:, event_type:, note:,
      event_date: current.work_date,
      previous_status: previous && AttendanceRecord.statuses[previous.status],
      new_status: AttendanceRecord.statuses[current.status],
      previous_clock_in: previous&.clock_in,  new_clock_in: current.clock_in,
      previous_clock_out: previous&.clock_out, new_clock_out: current.clock_out,
      previous_is_late: previous&.is_late, new_is_late: current.is_late,
      previous_late_minutes: previous&.late_minutes, new_late_minutes: current.late_minutes,
      previous_is_early_leave: previous&.is_early_leave, new_is_early_leave: current.is_early_leave,
      previous_early_leave_minutes: previous&.early_leave_minutes,
      new_early_leave_minutes: current.early_leave_minutes
    )
  end
```

- [ ] **Step 11: テスト成功を確認**

Run: `bundle exec rspec spec/services/clockings_spec.rb`
Expected: PASS

- [ ] **Step 12: ClockIn / ClockOut を共有部品へ寄せる（回帰・挙動不変）**

`app/services/clockings/clock_in.rb` の `work_pattern_id:` 行（`@user.user_work_patterns.effective_on(today).pick(:work_pattern_id)`）を置換:

```ruby
          work_pattern_id: Clockings.snapshot_pattern_id(@user, today),
```

`app/services/clockings/clock_out.rb` の private `recalculate` メソッド（`def recalculate(record) ... end` ブロック全体）を削除し、本体の `recalculate(record) if result.success?` を以下に置換:

```ruby
        Clockings.recalculate_safely(record) if result.success?
```

- [ ] **Step 13: 既存打刻 spec の回帰を確認**

Run: `bundle exec rspec spec/services spec/requests spec/system`
Expected: PASS（ClockIn/ClockOut の既存挙動が不変）

- [ ] **Step 14: コミット**

```bash
git add db/migrate db/schema.rb app/models/attendance_record.rb app/services/clockings.rb \
        app/services/clockings/clock_in.rb app/services/clockings/clock_out.rb \
        spec/models/attendance_record_spec.rb spec/services/clockings_spec.rb
git commit -m "feat: attendance_records に proxy_clock_reason/note + 打刻共有部品抽出"
```

---

## Task 4: 代理打刻サービス（ProxyClockIn / ProxyClockOut）

**Files:**
- Create: `app/services/clockings/proxy_clock_in.rb`
- Create: `app/services/clockings/proxy_clock_out.rb`
- Test: `spec/services/clockings/proxy_clock_in_spec.rb`, `proxy_clock_out_spec.rb`

- [ ] **Step 1: ProxyClockIn の failing test を書く**

Create `spec/services/clockings/proxy_clock_in_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Clockings::ProxyClockIn do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:operator) { create(:user, :manager_role, organization: org) }
  let(:target)   { create(:user, organization: org, manager: operator) }

  def call(reason: "system_failure", op: operator, tg: target)
    described_class.call(operator: op, target_user: tg, reason:)
  end

  it "代理出勤を作成し履歴を残す" do
    expect { @result = call }.to change(AttendanceRecord, :count).by(1)
                            .and change(AttendanceHistory, :count).by(1)
    expect(@result).to be_success
    rec = @result.record
    expect(rec.user).to eq target
    expect(rec.status).to eq "working"
    expect(rec.proxy_clock_reason).to eq "system_failure"
    expect(rec.note).to include("代理打刻（出勤）", operator.name)

    hist = AttendanceHistory.last
    expect(hist.event_type).to eq "proxy_clock"
    expect(hist.actor).to eq operator   # 操作者
    expect(hist.user).to eq target      # 対象
    expect(hist.source).to eq rec
    expect(hist.new_status).to eq AttendanceRecord.statuses["working"]
  end

  it "reason 欠落は reason_required で拒否（無理由代理打刻を塞ぐ・§R-7）" do
    result = call(reason: nil)
    expect(result).not_to be_success
    expect(result.error).to eq :reason_required
    expect(AttendanceRecord.count).to eq 0
  end

  it "自己代理は self_proxy_forbidden（自分は通常打刻・§R-8）" do
    result = call(tg: operator)
    expect(result.error).to eq :self_proxy_forbidden
  end

  it "別テナント対象は cross_tenant で fail-closed（§R-8）" do
    other = create(:organization)
    foreign = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
    result = call(tg: foreign)
    expect(result.error).to eq :cross_tenant
    expect(AttendanceHistory.count).to eq 0
  end

  it "同日出勤済みは already_clocked_in" do
    call
    expect(call.error).to eq :already_clocked_in
  end
end
```

- [ ] **Step 2: テスト失敗を確認**

Run: `bundle exec rspec spec/services/clockings/proxy_clock_in_spec.rb`
Expected: FAIL（`uninitialized constant Clockings::ProxyClockIn`）

- [ ] **Step 3: ProxyClockIn を実装**

Create `app/services/clockings/proxy_clock_in.rb`:

```ruby
module Clockings
  # 代理出勤（1-3 設計 §4）。自己打刻 ClockIn とは別クラス（current_user 固定の不変条件を壊さない）。
  # 打刻と履歴を同一 tx で原子的に（履歴は法的必須・証跡なき改変を作らない）。
  class ProxyClockIn
    def self.call(operator:, target_user:, reason:) = new(operator, target_user, reason).call

    def initialize(operator, target_user, reason)
      @operator = operator
      @target_user = target_user
      @reason = reason
      @organization = operator.organization
    end

    def call
      return failure(:reason_required) if @reason.blank?                 # §R-7
      return failure(:self_proxy_forbidden) if @operator == @target_user # §R-8

      ActsAsTenant.with_tenant(@organization) do
        # fail-closed テナント検証（console/将来ジョブ経路も守る・§3.6・§R-8）。
        # 部下境界は controller の policy_scope 専任（service は認可境界でない）
        next failure(:cross_tenant) unless @target_user.organization_id == @operator.organization_id

        today = @organization.today
        next failure(:already_clocked_in) if @target_user.attendance_records.exists?(work_date: today)
        next failure(:still_working) if @target_user.attendance_records
                                                    .working_within(Clockings.window(today)).exists?

        fragment = Clockings.proxy_note_fragment(
          operator: @operator, organization: @organization, kind: "出勤", reason: @reason)
        record = nil
        ActiveRecord::Base.transaction do
          record = @target_user.attendance_records.create!(
            work_date: today,
            clock_in: Time.current.change(usec: 0),
            work_pattern_id: Clockings.snapshot_pattern_id(@target_user, today),
            status: :working,
            proxy_clock_reason: @reason,
            note: fragment
          )
          Clockings.record_history(
            event_type: :proxy_clock, organization: @organization,
            user: @target_user, actor: @operator, source: record, note: fragment,
            previous: nil, current: record
          )
        end
        Result.new(success: true, record:, error: nil)
      end
    rescue ActiveRecord::RecordNotUnique
      failure(:already_clocked_in)   # 同時タブ/二重タップ（tx 外 rescue）
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      Rails.error.report(e, severity: :error,
                            context: { target_user_id: @target_user.id }, source: "clockings")
      failure(:proxy_clock_failed)
    end

    private

    def failure(error) = Result.new(success: false, record: nil, error:)
  end
end
```

- [ ] **Step 4: テスト成功を確認**

Run: `bundle exec rspec spec/services/clockings/proxy_clock_in_spec.rb`
Expected: PASS

- [ ] **Step 5: ProxyClockOut の failing test を書く**

Create `spec/services/clockings/proxy_clock_out_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Clockings::ProxyClockOut do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:operator) { create(:user, :manager_role, organization: org) }
  let(:target)   { create(:user, organization: org, manager: operator) }

  before { allow(org).to receive(:today).and_return(Date.new(2026, 6, 1)) }

  def open_shift
    create(:attendance_record, organization: org, user: target,
           work_date: Date.new(2026, 6, 1), status: :working)
  end

  def call(reason: "forgot_punch")
    described_class.call(operator: operator, target_user: target, reason:)
  end

  it "代理退勤し履歴を残す。再計算は commit 後" do
    open_shift
    expect { @result = call }.to change(AttendanceHistory, :count).by(1)
    expect(@result).to be_success
    rec = @result.record.reload
    expect(rec.status).to eq "clocked_out"
    expect(rec.clock_out).to be_present
    expect(rec.note).to include("代理打刻（退勤）")

    hist = AttendanceHistory.last
    expect(hist.previous_status).to eq AttendanceRecord.statuses["working"]
    expect(hist.new_status).to eq AttendanceRecord.statuses["clocked_out"]
  end

  it "window 内に working が無ければ not_working" do
    expect(call.error).to eq :not_working
  end

  it "reason 欠落は reason_required" do
    open_shift
    result = described_class.call(operator:, target_user: target, reason: "")
    expect(result.error).to eq :reason_required
  end

  it "履歴 INSERT 失敗時は退勤ごとロールバック（証跡なき改変を作らない・§R-4）" do
    rec = open_shift
    allow(Clockings).to receive(:record_history).and_raise(ActiveRecord::RecordInvalid.new(AttendanceHistory.new))
    result = call
    expect(result.error).to eq :proxy_clock_failed
    expect(rec.reload.status).to eq "working"        # 退勤がロールバックされている
    expect(rec.clock_out).to be_nil
  end
end
```

- [ ] **Step 6: テスト失敗を確認**

Run: `bundle exec rspec spec/services/clockings/proxy_clock_out_spec.rb`
Expected: FAIL

- [ ] **Step 7: ProxyClockOut を実装（with_lock + 履歴同一 tx + 再計算 commit 後）**

Create `app/services/clockings/proxy_clock_out.rb`:

```ruby
module Clockings
  # 代理退勤（1-3 設計 §4）。ClockOut と同期構造（GOTCHAS「tx 内 SQL 例外 rescue → 偽 success」回避）。
  # 退勤 + 履歴を with_lock 内で原子的に・rescue は with_lock の外・再計算は commit 後（§R-4）。
  class ProxyClockOut
    def self.call(operator:, target_user:, reason:) = new(operator, target_user, reason).call

    def initialize(operator, target_user, reason)
      @operator = operator
      @target_user = target_user
      @reason = reason
      @organization = operator.organization
    end

    def call
      return failure(:reason_required) if @reason.blank?
      return failure(:self_proxy_forbidden) if @operator == @target_user

      ActsAsTenant.with_tenant(@organization) do
        next failure(:cross_tenant) unless @target_user.organization_id == @operator.organization_id

        today = @organization.today
        record = @target_user.attendance_records
                             .working_within(Clockings.window(today)).order(work_date: :desc).first
        next failure(:not_working) if record.nil?

        fragment = Clockings.proxy_note_fragment(
          operator: @operator, organization: @organization, kind: "退勤", reason: @reason)

        result =
          begin
            record.with_lock do
              next failure(:not_working) unless record.working?

              previous = record.dup   # 変更前スナップショット（before-values）
              record.update!(
                clock_out: Time.current.change(usec: 0), status: :clocked_out,
                proxy_clock_reason: @reason, note: Clockings.append_note(record.note, fragment)
              )
              Clockings.record_history(
                event_type: :proxy_clock, organization: @organization,
                user: @target_user, actor: @operator, source: record, note: fragment,
                previous:, current: record
              )
              Result.new(success: true, record:, error: nil)
            end
          rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
            # rescue は with_lock の外（tx 内 rescue は偽 success + 更新消失・RAILS_GOTCHAS）
            Rails.error.report(e, severity: :error,
                                  context: { attendance_record_id: record.id }, source: "clockings")
            failure(:proxy_clock_failed)
          end

        Clockings.recalculate_safely(record) if result.success?   # commit 後（lock 外）
        result
      end
    end

    private

    def failure(error) = Result.new(success: false, record: nil, error:)
  end
end
```

- [ ] **Step 8: テスト成功を確認**

Run: `bundle exec rspec spec/services/clockings/proxy_clock_out_spec.rb`
Expected: PASS

- [ ] **Step 9: コミット**

```bash
git add app/services/clockings/proxy_clock_in.rb app/services/clockings/proxy_clock_out.rb \
        spec/services/clockings/proxy_clock_in_spec.rb spec/services/clockings/proxy_clock_out_spec.rb
git commit -m "feat: 代理打刻サービス ProxyClockIn/ProxyClockOut（tx 境界・fail-closed）"
```

---

## Task 5: 認可（ProxyClockingPolicy）+ コントローラ + ルート + UI

**Files:**
- Create: `app/policies/proxy_clocking_policy.rb`
- Create: `app/controllers/proxy_clockings_controller.rb`
- Create: `app/views/proxy_clockings/index.html.erb`
- Modify: `config/routes.rb`, `config/locales/ja.yml`
- Test: `spec/policies/proxy_clocking_policy_spec.rb`, `spec/requests/proxy_clockings_spec.rb`

- [ ] **Step 1: policy の failing test を書く**

Create `spec/policies/proxy_clocking_policy_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ProxyClockingPolicy do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  describe "アクション可否" do
    it "manager / hr_admin は可、employee は不可" do
      expect(described_class.new(create(:user, :manager_role, organization: org), :proxy_clocking).clock_in?).to be true
      expect(described_class.new(create(:user, :hr_admin, organization: org), :proxy_clocking).clock_in?).to be true
      expect(described_class.new(create(:user, organization: org), :proxy_clocking).clock_in?).to be false
    end
  end

  describe "Scope" do
    let(:manager) { create(:user, :manager_role, organization: org) }
    let!(:sub)    { create(:user, organization: org, manager: manager) }
    let!(:other)  { create(:user, organization: org) }                 # 非部下
    let!(:inactive_sub) { create(:user, organization: org, manager: manager, active: false) }

    it "manager は直接部下のみ（自分・非部下・inactive 除外）" do
      resolved = ProxyClockingPolicy::Scope.new(manager, User).resolve
      expect(resolved).to contain_exactly(sub)
    end

    it "hr_admin は組織全員（自分除外・active のみ）" do
      admin = create(:user, :hr_admin, organization: org)
      resolved = ProxyClockingPolicy::Scope.new(admin, User).resolve
      expect(resolved).to include(sub, other, manager)
      expect(resolved).not_to include(admin)          # 自分除外
      expect(resolved).not_to include(inactive_sub)   # inactive 除外
    end

    it "employee は空（fail-closed）" do
      expect(ProxyClockingPolicy::Scope.new(other, User).resolve).to be_empty
    end
  end
end
```

- [ ] **Step 2: テスト失敗を確認**

Run: `bundle exec rspec spec/policies/proxy_clocking_policy_spec.rb`
Expected: FAIL（`uninitialized constant ProxyClockingPolicy`）

- [ ] **Step 3: policy を実装**

Create `app/policies/proxy_clocking_policy.rb`:

```ruby
# 代理打刻の headless policy（authorize :proxy_clocking, :clock_in? — ClockingPolicy 同型）。
# 認可は二層: ① role ゲート（本 policy）② 対象ゲート（controller の policy_scope.find→404）。
# clock_in?/clock_out? は record 非依存ゆえ「対象が部下か」は Scope.find に委譲（SPEC §3.4・§R-8）。
class ProxyClockingPolicy < ApplicationPolicy
  def index?     = manager_or_admin?
  def clock_in?  = manager_or_admin?
  def clock_out? = manager_or_admin?

  # ロスター = 代理打刻の対象集合。在籍者・自分除外（自分は通常打刻）。
  # organization_id 明示（without_tenant 文脈耐性・Admin::UserPolicy::Scope と同型）
  class Scope < ApplicationPolicy::Scope
    def resolve
      base =
        if user.hr_admin?
          scope.where(organization_id: user.organization_id)
        elsif user.manager?
          scope.where(organization_id: user.organization_id, manager_id: user.id)
        else
          scope.none
        end
      base.where(active: true).where.not(id: user.id)
    end
  end

  private

  def manager_or_admin? = user.manager? || user.hr_admin?
end
```

- [ ] **Step 4: テスト成功を確認**

Run: `bundle exec rspec spec/policies/proxy_clocking_policy_spec.rb`
Expected: PASS

- [ ] **Step 5: ルートを追加**

`config/routes.rb` の `resource :clocking, ...` ブロックの直後に追記:

```ruby
  resources :proxy_clockings, only: %i[index] do
    member do
      post :clock_in    # :id = 対象社員 id
      post :clock_out
    end
  end
```

- [ ] **Step 6: i18n を追加**

`config/locales/ja.yml` の `ja:` 配下にマージ（既存キーと階層を合わせる）:

```yaml
ja:
  activerecord:
    attributes:
      attendance_record:
        proxy_clock_reasons:
          system_failure: システム障害
          unreachable: 連絡不能
          forgot_punch: 打刻忘れ
          other: その他
  proxy_clockings:
    clock_in:
      success: 代理出勤を記録しました
    clock_out:
      success: 代理退勤を記録しました
    errors:
      already_clocked_in: すでに出勤済みです
      still_working: 勤務中の打刻が残っています
      not_working: 退勤対象の勤務がありません
      cross_tenant: 対象が組織外です
      self_proxy_forbidden: 自分自身には通常の打刻を使ってください
      reason_required: 代理打刻の理由を選択してください
      proxy_clock_failed: 代理打刻に失敗しました
    index:
      title: 代理打刻
      empty: 代理打刻の対象者がいません
      clock_in: 代理出勤
      clock_out: 代理退勤
      done: 本日打刻済
      reason: 理由
```

- [ ] **Step 7: request spec の failing test を書く**

Create `spec/requests/proxy_clockings_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "ProxyClockings", type: :request do
  let(:org) { create(:organization, subdomain: "acme") }
  let(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, organization: org) } }
  let(:sub)     { ActsAsTenant.with_tenant(org) { create(:user, organization: org, manager: manager) } }

  before { host! "acme.example.com" }

  describe "代理出勤" do
    before { sign_in manager }

    it "scope 内の部下に代理出勤できる" do
      expect {
        post clock_in_proxy_clocking_path(sub), params: { proxy_clock_reason: "system_failure" }
      }.to change(AttendanceRecord, :count).by(1)
      expect(response).to have_http_status(:see_other)
    end

    it "scope 外（非部下）は 404（IDOR 対策）" do
      stranger = ActsAsTenant.with_tenant(org) { create(:user, organization: org) }
      post clock_in_proxy_clocking_path(stranger), params: { proxy_clock_reason: "system_failure" }
      expect(response).to have_http_status(:not_found)
    end

    it "reason 欠落は無理由代理打刻を作らない" do
      post clock_in_proxy_clocking_path(sub)
      expect(AttendanceRecord.count).to eq 0
      expect(response).to have_http_status(:see_other)
    end
  end
end
```

> **注（RAILS_GOTCHAS）:** request spec の setup でモデルを触るときは `ActsAsTenant.with_tenant(org) { ... }` で包む（request spec はテナント未設定で `NoTenantSet` になる）。`host!` でサブドメインを与えテナント解決させる。scope 外 `find` の 404 は controller 層の `rescue_from RecordNotFound`（0b-1 で確立）が描く。

- [ ] **Step 8: テスト失敗を確認**

Run: `bundle exec rspec spec/requests/proxy_clockings_spec.rb`
Expected: FAIL（`uninitialized constant ProxyClockingsController`）

- [ ] **Step 9: コントローラを実装**

Create `app/controllers/proxy_clockings_controller.rb`:

```ruby
# 代理打刻（1-3 設計 §5）。manager(直接部下) / hr_admin(全員) が対象社員に代わり打刻。
# 対象は policy_scope.find で解決 → scope 外は RecordNotFound → 404（IDOR 対策・SPEC §3.4）。
class ProxyClockingsController < ApplicationController
  def index
    authorize :proxy_clocking, :index?
    @targets = roster.order(:employee_code).to_a
    @today = current_user.organization.today
    ids = @targets.map(&:id)
    # 打刻状態を 1 クエリ先読み（per-row N+1 回避・§R-10）
    @open = AttendanceRecord.working_within(Clockings.window(@today))
                            .where(user_id: ids).index_by(&:user_id)
    @done_today = AttendanceRecord.where(user_id: ids, work_date: @today)
                                  .where.not(status: :working).index_by(&:user_id)
  end

  def clock_in
    authorize :proxy_clocking, :clock_in?
    target = roster.find(params[:id])
    redirect_with(
      Clockings::ProxyClockIn.call(operator: current_user, target_user: target, reason: params[:proxy_clock_reason]),
      t(".success")
    )
  end

  def clock_out
    authorize :proxy_clocking, :clock_out?
    target = roster.find(params[:id])
    redirect_with(
      Clockings::ProxyClockOut.call(operator: current_user, target_user: target, reason: params[:proxy_clock_reason]),
      t(".success")
    )
  end

  private

  # policy_scope(User) 単独は top-level UserPolicy 不在で NotDefinedError ゆえ
  # policy_scope_class を明示（§R・§5 設計）。verify_policy_scoped も満たす
  def roster = policy_scope(User, policy_scope_class: ProxyClockingPolicy::Scope)

  # 書込系 redirect は一律 see_other（Turbo 302 メソッド保持・RAILS_GOTCHAS）
  def redirect_with(result, success_message)
    if result.success?
      redirect_to proxy_clockings_path, notice: success_message, status: :see_other
    else
      redirect_to proxy_clockings_path, alert: t("proxy_clockings.errors.#{result.error}"), status: :see_other
    end
  end
end
```

- [ ] **Step 10: index ビュー（ロスター・最小）を作成**

Create `app/views/proxy_clockings/index.html.erb`:

```erb
<main class="mx-auto w-full max-w-3xl p-4">
  <h1 class="text-2xl font-bold"><%= t(".title") %></h1>

  <% if @targets.empty? %>
    <p class="mt-6 text-gray-600"><%= t(".empty") %></p>
  <% else %>
    <table class="mt-6 w-full text-sm">
      <tbody>
        <% reason_options = AttendanceRecord.proxy_clock_reasons.keys.map { |k|
             [t("activerecord.attributes.attendance_record.proxy_clock_reasons.#{k}"), k] } %>
        <% @targets.each do |target| %>
          <tr class="border-b border-gray-200">
            <td class="py-3"><%= target.name %>（<%= target.employee_code %>）</td>
            <td class="py-3 text-right">
              <% if @open[target.id] %>
                <%= form_with url: clock_out_proxy_clocking_path(target), method: :post,
                              class: "inline-flex items-center gap-2 justify-end" do %>
                  <%= select_tag :proxy_clock_reason, options_for_select(reason_options),
                        class: "rounded border-gray-300 text-sm" %>
                  <%= submit_tag t(".clock_out"), class: "rounded bg-blue-600 px-4 py-2 text-white" %>
                <% end %>
              <% elsif @done_today[target.id] %>
                <span class="text-gray-500"><%= t(".done") %></span>
              <% else %>
                <%= form_with url: clock_in_proxy_clocking_path(target), method: :post,
                              class: "inline-flex items-center gap-2 justify-end" do %>
                  <%= select_tag :proxy_clock_reason, options_for_select(reason_options),
                        class: "rounded border-gray-300 text-sm" %>
                  <%= submit_tag t(".clock_in"), class: "rounded bg-blue-600 px-4 py-2 text-white" %>
                <% end %>
              <% end %>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% end %>
</main>
```

> **UI 注（§R-13）:** `button_to` は sibling `<select>` を内包できないため、行ごと `form_with` + `select_tag` + `submit_tag` で実装する。

- [ ] **Step 11: request spec 成功を確認**

Run: `bundle exec rspec spec/requests/proxy_clockings_spec.rb`
Expected: PASS

- [ ] **Step 12: コミット**

```bash
git add app/policies/proxy_clocking_policy.rb app/controllers/proxy_clockings_controller.rb \
        config/routes.rb config/locales/ja.yml app/views/proxy_clockings \
        spec/policies/proxy_clocking_policy_spec.rb spec/requests/proxy_clockings_spec.rb
git commit -m "feat: ProxyClockingPolicy + コントローラ + ルート + ロスター UI"
```

---

## Task 6: 本人ホームの代理打刻バナー + ナビ + system spec

**Files:**
- Modify: `app/controllers/home_controller.rb`
- Modify: `app/views/home/show.html.erb`
- Create: `app/views/home/_proxy_clock_banner.html.erb`
- Test: `spec/system/proxy_clocking_spec.rb`

- [ ] **Step 1: home_controller でバナー用イベントを解決**

`app/controllers/home_controller.rb` の `show` メソッド末尾（`@day_types = ...` の後）に追記:

```ruby
    # 本人向け代理打刻バナー（§R-6・push は Phase 4）。当日レコードが代理打刻なら操作者を履歴から解決
    @today_record = @records[@state.today]
    @proxy_clock_event =
      if @today_record&.proxy_clock_reason?
        AttendanceHistory.where(source: @today_record, event_type: :proxy_clock)
                         .order(:created_at).last
      end
```

- [ ] **Step 2: バナー partial を作成**

Create `app/views/home/_proxy_clock_banner.html.erb`:

```erb
<div class="mt-4 rounded border border-amber-400 bg-amber-50 p-3 text-sm text-amber-900">
  <p>
    本日の打刻は <strong><%= event.actor&.name %></strong> による<strong>代理打刻</strong>です
    （理由: <%= t("activerecord.attributes.attendance_record.proxy_clock_reasons.#{record.proxy_clock_reason}") %>）。
  </p>
  <p class="mt-1">時刻が異なる場合は打刻変更申請を提出してください（Phase 2 で提供予定）。</p>
</div>
```

- [ ] **Step 3: show でバナーとナビを表示**

`app/views/home/show.html.erb` の `<%= render "home/clocking", state: @state %>` の直前に追記:

```erb
  <% if @proxy_clock_event %>
    <%= render "home/proxy_clock_banner", event: @proxy_clock_event, record: @today_record %>
  <% end %>
```

同ファイルのヘッダー、`<span><%= current_user.name %>...` の直前に代理打刻ナビを追記:

```erb
      <% if current_user.manager? || current_user.hr_admin? %>
        <%= link_to "代理打刻", proxy_clockings_path, class: "rounded border border-gray-300 px-3 py-1.5" %>
      <% end %>
```

- [ ] **Step 4: system spec を書く（manager が部下に代理出勤 → 部下のホームにバナー）**

Create `spec/system/proxy_clocking_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "代理打刻", type: :system do
  let(:org) { create(:organization, subdomain: "acme") }
  let!(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, organization: org, password: "password123!") } }
  let!(:sub)     { ActsAsTenant.with_tenant(org) { create(:user, organization: org, manager: manager, password: "password123!") } }

  before { driven_by(:rack_test); Capybara.app_host = "http://acme.example.com" }

  def login(user)
    visit new_user_session_path
    fill_in "メールアドレス", with: user.email
    fill_in "パスワード", with: "password123!"
    click_button "ログイン"
  end

  it "manager がロスターから部下に代理出勤でき、部下のホームにバナーが出る" do
    login(manager)
    click_link "代理打刻"
    expect(page).to have_content(sub.name)
    within("tr", text: sub.name) do
      select "打刻忘れ", from: "proxy_clock_reason"
      click_button "代理出勤"
    end
    expect(page).to have_content("代理出勤を記録しました")

    click_button "ログアウト"
    login(sub)
    expect(page).to have_content("代理打刻")
    expect(page).to have_content(manager.name)
  end
end
```

> **注:** ログインのラベル文言（"メールアドレス"/"パスワード"/"ログイン"/"ログアウト"）は既存の devise/home ビューと一致させること。差異があれば既存 system spec（`spec/system/admin_invitation_spec.rb` 等）の文言に合わせる。

- [ ] **Step 5: system spec 成功を確認**

Run: `bundle exec rspec spec/system/proxy_clocking_spec.rb`
Expected: PASS

- [ ] **Step 6: コミット**

```bash
git add app/controllers/home_controller.rb app/views/home spec/system/proxy_clocking_spec.rb
git commit -m "feat: 本人ホームの代理打刻バナー + ナビ + system spec"
```

---

## Task 7: docs 逆反映 + preflight + PR

**Files:**
- Modify: `docs/SPEC.md`, `docs/ROADMAP.md`, `docs/RAILS_GOTCHAS.md`, `docs/LABOR_LAW_REVIEW_NOTES.md`

- [ ] **Step 1: SPEC 逆反映**

`docs/SPEC.md` を編集:
- §4.14 の表に `actor_id | bigint | 操作者（NULL=システム起因）` 行を追加。`event_date`=対象勤務日／`created_at`=操作時刻の二軸、status/event_type の整数マッピングは append-only/凍結、を注記。**§7.6 撤回復元は proxy_clock 行の計算列を source にしない**契約を追記。
- §3.4 の認可表 line 211「代理打刻 | manager? かつ部下」→「代理打刻 | manager?(直接部下) または hr_admin?(全員)」へ amend。
- §11.1 に「監査 UI/CSV の計算値は常に AttendanceRecord から解決（履歴計算列を賃金証跡に使わない）」を追記。
- §6.8 退勤打刻忘れの救済に「前日以前は打刻変更申請（2-3）。代理打刻は当日のみ」を明記。

- [ ] **Step 2: ROADMAP 更新**

`docs/ROADMAP.md` の 1-3 行を `[x]` にし PR 番号を付す:

```markdown
- [x] **1-3 AttendanceHistory + 代理打刻**: 追記専用モデル（3 段不変防御・fx トリガー/TRUNCATE・§4.14）・代理打刻（§6.1・本人バナー前倒し・通知本体は Phase 4）（PR #NN）
```

横断バックログに追記: 「**本番 attendance_histories の owner 分離**（trigger は owner/superuser バイパス可 — app ロール≠owner を Phase 5-3 で）」「**§11.2 匿名化 vs 不変トリガー**（`_v01` 版差替で制御付きバイパス）」。

- [ ] **Step 3: RAILS_GOTCHAS 追記**

`docs/RAILS_GOTCHAS.md` に以下を WHAT/WHY/HOW で追記（verified 日付き）:
- fx SchemaDumper フック × exclusion-constraint パッチの共存（両者別メソッド prepend で順序非依存・round-trip 実証済）。
- 追記専用テーブルの拒否 spec は transactional fixtures 下で `transaction(requires_new:)` 隔離必須（RAISE が example tx を abort）。
- `policy_scope(Model)` の解決規則（top-level Policy 不在→NotDefinedError／別 Scope は `policy_scope_class:` 明示）。

- [ ] **Step 4: LABOR_LAW_REVIEW_NOTES に #17 を追記**

`docs/LABOR_LAW_REVIEW_NOTES.md` に社労士確認 #17 を追加（通知後送りの適否・`forgot_punch` の now 記録・`other` の証跡十分性。労基法 109 条 5 年保存は照合済 <https://laws.e-gov.go.jp/law/322AC0000000049>、適正把握ガイドライン基発0120第3号は未照合）。

- [ ] **Step 5: 全 spec + lint + brakeman**

Run:
```bash
bundle exec rspec
bundle exec rubocop --force-exclusion
bin/brakeman --no-pager
```
Expected: 全 PASS（rubocop は `--force-exclusion` 必須・db/schema.rb 偽 FAIL 回避）

- [ ] **Step 6: preflight**

Run: `/preflight`（push 前 CI 等価チェック）
Expected: 緑。

- [ ] **Step 7: コミット + PR**

```bash
git add docs/
git commit -m "docs: Phase 1-3 逆反映（SPEC §4.14/§3.4/§11.1/§6.8・ROADMAP・GOTCHAS・NOTES #17）"
git push -u github-kei1110 feat/phase1-3-attendance-history-proxy-clock
gh pr create --title "feat: Phase 1-3 AttendanceHistory（追記専用・3段不変防御）+ 代理打刻" --body "<実装サマリ・設計/計画リンク・テスト結果を記述>"
```

---

## Self-Review（writing-plans チェック）

**1. Spec coverage（§R 含む）:**
- §1 attendance_histories（actor_id/index/created_at のみ）→ Task 1 ✓
- §2 3 段不変防御（trigger/TRUNCATE/fx）→ Task 1-2、AR バイパス test §R-5 → Task 2 ✓
- R-1 source 同一テナント検証 / R-2 user/actor 検証 → Task 2 ✓
- R-3 trigger 脅威モデル → Task 7（SPEC/ROADMAP/GOTCHAS 逆反映）✓
- §3 proxy_clock_reason/note + 共有部品（R-4 recalculate_safely）→ Task 3 ✓
- §4 ProxyClockIn/Out（R-7 reason 必須・R-8 operator==target/cross_tenant・tx 境界）→ Task 4 ✓
- §5 Policy/Controller（R-13 IDOR/N+1 先読み）→ Task 5 ✓
- R-6 本人バナー → Task 6 ✓
- R-9 actor 必須 → Task 2 ✓ / R-11 §11.2・R-12 計算列契約 → Task 7 ✓
- docs 逆反映（§8）→ Task 7 ✓

**2. Placeholder scan:** PR body の `<...>`（Task 7 Step 7）のみ意図的プレースホルダ（実 PR 作成時に記述）。コードステップは全て実コード。

**3. Type consistency:** `Clockings.record_history(event_type:, organization:, user:, actor:, source:, note:, previous:, current:)` は Task 3 定義 ↔ Task 4 呼び出しで一致。`Result.new(success:, record:, error:)` は既存 `Clockings::Result` と一致。`roster` / `policy_scope_class:` は Task 5 内で一貫。`proxy_clock_reasons` キー（system_failure/unreachable/forgot_punch/other）は enum・i18n・UI・spec で一致。

**実装上の前提（要確認）:** `users` に複合一意 index `(organization_id, id)` が存在すること（0a/0b で確立・複合 FK の前提）。不在なら Task 1 で `add_index :users, %i[organization_id id], unique: true` を先行。
