# Phase 4-2a データ層 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 4-2（日次バッチ）が消費するデータ層を整える — AttendanceRecord の `absent` ステータス + 欠勤理由、欠勤候補テーブル `AbsenceCandidate`、インターバル/抑制の設定列、通知 source_type の拡張。

**Architecture:** 既存テーブルへの enum 値追加 + 列追加 + 新規テナント帰属テーブル 1 つ（複合 FK 二層防御）。reachable 面は持たない（データ層・§1.4 行なし）。後続の 4-2b 検知バッチ / 4-2c 欠勤確定 / 4-2d インターバルが消費する。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / acts_as_tenant / 複合 FK `[organization_id, id]`（§3.6）

**設計 SSOT:** `docs/superpowers/specs/2026-06-28-phase4-2-daily-batch-design.md` の **§3（データモデル）と §10（多視点レビュー binding 追補）**。本計画の各タスク要件は暗黙に §10 を含む。

## Global Constraints（§10 binding から・全タスクに適用）

- **テナント二層防御（§3.6）**: ユーザー参照は**複合 FK `[organization_id, user_id]→users[organization_id, id]`**（単純 FK 禁止）+ model `*_must_belong_to_same_organization`（ID 基点 fail-closed）。migration だけ／model だけは不可。`/create-migration` 規約に従う。
- **§10④ YAGNI（追加しない列）**: `daily_batch_hour`（recurring 固定ゆえ消費者なし）・`AbsenceCandidate.detected_on`（`created_at` で兼用）・`enforcement_mode`（§8.4 法改正後の将来拡張）は**追加しない**。`organization_settings` 追加は `rest_interval_hours` **1 列のみ**。
- **§10⑩**: `rest_interval_hours` 検証は **`1..24`**（0 はインターバル機能を無効化する穴ゆえ禁止）。
- **§10⑫**: AR.status は `absent` 追加で 6 状態だが **plain enum 継続**（単方向終端・副作用は後続 Service・AASM イベント不要）。
- **AttendanceHistory の `absence_confirmed`/`interval_shortage` は既存**（event_type enum に予約済 5/8）→ **本スライスでは追加しない**（消費は 4-2c/4-2d）。
- enum 不正値は代入時 `ArgumentError`→500 ゆえ `validate: true`（permit する列・RAILS_GOTCHAS）。`absence_reason` は `validate: { allow_nil: true }`（absent 以外 null）。
- schema は migration 経由のみ（`block-schema-edit` フック）。`bin/rails db:migrate && db:test:prepare` で schema.rb 自動更新（手編集しない）。`db/queue_schema.rb` の mtime ノイズは `git add` しない。
- **検証**: 各タスク完了条件に `bundle exec rspec <該当>` / `bundle exec rubocop --force-exclusion <files>`。models/migration に触れるゆえ**マージ前 `tenant-isolation-reviewer`**。

## File Structure

| ファイル | 責務 | タスク |
|----------|------|--------|
| `db/migrate/*_add_absence_reason_to_attendance_records.rb` | AR に `absence_reason` 列追加 | 1 |
| `app/models/attendance_record.rb`（変更） | `absent:5` status・`absence_reason` enum・`clockless_status?` 検証拡張・`absence_reason_only_on_absent` | 1 |
| `db/migrate/*_create_absence_candidates.rb` | 欠勤候補テーブル（複合 FK・unique index） | 2 |
| `app/models/absence_candidate.rb`（新規） | acts_as_tenant・複合 FK 検証・`scope :unnotified` | 2 |
| `spec/factories/absence_candidates.rb`（新規） | factory | 2 |
| `db/migrate/*_add_phase42_consuming_columns.rb` | MAS `interval_violation_count` + org_settings `rest_interval_hours` | 3 |
| `app/models/monthly_attendance_summary.rb`（変更） | `interval_violation_count` numericality | 3 |
| `app/models/organization_setting.rb`（変更） | `rest_interval_hours` inclusion 1..24 | 3 |
| `app/models/notification.rb`（変更） | `source_type` に 6 値 append | 4 |

---

## Task 1: AttendanceRecord に `absent` ステータス + 欠勤理由

**Files:**
- Create: `db/migrate/<ts>_add_absence_reason_to_attendance_records.rb`
- Modify: `app/models/attendance_record.rb`
- Test: `spec/models/attendance_record_spec.rb`

**Interfaces:**
- Consumes: 既存 AR（status enum 0..4・`LEAVE_STATUSES`・`clock_in presence unless leave_status?`）。
- Produces: `AttendanceRecord` が `status: :absent` + `absence_reason:` を**打刻なしで**有効に保存できる（4-2c 欠勤確定が消費）。

> **罠（設計が捉えていなかった correctness 穴）**: 既存 `validates :clock_in, presence: true, unless: :leave_status?` の `leave_status?` は `LEAVE_STATUSES = %w[morning_half afternoon_half on_leave]` のみ。`absent` は含まれないため、clock_in なしの `absent` AR は**この検証で invalid になる**。`absent` を「打刻なし」状態群に加える必要がある。`leave_type_only_on_leave_status` は `leave_status?`（leave のみ）のまま維持する（absent は leave_type を持たない）。

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/attendance_record_spec.rb` に追加（テナント文脈で）:

```ruby
  describe "absent ステータス（4-2）" do
    let(:org) { create(:organization) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "absent は打刻なしで有効（clock_in presence をスキップ）" do
      user = create(:user)
      ar = build(:attendance_record, user:, status: :absent, absence_reason: :unauthorized,
                                     clock_in: nil, work_date: Date.new(2026, 5, 1))
      expect(ar).to be_valid
    end

    it "absent + absence_reason を保存できる" do
      user = create(:user)
      ar = create(:attendance_record, user:, status: :absent, absence_reason: :illness, clock_in: nil)
      expect(ar.reload).to be_absent
      expect(ar.absence_reason).to eq("illness")
    end

    it "absence_reason は absent 以外の status では設定できない" do
      user = create(:user)
      ar = build(:attendance_record, user:, status: :working, absence_reason: :unauthorized)
      expect(ar).to be_invalid
      expect(ar.errors[:absence_reason]).to be_present
    end

    it "absent でも absence_reason は null 可（理由未入力の確定を許す前に弾かない）" do
      user = create(:user)
      ar = build(:attendance_record, user:, status: :absent, absence_reason: nil, clock_in: nil)
      expect(ar).to be_valid
    end

    it "absent は calculated スコープ外（計算 8 列 NULL）" do
      user = create(:user)
      create(:attendance_record, user:, status: :absent, absence_reason: :family, clock_in: nil)
      expect(AttendanceRecord.calculated).to be_empty
    end
  end
```

Run: `bundle exec rspec spec/models/attendance_record_spec.rb -e "absent ステータス"`
Expected: FAIL（`absent` enum 値なし → `ArgumentError` or invalid）。

- [ ] **Step 2: migration を生成して body を差し替え**

```bash
bin/rails generate migration AddAbsenceReasonToAttendanceRecords
```
生成された `db/migrate/<ts>_add_absence_reason_to_attendance_records.rb` の body を全置換:

```ruby
# frozen_string_literal: true

class AddAbsenceReasonToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    # enum・null 可（status: absent の時のみ非 null・§6.10）。consumer クエリ未確定ゆえ index は張らない（YAGNI）
    add_column :attendance_records, :absence_reason, :integer
  end
end
```

- [ ] **Step 3: migrate**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `db/schema.rb` に `absence_reason` 列が自動追記される。

- [ ] **Step 4: モデルを実装**

`app/models/attendance_record.rb` を変更:

(1) status enum に `absent: 5` を追加:
```ruby
  enum :status, { working: 0, clocked_out: 1,
                  morning_half: 2, afternoon_half: 3, on_leave: 4, absent: 5 }, validate: true
```

(2) `LEAVE_STATUSES` の直後に `NO_CLOCK_STATUSES` と `absence_reason` enum を追加:
```ruby
  LEAVE_STATUSES = %w[morning_half afternoon_half on_leave].freeze

  # 「打刻なし」状態群 = 休暇 + 欠勤（4-2）。clock_in presence 検証のスキップ対象。
  # leave_type は休暇のみ（absent は leave_type なし）ゆえ LEAVE_STATUSES と別概念。
  NO_CLOCK_STATUSES = (LEAVE_STATUSES + %w[absent]).freeze

  # 欠勤確定時の理由（§6.10）。null = absent 以外。permit ゆえ毒入力のみ 422（allow_nil）
  enum :absence_reason, { unauthorized: 0, illness: 1, family: 2, investigating: 3, other: 4 },
       validate: { allow_nil: true }
```

(3) `clock_in` presence 検証の条件を `leave_status?` → `clockless_status?` に変更し、`absence_reason_only_on_absent` 検証を追加:
```ruby
  validates :clock_in, presence: true, unless: :clockless_status?
```
```ruby
  validate :leave_type_only_on_leave_status
  validate :absence_reason_only_on_absent
```

(4) private に述語と検証を追加:
```ruby
  def leave_status? = LEAVE_STATUSES.include?(status)
  def clockless_status? = NO_CLOCK_STATUSES.include?(status)

  def absence_reason_only_on_absent
    return if absence_reason.nil? || absent?

    errors.add(:absence_reason, "は欠勤ステータスの記録にのみ設定できます")
  end
```

- [ ] **Step 5: テストを通す**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb`
Expected: 全 PASS（新規 absent 群 + 既存例が回帰なし）。

- [ ] **Step 6: rubocop**

Run: `bundle exec rubocop --force-exclusion app/models/attendance_record.rb`
Expected: 0 offenses。

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/attendance_record.rb spec/models/attendance_record_spec.rb
git commit -m "feat: AttendanceRecord に absent ステータス + 欠勤理由（打刻なし検証対応）"
```

---

## Task 2: AbsenceCandidate テーブル + モデル

**Files:**
- Create: `db/migrate/<ts>_create_absence_candidates.rb`
- Create: `app/models/absence_candidate.rb`
- Create: `spec/factories/absence_candidates.rb`
- Test: `spec/models/absence_candidate_spec.rb`

**Interfaces:**
- Consumes: `users`（複合 FK 標的 `[organization_id, id]` 既存）。
- Produces: `AbsenceCandidate`（4-2b バッチが upsert・4-2c 欠勤確定が権威源として消費）。`scope :unnotified`。

> §3.2 / §10④（`detected_on` なし・`created_at` が検知日を兼ねる）。複合 FK + model 検証で二層（§3.6）。unique `[org, user, target_date]` が同一候補の二重生成を DB で排除（§10⑨ の `insert_all` upsert はバッチ側 4-2b の話・本タスクは index のみ用意）。

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/absence_candidate_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbsenceCandidate, type: :model do
  let(:org) { create(:organization) }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  it "有効な候補を作成できる" do
    user = create(:user)
    expect(build(:absence_candidate, user:, target_date: Date.new(2026, 5, 1))).to be_valid
  end

  it "同一 (user, target_date) は二重作成できない（テナント内 unique）" do
    user = create(:user)
    create(:absence_candidate, user:, target_date: Date.new(2026, 5, 1))
    dup = build(:absence_candidate, user:, target_date: Date.new(2026, 5, 1))
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "scope :unnotified は notified_on 未設定のみ" do
    user = create(:user)
    pending = create(:absence_candidate, user:, target_date: Date.new(2026, 5, 1), notified_on: nil)
    notified = create(:absence_candidate, user:, target_date: Date.new(2026, 5, 2), notified_on: Date.current)
    expect(described_class.unnotified).to include(pending)
    expect(described_class.unnotified).not_to include(notified)
  end

  describe "同一組織強制（§3.6・二層防御）" do
    let(:other) { create(:organization) }
    let(:other_user) { ActsAsTenant.with_tenant(other) { create(:user) } }

    it "他組織 user の候補は DB 複合 FK で拒否（model 層を貫通）" do
      c = build(:absence_candidate, user: nil, target_date: Date.new(2026, 5, 1))
      c.user_id = other_user.id # 他組織 id を直挿（acts_as_tenant の nil ロードを迂回）
      expect { c.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  it "他テナントの候補は default scope で見えない" do
    other = create(:organization)
    ActsAsTenant.with_tenant(other) { create(:absence_candidate, user: create(:user)) }
    expect(described_class.count).to eq(0) # org 文脈では他社 0 件
  end
end
```

Run: `bundle exec rspec spec/models/absence_candidate_spec.rb`
Expected: FAIL（テーブル/モデル/factory なし）。

- [ ] **Step 2: migration を生成して body を差し替え**

```bash
bin/rails generate migration CreateAbsenceCandidates
```
body を全置換（`/create-migration` §1 idiom）:

```ruby
# frozen_string_literal: true

class CreateAbsenceCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :absence_candidates do |t|
      t.references :organization, null: false, foreign_key: true # テナントルートは単純 FK
      t.bigint :user_id, null: false                             # 複合 FK ゆえ references にしない
      t.date :target_date, null: false                           # 未打刻の対象日
      t.date :notified_on                                        # null = 未通知（notify-once・§4.4）
      t.timestamps                                               # created_at = 検知日（detected_on は持たない・§10④）
    end

    add_index :absence_candidates, %i[organization_id id], unique: true # 複合 FK 標的（idiom 統一）
    add_index :absence_candidates, %i[organization_id user_id target_date],
              unique: true, name: "idx_absence_candidates_unique" # 同一候補の二重生成を排除
    add_index :absence_candidates, %i[organization_id user_id],
              name: "idx_absence_candidates_org_user" # 一覧/解決スキャン
    add_foreign_key :absence_candidates, :users,
                    column: %i[organization_id user_id], primary_key: %i[organization_id id]
  end
end
```

- [ ] **Step 3: migrate**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: schema.rb に `absence_candidates` テーブル + 3 index + 複合 FK。

- [ ] **Step 4: モデルを実装**

`app/models/absence_candidate.rb`:

```ruby
# frozen_string_literal: true

# 欠勤候補（no AR ∧ no LR の未打刻日・§6.8/§6.10）。存在 = 未解決・削除 = resolve（ephemeral）。
# 監査は AttendanceHistory(absence_confirmed) が担い、本テーブルは作業状態。4-2b が upsert・4-2c が権威源。
class AbsenceCandidate < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user

  scope :unnotified, -> { where(notified_on: nil) }

  validate :user_must_belong_to_same_organization

  private

  # ID 基点 fail-closed（§3.6・複合 FK と二層）
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id

    errors.add(:user, "は同一組織でなければなりません")
  end
end
```

- [ ] **Step 5: factory を作成**

`spec/factories/absence_candidates.rb`:

```ruby
# frozen_string_literal: true

FactoryBot.define do
  factory :absence_candidate do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user { association(:user) }
    target_date { Date.new(2026, 5, 1) }
    notified_on { nil }
  end
end
```

- [ ] **Step 6: テストを通す**

Run: `bundle exec rspec spec/models/absence_candidate_spec.rb`
Expected: 全 PASS。

- [ ] **Step 7: rubocop**

Run: `bundle exec rubocop --force-exclusion app/models/absence_candidate.rb spec/factories/absence_candidates.rb spec/models/absence_candidate_spec.rb`
Expected: 0 offenses。

- [ ] **Step 8: Commit**

```bash
git add db/migrate db/schema.rb app/models/absence_candidate.rb spec/factories/absence_candidates.rb spec/models/absence_candidate_spec.rb
git commit -m "feat: AbsenceCandidate テーブル（欠勤候補・複合 FK 二層・notify-once 列）"
```

---

## Task 3: 消費列追加（MAS interval_violation_count + org_settings rest_interval_hours）

**Files:**
- Create: `db/migrate/<ts>_add_phase42_consuming_columns.rb`
- Modify: `app/models/monthly_attendance_summary.rb`
- Modify: `app/models/organization_setting.rb`
- Test: `spec/models/monthly_attendance_summary_spec.rb` / `spec/models/organization_setting_spec.rb`

**Interfaces:**
- Consumes: 既存 MAS / OrganizationSetting。
- Produces: `MonthlyAttendanceSummary#interval_violation_count`（4-2d IntervalCheck がインクリメント）/ `OrganizationSetting#rest_interval_hours`（4-2d が閾値参照）。

> §10④（org_settings は `rest_interval_hours` 1 列のみ・`daily_batch_hour` なし）/ §10⑩（`rest_interval_hours` は `1..24`・0 禁止）。`interval_violation_count` は AGGREGATE_COLUMNS に**入れない**（§5 集計でなく打刻時インクリメント）。

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/monthly_attendance_summary_spec.rb` に追加:
```ruby
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
```

`spec/models/organization_setting_spec.rb` に追加（org 文脈・OrganizationSetting は lazy 生成ゆえ org.setting を使う）:
```ruby
  describe "rest_interval_hours（4-2・§10⑩）" do
    let(:org) { create(:organization) }

    it "既定は 11" do
      ActsAsTenant.with_tenant(org) { expect(org.setting.rest_interval_hours).to eq(11) }
    end

    it "1..24 の範囲外は無効（0 はインターバル無効化ゆえ禁止）" do
      ActsAsTenant.with_tenant(org) do
        s = org.setting
        s.rest_interval_hours = 0
        expect(s).to be_invalid
        s.rest_interval_hours = 25
        expect(s).to be_invalid
        s.rest_interval_hours = 11
        expect(s).to be_valid
      end
    end
  end
```

Run: `bundle exec rspec spec/models/monthly_attendance_summary_spec.rb spec/models/organization_setting_spec.rb`
Expected: FAIL（列/検証なし）。

- [ ] **Step 2: migration を生成して body を差し替え**

```bash
bin/rails generate migration AddPhase42ConsumingColumns
```
body を全置換:
```ruby
# frozen_string_literal: true

class AddPhase42ConsumingColumns < ActiveRecord::Migration[8.1]
  def change
    # §6.9/§8.4 月内インターバル違反回数（打刻時インクリメント・集計列ではない）
    add_column :monthly_attendance_summaries, :interval_violation_count, :integer, null: false, default: 0
    # §6.9 勤務間インターバル閾値（既定 11h・§10④ daily_batch_hour は追加しない）
    add_column :organization_settings, :rest_interval_hours, :integer, null: false, default: 11
  end
end
```

- [ ] **Step 3: migrate**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: 両列が schema.rb に追記。

- [ ] **Step 4: モデルを実装**

`app/models/monthly_attendance_summary.rb` の validates 群に追加:
```ruby
  validates :interval_violation_count, numericality: { greater_than_or_equal_to: 0 }
```

`app/models/organization_setting.rb` の validates 群に追加:
```ruby
  validates :rest_interval_hours, inclusion: { in: 1..24 } # 0 はインターバル機能を無効化する穴（§10⑩）
```

- [ ] **Step 5: テストを通す**

Run: `bundle exec rspec spec/models/monthly_attendance_summary_spec.rb spec/models/organization_setting_spec.rb`
Expected: 全 PASS。

- [ ] **Step 6: rubocop**

Run: `bundle exec rubocop --force-exclusion app/models/monthly_attendance_summary.rb app/models/organization_setting.rb`
Expected: 0 offenses。

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/monthly_attendance_summary.rb app/models/organization_setting.rb spec/models/monthly_attendance_summary_spec.rb spec/models/organization_setting_spec.rb
git commit -m "feat: interval_violation_count（MAS）+ rest_interval_hours（org・1..24）"
```

---

## Task 4: Notification.source_type に 4-2 の 6 値を append

**Files:**
- Modify: `app/models/notification.rb`
- Test: `spec/models/notification_spec.rb`

**Interfaces:**
- Consumes: 既存 `Notification`（source_type enum `request_approved:0, request_rejected:1`）。
- Produces: 4-2 の producer/バッチが使う source_type（4-2b/4-2c/4-2d が消費）。

> append-only integer enum ゆえ**列追加なし・model 編集のみ**（migration 不要）。全 6 値に本 Phase の consumer がある（§10 是認）。

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/notification_spec.rb` に追加:
```ruby
  describe "source_type 4-2 拡張" do
    let(:org) { create(:organization) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    %i[clock_out_missing absence_candidate leave_pending_no_clock proxy_clocked interval_shortage absence_confirmed]
      .each do |st|
      it "source_type: #{st} で有効に作成できる" do
        n = build(:notification, target_user: create(:user), source_type: st)
        expect(n).to be_valid
        expect(n.source_type).to eq(st.to_s)
      end
    end
  end
```

Run: `bundle exec rspec spec/models/notification_spec.rb -e "source_type 4-2"`
Expected: FAIL（enum 値なし → `ArgumentError`）。

- [ ] **Step 2: enum を拡張**

`app/models/notification.rb` の source_type enum を変更:
```ruby
  # 後続 Phase が値を追加（integer enum ゆえ model 編集のみ・append-only）
  enum :source_type, { request_approved: 0, request_rejected: 1,
                       clock_out_missing: 2, absence_candidate: 3, leave_pending_no_clock: 4,
                       proxy_clocked: 5, interval_shortage: 6, absence_confirmed: 7 }, validate: true
```

- [ ] **Step 3: テストを通す**

Run: `bundle exec rspec spec/models/notification_spec.rb`
Expected: 全 PASS（新 6 値 + 既存例が回帰なし）。

- [ ] **Step 4: rubocop**

Run: `bundle exec rubocop --force-exclusion app/models/notification.rb`
Expected: 0 offenses。

- [ ] **Step 5: Commit**

```bash
git add app/models/notification.rb spec/models/notification_spec.rb
git commit -m "feat: Notification.source_type に 4-2 の 6 値 append（検知/欠勤/代理/インターバル）"
```

---

## 仕上げ（全タスク後）

1. **全スイート + 静的検証**:
   - `bundle exec rspec`（全緑・既存 pending は Approvals 自己承認 #2 のみ）
   - `bundle exec rubocop --force-exclusion $(git diff --name-only main...HEAD | grep '\.rb$')`
   - `bin/brakeman --no-pager`（app/ 変更ゆえ）
2. **設計書を本ブランチに含める**: `docs/superpowers/specs/2026-06-28-phase4-2-daily-batch-design.md` を 4-2a の PR に同梱（4-1a で design を #22 に入れた前例）。本計画 `docs/superpowers/plans/2026-06-29-phase4-2a-data-layer.md` も同梱。
3. **マージ前レビュアー**: `tenant-isolation-reviewer`（AbsenceCandidate の複合 FK 二層・他テーブル変更のテナント安全）。
4. **ROADMAP**: 4-2 行に「4-2a データ層 ✅ PR #<番号>」を追記（4-1 同様 PR 作成後に番号確定）。
5. **RAILS_GOTCHAS 還流**: 新たに踏んだ罠（例: absent の clock_in presence 検証穴）があれば本 PR で追記。

## Self-Review（writing-plans 規約）

- **Spec coverage（設計 §3 + §10）**: AR absent/absence_reason=Task1（+ §10 が捉えなかった clock_in 検証穴を Task1 が解消）/ AbsenceCandidate（detached detected_on・§10④）=Task2 / interval_violation_count + rest_interval_hours（1 列のみ・1..24・§10④⑩）=Task3 / source_type 6 値=Task4。AttendanceHistory event_type は既存ゆえ非対象（Global Constraints に明記）。daily_batch_hour/enforcement_mode は §10④ で不追加。
- **Placeholder scan**: 全コードは実コード。PR 番号のみ後埋め（明示）。`<ts>` は generate が確定。
- **Type consistency**: `NO_CLOCK_STATUSES`/`clockless_status?`（Task1 で定義→clock_in 検証が参照）/ `AbsenceCandidate.unnotified`（Task2 定義・4-2b 消費）/ source_type 値（Task4・4-2b/c/d 消費）/ 複合 FK `[organization_id, user_id]→users[organization_id, id]`（users の `[org,id] unique` 既存・4-1a 実績）— 整合確認済。
