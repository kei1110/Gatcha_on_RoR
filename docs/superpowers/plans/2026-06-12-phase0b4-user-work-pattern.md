# Phase 0b-4 UserWorkPattern 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 勤務パターン割当（UserWorkPattern）の CRUD・期間重複の二重防衛（モデル検証 + PostgreSQL exclusion constraint）・WorkPattern 無効化ガードを、社員詳細ネスト UI で出荷する。

**Architecture:** 設計仕様 [docs/superpowers/specs/2026-06-12-phase0b4-user-work-pattern-design.md](../specs/2026-06-12-phase0b4-user-work-pattern-design.md)（§番号は本計画から参照）。acts_as_tenant + 複合 FK のテナント二重防衛、`Organization#today`（組織 TZ）への「今日」一本化、`effective_on` scope を Phase 1 取得述語の単一ソースとする。

**Tech Stack:** Rails 8.1 / PostgreSQL 17（btree_gist・EXCLUDE）/ acts_as_tenant / Pundit / RSpec + FactoryBot

**ブランチ:** `feat/0b-4-user-work-pattern`（作成済み・設計コミット 71bd95f が先頭にある）

---

## 前提知識（RAILS_GOTCHAS 注入 — 違反すると過去に踏んだ虫を買い直す）

1. **書き込み系 redirect は一律 `status: :see_other`**（Turbo は 302 だと PATCH を redirect 先へ再発行）。失敗 render は `status: :unprocessable_entity`
2. **バリデーション内のスコープ依存クエリは fail-open し得る** — 本スライスのクエリは全て「②型」: グローバル一意キー（user_id / work_pattern_id）+ 複合 FK 保護 + `ActsAsTenant.without_tenant` ラップ。organization_id 明示が要る「①型」（COUNT 系）は本スライスに無い。**実装コメントに②型の根拠を残すこと**
3. **request spec の setup のモデル操作は `ActsAsTenant.with_tenant(org) { ... }` で包む**（request spec は意図的にテナント未設定。`NoTenantSet` はガードが正しい証拠であり、ガード側を緩めない）
4. **enum validate / permit 境界** — 本スライスに enum 新設は無いが、permit は `work_pattern_id / start_date / end_date` の 3 つだけ。`user_id`（URL から）・`active`（メンバーアクション専用）・`organization_id` は permit しない
5. **サブエージェントはフックをすり抜ける** — 各タスクの完了条件: `bundle exec rspec`（全 suite green）+ `bundle exec rubocop --force-exclusion <触ったファイル>`。app/ に触れたタスクは最後に `bin/brakeman --no-pager -q -w2`。**ステップ完了ごとに即コミット**・探索で触った不要編集は revert してから報告
6. **db/schema.rb は手編集禁止**（migration 経由のみ。block-schema-edit フックは subagent に効かないため自律遵守）
7. rescue は **`ActiveRecord::ExclusionViolation` に限定**（Rails 8.1 で StatementInvalid から分化済み。広く取ると無関係な SQL 失敗が「競合しました」に化ける）

---

### Task 1: Organization#today（組織 TZ の「今日」単一ソース）

**Files:**
- Modify: `app/models/organization.rb`
- Test: `spec/models/organization_spec.rb`（既存ファイルに describe 追加）

- [ ] **Step 1: TimeHelpers の有効化を確認**

Run: `grep -rn "TimeHelpers" spec/`
ヒットが無ければ `spec/support/time_helpers.rb` を作成:

```ruby
RSpec.configure do |config|
  config.include ActiveSupport::Testing::TimeHelpers
end
```

- [ ] **Step 2: 失敗するテストを書く**

`spec/models/organization_spec.rb` の `RSpec.describe Organization` 内に追加:

```ruby
  describe "#today（0b-4 設計 §0 の TZ 契約）" do
    it "組織 TZ の当日を返す（アプリ TZ = UTC と日付が割れる時刻帯）" do
      org = build(:organization, time_zone: "Asia/Tokyo")
      travel_to Time.utc(2026, 6, 11, 20, 0) do # JST 2026-06-12 05:00
        expect(Date.current).to eq(Date.new(2026, 6, 11)) # 前提の固定: アプリ TZ では前日
        expect(org.today).to eq(Date.new(2026, 6, 12))
      end
    end

    it "UTC 組織なら Date.current と一致する" do
      org = build(:organization, time_zone: "UTC")
      travel_to Time.utc(2026, 6, 11, 20, 0) do
        expect(org.today).to eq(Date.new(2026, 6, 11))
      end
    end
  end
```

- [ ] **Step 3: 失敗を確認**

Run: `bundle exec rspec spec/models/organization_spec.rb -e "#today"`
Expected: FAIL（`NoMethodError: undefined method 'today'`）

- [ ] **Step 4: 実装**

`app/models/organization.rb` の `fiscal_year_for` の下に追加:

```ruby
  # 「今日」の単一ソース（組織 TZ・0b-4 設計 §0）。config.time_zone は未設定（UTC）のため
  # Date.current は JST 0:00〜8:59 に前日を返す。WorkPattern 無効化ガード・割当の表示分類・
  # 未割当バナー（Phase 1 の打刻日判定もここに合流予定）は必ずこれを使うこと
  def today
    Time.current.in_time_zone(time_zone).to_date
  end
```

- [ ] **Step 5: テスト green を確認して commit**

Run: `bundle exec rspec spec/models/organization_spec.rb && bundle exec rubocop --force-exclusion app/models/organization.rb spec/models/organization_spec.rb`
Expected: PASS / no offenses

```bash
git add app/models/organization.rb spec/models/organization_spec.rb spec/support/time_helpers.rb
git commit -m "feat: Organization#today（組織 TZ の当日・0b-4 TZ 契約）"
```

---

### Task 2: migration（btree_gist + user_work_patterns + 複合 FK + exclusion constraint）

**Files:**
- Create: `db/migrate/<timestamp>_create_user_work_patterns.rb`（generator で生成して中身を差し替え）
- 自動更新: `db/schema.rb`（手編集禁止）

- [ ] **Step 1: migration 生成**

Run: `bin/rails generate migration CreateUserWorkPatterns`

- [ ] **Step 2: 生成ファイルの中身を以下に置き換え**

```ruby
class CreateUserWorkPatterns < ActiveRecord::Migration[8.1]
  def change
    # bigint の = と daterange の && を 1 つの GiST インデックスに同居させるため必須
    enable_extension "btree_gist"

    create_table :user_work_patterns do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.bigint :work_pattern_id, null: false
      t.date :start_date, null: false
      t.date :end_date # null = 無期限（SPEC §4.6）
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    # クロステナント割当を DB 層で構造的に遮断（users.manager_id と同じ複合 FK パターン・SPEC §3.6）
    add_foreign_key :user_work_patterns, :users,
                    column: [ :organization_id, :user_id ], primary_key: [ :organization_id, :id ]
    add_foreign_key :user_work_patterns, :work_patterns,
                    column: [ :organization_id, :work_pattern_id ], primary_key: [ :organization_id, :id ]

    add_index :user_work_patterns, :user_id
    add_index :user_work_patterns, :work_pattern_id # WorkPattern 無効化ガードの参照クエリ用
    # プロジェクト規約（将来の複合 FK 参照先）。被参照予定は現状なし — 規約準拠のため（0b-4 設計 §1）
    add_index :user_work_patterns, %i[organization_id id], unique: true

    # 期間重複の最終防衛（TOCTOU 競合窓・mismatched with_tenant 時のモデル検証取りこぼしを拾う）。
    # organization_id WITH = は意味論上冗長（user_id 全域一意 + 複合 FK で単一テナント保証）だが
    # 「複合一意制約に organization_id を必ず含める」規約（SPEC §2.2）に整合させる。
    # daterange(s, e, '[]') は [s, e+1day) に正規化・end_date NULL は上限無限。
    # WHERE (active) で無効割当（誤登録の論理削除）は対象外 — 作り直しを妨げない
    add_exclusion_constraint :user_work_patterns,
      "organization_id WITH =, user_id WITH =, daterange(start_date, end_date, '[]') WITH &&",
      using: :gist, where: "active", name: "user_work_patterns_no_overlap"
  end
end
```

- [ ] **Step 3: migrate 実行と schema 確認**

Run: `bin/rails db:migrate && git diff db/schema.rb`
Expected: schema.rb に `enable_extension "btree_gist"`・`t.exclusion_constraint`（where: "active" 付き。PostgreSQL 正規化形 `'[]'::text` 等のキャストが出るのは正常）・複合 FK 2 本が現れる

- [ ] **Step 4: schema ラウンドトリップ確認（設計 §1 の完了条件）**

Run:
```bash
RAILS_ENV=test bin/rails db:schema:load db:schema:dump && git diff --exit-code db/schema.rb
```
Expected: exit 0（load → dump で差分ゼロ — exclusion constraint が schema.rb で完全に往復できる）

- [ ] **Step 5: Commit**

```bash
git add db/migrate db/schema.rb
git commit -m "feat: user_work_patterns テーブル（複合 FK・btree_gist exclusion constraint）"
```

---

### Task 3: UserWorkPattern モデル + factory + model spec

**Files:**
- Create: `app/models/user_work_pattern.rb`
- Create: `spec/factories/user_work_patterns.rb`
- Create: `spec/models/user_work_pattern_spec.rb`
- Modify: `app/models/user.rb`（has_many 1 行）

- [ ] **Step 1: factory を書く**

`spec/factories/user_work_patterns.rb`:

```ruby
FactoryBot.define do
  factory :user_work_pattern do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user
    work_pattern
    start_date { Date.new(2026, 4, 1) }
  end
end
```

- [ ] **Step 2: 失敗する model spec を書く**

`spec/models/user_work_pattern_spec.rb`（全文）:

```ruby
require "rails_helper"

RSpec.describe UserWorkPattern, type: :model do
  let(:user)    { create(:user) }
  let(:pattern) { create(:work_pattern) }

  describe "期間重複（SPEC §4.6・0b-4 設計 §2-2）" do
    let!(:existing) do
      create(:user_work_pattern, user: user, work_pattern: pattern,
             start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30))
    end

    def build_overlap(start_date:, end_date: nil)
      build(:user_work_pattern, user: user, work_pattern: pattern,
            start_date: start_date, end_date: end_date)
    end

    it "包含（既存の内側）は拒否" do
      expect(build_overlap(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 31))).not_to be_valid
    end

    it "部分交差（末尾に重なる）は拒否" do
      expect(build_overlap(start_date: Date.new(2026, 6, 30), end_date: Date.new(2026, 12, 31))).not_to be_valid
    end

    it "隣接（既存終了の翌日から）は許可" do
      expect(build_overlap(start_date: Date.new(2026, 7, 1))).to be_valid
    end

    it "無期限の新規が既存に被さるのは拒否" do
      expect(build_overlap(start_date: Date.new(2026, 1, 1))).not_to be_valid
    end

    it "無期限の既存と未来の新規は拒否（end_date NULL = 全未来日と重複扱い・SPEC §4.6）" do
      other = create(:user)
      create(:user_work_pattern, user: other, work_pattern: pattern,
             start_date: Date.new(2026, 1, 1)) # end nil
      dup = build(:user_work_pattern, user: other, work_pattern: pattern,
                  start_date: Date.new(2030, 1, 1))
      expect(dup).not_to be_valid
    end

    it "active=false の既存とは重複可（誤登録の作り直しを妨げない）" do
      existing.update_column(:active, false)
      expect(build_overlap(start_date: Date.new(2026, 5, 1))).to be_valid
    end

    it "他ユーザーの割当とは不問" do
      other = create(:user)
      expect(build(:user_work_pattern, user: other, work_pattern: pattern,
                   start_date: Date.new(2026, 5, 1))).to be_valid
    end

    it "自分自身は除外（update で期間を変えられる）" do
      existing.end_date = Date.new(2026, 5, 31)
      expect(existing).to be_valid
    end

    it "エラー文言に衝突相手の期間を含む" do
      record = build_overlap(start_date: Date.new(2026, 5, 1))
      record.valid?
      expect(record.errors[:base].join).to include("2026-04-01").and include("2026-06-30")
    end

    it "activate 経由（update(active: true)）でも重複拒否 + 衝突相手期間入り文言（0b-4 設計 §2-2 発火条件）" do
      overlapped = create(:user_work_pattern, user: user, work_pattern: pattern,
                          start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 31), active: false)
      expect(overlapped.update(active: true)).to be(false)
      expect(overlapped.errors[:base].join).to include("重複")
    end

    it "mismatched with_tenant 文脈でも重複を検出する（without_tenant ラップの固定・設計 §2-2）" do
      other_org = create(:organization)
      dup = build_overlap(start_date: Date.new(2026, 5, 1))
      ActsAsTenant.with_tenant(other_org) do
        expect(dup).not_to be_valid
      end
    end
  end

  describe "日付" do
    it "start_date 必須" do
      record = build(:user_work_pattern, user: user, work_pattern: pattern, start_date: nil)
      expect(record).not_to be_valid
      expect(record.errors[:start_date]).to be_present
    end

    it "end_date < start_date はバリデーションで拒否（daterange の DB エラーに先回り）" do
      record = build(:user_work_pattern, user: user, work_pattern: pattern,
                     start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 3, 31))
      expect(record).not_to be_valid
      expect(record.errors[:end_date]).to be_present
    end

    it "end_date = start_date（1 日だけの割当）は許可" do
      expect(build(:user_work_pattern, user: user, work_pattern: pattern,
                   start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 4, 1))).to be_valid
    end
  end

  describe "勤務パターン整合（fail-closed・0b-4 設計 §2-3）" do
    it "inactive パターンの新規割当は拒否" do
      retired = create(:work_pattern, active: false)
      record = build(:user_work_pattern, user: user, work_pattern: retired)
      expect(record).not_to be_valid
      expect(record.errors[:work_pattern_id].join).to include("有効な勤務パターン")
    end

    it "パターン変更で inactive を指定すると拒否" do
      record = create(:user_work_pattern, user: user, work_pattern: pattern)
      retired = create(:work_pattern, active: false)
      record.work_pattern_id = retired.id
      expect(record).not_to be_valid
    end

    it "他テナントの work_pattern_id は nil 解決でも明示エラー（改竄 POST を 422 で止める）" do
      other_pattern = ActsAsTenant.with_tenant(create(:organization)) { create(:work_pattern) }
      record = build(:user_work_pattern, user: user)
      record.work_pattern_id = other_pattern.id
      expect(record).not_to be_valid
      expect(record.errors[:work_pattern_id].join).to include("同一組織")
    end

    it "無関係カラムの更新ではパターン再チェックしない（無効パターン参照の過去割当の end_date 編集が通る）" do
      record = create(:user_work_pattern, user: user, work_pattern: pattern,
                      start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31))
      pattern.update_column(:active, false) # ガードを通さず無効化された状態を再現
      record.end_date = Date.new(2026, 2, 28)
      expect(record).to be_valid
    end

    it "再有効化時に inactive パターンなら拒否（active になる遷移で再チェック）" do
      record = create(:user_work_pattern, user: user, work_pattern: pattern, active: false)
      pattern.update_column(:active, false)
      expect(record.update(active: true)).to be(false)
      expect(record.errors[:work_pattern_id]).to be_present
    end
  end

  describe "exclusion constraint（DB 最終防衛・0b-4 設計 §1）" do
    it "バリデーション skip の重複 INSERT は ActiveRecord::ExclusionViolation" do
      create(:user_work_pattern, user: user, work_pattern: pattern,
             start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30))
      dup = build(:user_work_pattern, user: user, work_pattern: pattern,
                  start_date: Date.new(2026, 5, 1))
      expect { dup.save(validate: false) }.to raise_error(ActiveRecord::ExclusionViolation)
    end

    it "inactive 行は constraint の対象外（WHERE active）" do
      create(:user_work_pattern, user: user, work_pattern: pattern,
             start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30), active: false)
      dup = build(:user_work_pattern, user: user, work_pattern: pattern,
                  start_date: Date.new(2026, 5, 1))
      expect { dup.save(validate: false) }.not_to raise_error
    end
  end

  describe ".effective_on（Phase 1 取得述語の単一ソース・0b-4 設計 §2）" do
    let!(:assignment) do
      create(:user_work_pattern, user: user, work_pattern: pattern,
             start_date: Date.new(2026, 4, 1), end_date: Date.new(2026, 6, 30))
    end

    it "開始当日・終了当日は含む / 範囲外は含まない" do
      expect(described_class.effective_on(Date.new(2026, 4, 1))).to contain_exactly(assignment)
      expect(described_class.effective_on(Date.new(2026, 6, 30))).to contain_exactly(assignment)
      expect(described_class.effective_on(Date.new(2026, 3, 31))).to be_empty
      expect(described_class.effective_on(Date.new(2026, 7, 1))).to be_empty
    end

    it "無期限（end_date NULL）は全未来日で有効" do
      assignment.update!(end_date: nil)
      expect(described_class.effective_on(Date.new(2030, 1, 1))).to contain_exactly(assignment)
    end

    it "inactive は除外" do
      assignment.update_column(:active, false)
      expect(described_class.effective_on(Date.new(2026, 5, 1))).to be_empty
    end
  end
end
```

- [ ] **Step 3: 失敗を確認**

Run: `bundle exec rspec spec/models/user_work_pattern_spec.rb`
Expected: FAIL（`NameError: uninitialized constant UserWorkPattern`）

- [ ] **Step 4: モデル実装**

`app/models/user_work_pattern.rb`（全文）:

```ruby
class UserWorkPattern < ApplicationRecord
  # 意味論（0b-4 設計 §0）: active=false は「誤登録の論理削除」専用。
  # 正常な終了・切替は end_date で表現する（切替 = 旧割当の end_date 設定 → 新規作成）。
  # 無効化は過去日の所定根拠を消すための操作ではない。
  # 過去割当は Phase 1 の「未打刻日の所定根拠」として温存（destroy ルートなし）
  acts_as_tenant(:organization)

  belongs_to :user
  belongs_to :work_pattern

  # Phase 1 の打刻時取得（SPEC §4.6「打刻日時点で有効な 1 件」）と未割当バナーの単一ソース。
  # この述語を他所に二度書かないこと（定義が割れると Phase 1 接続が穴あきになる）
  scope :effective_on, ->(date) {
    where(active: true)
      .where(start_date: ..date)
      .where("end_date IS NULL OR end_date >= ?", date)
  }

  validates :start_date, presence: true
  validate :end_date_not_before_start_date
  # 発火条件は「保存後に active であるすべての保存」（0b-4 設計 §2-2）—
  # create / update / activate（update(active: true)）が単一の検証に収束する
  validate :no_overlap_with_active_assignments, if: :active?
  validate :work_pattern_must_be_active_and_same_tenant,
           if: -> { new_record? || work_pattern_id_changed? || (active_changed? && active?) }

  private

  def end_date_not_before_start_date
    return if start_date.blank? || end_date.blank? || end_date >= start_date

    errors.add(:end_date, "は適用開始日以降の日付にしてください")
  end

  # ②型クエリ（RAILS_GOTCHAS の①型/②型書き分け）: user_id は全域一意 PK + 複合 FK
  # (organization_id, user_id) が越境を排除するため organization_id 明示不要。
  # without_tenant ラップで mismatched with_tenant 文脈（console で他社テナント設定中の操作）
  # でも default scope に実在行を隠されない。
  # 式は DB の exclusion constraint と同一の daterange '[]' — 意味の二重実装を避ける
  def no_overlap_with_active_assignments
    return if user_id.blank? || start_date.blank?
    return if end_date.present? && end_date < start_date # daterange が逆転で DB エラーになる入力は日付検証に委ねる

    conflict = ActsAsTenant.without_tenant do
      UserWorkPattern.where(user_id: user_id, active: true).where.not(id: id)
                     .where("daterange(start_date, end_date, '[]') && daterange(?, ?, '[]')",
                            start_date, end_date)
                     .order(:start_date).first
    end
    return if conflict.nil?

    period = conflict.end_date ? "#{conflict.start_date} 〜 #{conflict.end_date}" : "#{conflict.start_date} 〜（無期限）"
    errors.add(:base, "適用期間が既存の割当（#{period}）と重複しています")
  end

  # fail-closed（user.rb の manager_must_belong_to_same_organization と同型・0b-4 設計 §2-3）:
  # テナントスコープ下では他テナント id の association 解決が nil になるため、
  # without_tenant で実体を引き、nil（=実在しない）と組織不一致を明示エラーにする。
  # 改竄 POST を 422 で止め、複合 FK は最終防衛に退かせる
  def work_pattern_must_be_active_and_same_tenant
    return if work_pattern_id.blank? # presence は belongs_to が拾う

    pattern = ActsAsTenant.without_tenant { WorkPattern.find_by(id: work_pattern_id) }
    if pattern.nil? || pattern.organization_id != organization_id
      errors.add(:work_pattern_id, "は同一組織の勤務パターンである必要があります")
    elsif !pattern.active?
      errors.add(:work_pattern_id, "は有効な勤務パターンである必要があります")
    end
  end
end
```

- [ ] **Step 5: User に has_many を追加**

`app/models/user.rb` の `has_many :subordinates, ...` の直後に追加:

```ruby
  has_many :user_work_patterns, dependent: :destroy
```

- [ ] **Step 6: テスト green を確認**

Run: `bundle exec rspec spec/models/user_work_pattern_spec.rb`
Expected: PASS（全 example）

- [ ] **Step 7: 全 suite + rubocop + commit**

Run: `bundle exec rspec && bundle exec rubocop --force-exclusion app/models/user_work_pattern.rb app/models/user.rb spec/models/user_work_pattern_spec.rb spec/factories/user_work_patterns.rb`

```bash
git add app/models/user_work_pattern.rb app/models/user.rb spec/models/user_work_pattern_spec.rb spec/factories/user_work_patterns.rb
git commit -m "feat: UserWorkPattern モデル（期間重複・fail-closed パターン検証・effective_on）"
```

---

### Task 4: WorkPattern 無効化ガード（ガード②同型）

**Files:**
- Modify: `app/models/work_pattern.rb`
- Test: `spec/models/work_pattern_spec.rb`（describe 追加）

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/work_pattern_spec.rb` の `RSpec.describe WorkPattern` 内に追加:

```ruby
  describe "無効化ガード（0b-4 設計 §3・User ガード②同型）" do
    let(:pattern) { create(:work_pattern) }
    let(:org) { pattern.organization }

    def assign(user_name, end_date:, active: true)
      employee = create(:user, name: user_name)
      create(:user_work_pattern, user: employee, work_pattern: pattern,
             start_date: Date.new(2026, 1, 1), end_date: end_date, active: active)
    end

    it "今日以降も有効な割当（無期限）があれば無効化拒否" do
      assign("田中太郎", end_date: nil)
      expect(pattern.update(active: false)).to be(false)
      expect(pattern.errors[:base].join).to include("田中太郎").and include("先に割当を付け替えてください")
    end

    it "過去のみの割当なら許可" do
      assign("田中太郎", end_date: org.today - 1)
      expect(pattern.update(active: false)).to be(true)
    end

    it "割当なしなら許可" do
      expect(pattern.update(active: false)).to be(true)
    end

    it "inactive 割当のみなら許可（誤登録の論理削除は妨げない）" do
      assign("田中太郎", end_date: nil, active: false)
      expect(pattern.update(active: false)).to be(true)
    end

    it "文言は先頭 3 名 + 他 N 名（flash 肥大防止）" do
      %w[田中太郎 佐藤花子 鈴木一郎 高橋次郎 伊藤三郎].each { |n| assign(n, end_date: nil) }
      pattern.update(active: false)
      message = pattern.errors[:base].join
      expect(message).to include("田中太郎、佐藤花子、鈴木一郎 他 2 名")
      expect(message).not_to include("高橋次郎")
    end

    it "without_tenant 文脈でも保護される" do
      assign("田中太郎", end_date: nil)
      ActsAsTenant.without_tenant do
        expect(pattern.update(active: false)).to be(false)
      end
    end

    it "mismatched with_tenant 文脈（誤テナント設定中の console 操作）でも保護される" do
      assign("田中太郎", end_date: nil)
      ActsAsTenant.with_tenant(create(:organization)) do
        expect(pattern.update(active: false)).to be(false)
      end
    end

    it "再有効化（active: true への遷移）はガード対象外" do
      pattern.update!(active: false)
      expect(pattern.update(active: true)).to be(true)
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/work_pattern_spec.rb -e "無効化ガード"`
Expected: FAIL（拒否系 example が `be(false)` でなく true になる）

- [ ] **Step 3: 実装**

`app/models/work_pattern.rb` — `validate :times_must_not_invert_without_night_shift` の下に validate 宣言を追加:

```ruby
  validate :deactivation_requires_no_current_or_future_assignments,
           if: -> { active_changed? && !active }
```

private 部の末尾にメソッドを追加:

```ruby
  # 0b-4 設計 §3（User ガード②同型）: 今日以降も有効な割当が残る無効化を拒否し、
  # 「先に割当を付け替え → 無効化」の一本道にする（Phase 1 で無効パターンが打刻に
  # 使われ続ける/計算不能になる二択を構造的に避ける）。
  # ②型クエリ + without_tenant ラップ: 真の脆弱点は mismatched with_tenant
  # （default scope が誤テナントを AND して空集合 → ガード素通り）。work_pattern_id キーは
  # 複合 FK (organization_id, work_pattern_id) が越境を排除するため、スコープ無しでも
  # 自テナントの割当だけが見える。today はレコードの organization から導出
  # （current_tenant 不使用 — company_calendar の fiscal_year 導出と同じ前例）
  def deactivation_requires_no_current_or_future_assignments
    assignments = ActsAsTenant.without_tenant do
      UserWorkPattern.where(work_pattern_id: id, active: true)
                     .where("end_date IS NULL OR end_date >= ?", organization.today)
                     .includes(:user).order(:start_date).to_a
    end
    return if assignments.empty?

    names = assignments.map { |a| a.user.name }.uniq
    shown = names.first(3).join("、")
    rest = names.size - 3
    label = rest.positive? ? "#{shown} 他 #{rest} 名" : shown
    errors.add(:base, "#{label}に有効な割当が残っています。先に割当を付け替えてください")
  end
```

- [ ] **Step 4: テスト green + 全 suite + rubocop + commit**

Run: `bundle exec rspec spec/models/work_pattern_spec.rb && bundle exec rspec && bundle exec rubocop --force-exclusion app/models/work_pattern.rb spec/models/work_pattern_spec.rb`

```bash
git add app/models/work_pattern.rb spec/models/work_pattern_spec.rb
git commit -m "feat: WorkPattern 無効化ガード（今日以降有効な割当があれば拒否・ガード②同型）"
```

---

### Task 5: Admin::UserWorkPatternPolicy + policy spec

**Files:**
- Create: `app/policies/admin/user_work_pattern_policy.rb`
- Create: `spec/policies/admin/user_work_pattern_policy_spec.rb`

- [ ] **Step 1: 失敗する policy spec を書く**

`spec/policies/admin/user_work_pattern_policy_spec.rb`（全文）:

```ruby
require "rails_helper"

RSpec.describe Admin::UserWorkPatternPolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let(:record) { create(:user_work_pattern) }

  context "hr_admin" do
    let(:actor) { create(:user, :hr_admin) }
    it { is_expected.to permit_actions(%i[new create edit update deactivate activate]) }
    it "destroy は不可（無効化のみ方針の固定）" do
      expect(subject.destroy?).to be(false)
    end
  end

  context "manager" do
    let(:actor) { create(:user, :manager_role) }
    it { is_expected.to forbid_actions(%i[new create edit update deactivate activate]) }
  end

  context "employee" do
    let(:actor) { create(:user) }
    it { is_expected.to forbid_actions(%i[new create edit update deactivate activate]) }
  end

  describe "Scope" do
    it "組織全件（inactive 含む）・他テナント漏れなし" do
      actor    = create(:user, :hr_admin)
      inactive = create(:user_work_pattern, active: false,
                        start_date: Date.new(2027, 1, 1)) # record と期間を重ねない
      ActsAsTenant.with_tenant(create(:organization)) { create(:user_work_pattern) }

      resolved = described_class::Scope.new(actor, UserWorkPattern.all).resolve
      expect(resolved).to contain_exactly(record, inactive)
    end

    it "without_tenant 文脈でも自組織のみ（organization_id 明示の fail-open 検出）" do
      actor = create(:user, :hr_admin)
      record # 生成
      ActsAsTenant.with_tenant(create(:organization)) { create(:user_work_pattern) }

      resolved = ActsAsTenant.without_tenant do
        described_class::Scope.new(actor, UserWorkPattern.all).resolve.to_a
      end
      expect(resolved).to contain_exactly(record)
    end
  end
end
```

注: `inactive` の record は重複検証を通すため期間をずらしている（同一 user ではないが、factory が同一テナントの別 user を作るため衝突はそもそも起きない — それでも明示しておくと将来の factory 変更に強い）。

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/policies/admin/user_work_pattern_policy_spec.rb`
Expected: FAIL（`uninitialized constant Admin::UserWorkPatternPolicy`）

- [ ] **Step 3: 実装**

`app/policies/admin/user_work_pattern_policy.rb`（全文）:

```ruby
module Admin
  # 0b-3 CompanyCalendarPolicy と同じく MasterPolicy 継承（0b-4 設計 §4 の判断）。
  # index/show はルートを持たない（一覧は社員詳細に同居）ため基底の index?/show? 定義は未到達
  class UserWorkPatternPolicy < MasterPolicy
  end
end
```

- [ ] **Step 4: green 確認 + commit**

Run: `bundle exec rspec spec/policies/admin/user_work_pattern_policy_spec.rb && bundle exec rubocop --force-exclusion app/policies/admin/user_work_pattern_policy.rb spec/policies/admin/user_work_pattern_policy_spec.rb`

```bash
git add app/policies/admin/user_work_pattern_policy.rb spec/policies/admin/user_work_pattern_policy_spec.rb
git commit -m "feat: Admin::UserWorkPatternPolicy（MasterPolicy 継承・hr_admin 限定）"
```

---

### Task 6: ルーティング + コントローラ + new/edit ビュー + ja.yml + request spec

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/admin/user_work_patterns_controller.rb`
- Create: `app/views/admin/user_work_patterns/_form.html.erb`
- Create: `app/views/admin/user_work_patterns/new.html.erb`
- Create: `app/views/admin/user_work_patterns/edit.html.erb`
- Modify: `config/locales/ja.yml`
- Create: `spec/requests/admin_user_work_patterns_spec.rb`

- [ ] **Step 1: ルーティング追加**

`config/routes.rb` の `resources :users, except: :destroy do ... end` ブロックの `member do ... end` の**後**（users の do ブロック内）に追加:

```ruby
      resources :user_work_patterns, only: %i[new create edit update] do
        member do
          patch :deactivate
          patch :activate
        end
      end
```

- [ ] **Step 2: ja.yml に翻訳追加**

`config/locales/ja.yml` — `models:` に 1 行・`attributes:` にブロックを追加:

```yaml
    models:
      # （既存行の下に）
      user_work_pattern: 勤務パターン割当
```

```yaml
      # attributes: の company_calendar: ブロックの下に
      user_work_pattern:
        work_pattern: 勤務パターン
        work_pattern_id: 勤務パターン
        start_date: 適用開始日
        end_date: 適用終了日
        active: 有効
```

- [ ] **Step 3: 失敗する request spec を書く**

`spec/requests/admin_user_work_patterns_spec.rb`（全文。表示系 example は Task 7 で追加する）:

```ruby
require "rails_helper"

RSpec.describe "Admin::UserWorkPatterns", type: :request do
  let!(:org)     { create(:organization, subdomain: "acme") }
  let!(:admin)   { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:target)  { ActsAsTenant.with_tenant(org) { create(:user, name: "田中太郎") } }
  let!(:pattern) { ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "日勤") } }

  def create_assignment(**attrs)
    ActsAsTenant.with_tenant(org) do
      create(:user_work_pattern, { user: target, work_pattern: pattern,
                                   start_date: Date.new(2026, 4, 1) }.merge(attrs))
    end
  end

  describe "認可（403 対照ペア・未認証）" do
    it "未認証はサインインへリダイレクト" do
      get new_admin_user_user_work_pattern_url(target, host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))
    end

    it "employee は 403・hr_admin は同一リクエストが 200（対照）" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get new_admin_user_user_work_pattern_url(target, host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get new_admin_user_user_work_pattern_url(target, host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end

    it "employee は write 系（POST create）も 403・件数不変" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      expect {
        post admin_user_user_work_patterns_url(target, host: tenant_host(org)),
             params: { user_work_pattern: { work_pattern_id: pattern.id, start_date: "2026-04-01" } }
      }.not_to change { ActsAsTenant.with_tenant(org) { UserWorkPattern.count } }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "IDOR（policy_scope 経由 find の一本道）" do
    before { sign_in admin }

    it "他テナントの user_id は 404" do
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:user) }
      get new_admin_user_user_work_pattern_url(outsider, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
    end

    it "他テナントの割当 id は 404" do
      other_assignment = ActsAsTenant.with_tenant(create(:organization)) { create(:user_work_pattern) }
      patch admin_user_user_work_pattern_url(target, other_assignment, host: tenant_host(org)),
            params: { user_work_pattern: { start_date: "2026-01-01" } }
      expect(response).to have_http_status(:not_found)
    end

    it "自テナントでも別ユーザーの割当 id は 404（user ネストの絞り）" do
      other_user_assignment = ActsAsTenant.with_tenant(org) { create(:user_work_pattern) }
      patch admin_user_user_work_pattern_url(target, other_user_assignment, host: tenant_host(org)),
            params: { user_work_pattern: { start_date: "2026-01-01" } }
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "作成できる（303 → 社員詳細）" do
      post admin_user_user_work_patterns_url(target, host: tenant_host(org)),
           params: { user_work_pattern: { work_pattern_id: pattern.id, start_date: "2026-04-01" } }
      expect(response).to redirect_to(admin_user_url(target, host: tenant_host(org)))
      expect(response).to have_http_status(:see_other)
      created = ActsAsTenant.with_tenant(org) { UserWorkPattern.order(:id).last }
      expect(created.user_id).to eq(target.id)
      expect(created.end_date).to be_nil
    end

    it "重複期間は 422 + 衝突相手期間入り文言で再描画" do
      create_assignment(end_date: Date.new(2026, 6, 30))
      post admin_user_user_work_patterns_url(target, host: tenant_host(org)),
           params: { user_work_pattern: { work_pattern_id: pattern.id, start_date: "2026-05-01" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("重複しています").and include("2026-04-01")
    end

    it "更新できる（303）" do
      assignment = create_assignment(end_date: Date.new(2026, 6, 30))
      patch admin_user_user_work_pattern_url(target, assignment, host: tenant_host(org)),
            params: { user_work_pattern: { work_pattern_id: pattern.id,
                                           start_date: "2026-04-01", end_date: "2026-05-31" } }
      expect(response).to have_http_status(:see_other)
      expect(assignment.reload.end_date).to eq(Date.new(2026, 5, 31))
    end

    it "日付逆転は 422" do
      assignment = create_assignment(end_date: Date.new(2026, 6, 30))
      patch admin_user_user_work_pattern_url(target, assignment, host: tenant_host(org)),
            params: { user_work_pattern: { work_pattern_id: pattern.id,
                                           start_date: "2026-04-01", end_date: "2026-03-01" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "permit 境界: user_id / active / organization_id を送っても無視される" do
      other_user = ActsAsTenant.with_tenant(org) { create(:user) }
      post admin_user_user_work_patterns_url(target, host: tenant_host(org)),
           params: { user_work_pattern: { work_pattern_id: pattern.id, start_date: "2026-04-01",
                                          user_id: other_user.id, active: false, organization_id: 0 } }
      created = ActsAsTenant.with_tenant(org) { UserWorkPattern.order(:id).last }
      expect(created.user_id).to eq(target.id)
      expect(created.active).to be(true)
      expect(created.organization_id).to eq(org.id)
    end

    it "exclusion 競合（TOCTOU）は 422 + 競合文言で再描画" do
      allow_any_instance_of(UserWorkPattern).to receive(:save)
        .and_raise(ActiveRecord::ExclusionViolation)
      post admin_user_user_work_patterns_url(target, host: tenant_host(org)),
           params: { user_work_pattern: { work_pattern_id: pattern.id, start_date: "2026-04-01" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("他の操作と競合しました")
    end
  end

  describe "deactivate / activate" do
    before { sign_in admin }

    it "無効化できる（303 → 社員詳細）" do
      assignment = create_assignment
      patch deactivate_admin_user_user_work_pattern_url(target, assignment, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(assignment.reload.active).to be(false)
    end

    it "再有効化できる" do
      assignment = create_assignment(active: false)
      patch activate_admin_user_user_work_pattern_url(target, assignment, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(assignment.reload.active).to be(true)
    end

    it "重複する割当の再有効化は 303 + alert（衝突相手期間入り文言）・active のまま不変" do
      inactive = create_assignment(end_date: Date.new(2026, 5, 31), active: false)
      create_assignment(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 12, 31))
      patch activate_admin_user_user_work_pattern_url(target, inactive, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(inactive.reload.active).to be(false)
      follow_redirect!
      expect(response.body).to include("重複しています")
    end
  end
end
```

- [ ] **Step 4: 失敗を確認**

Run: `bundle exec rspec spec/requests/admin_user_work_patterns_spec.rb`
Expected: FAIL（ルーティング/コントローラ不在）

- [ ] **Step 5: コントローラ実装**

`app/controllers/admin/user_work_patterns_controller.rb`（全文）:

```ruby
module Admin
  # 社員詳細ネストの割当 CRUD（0b-4 設計 §4）。index/show なし — 一覧は users#show に同居。
  # Deactivatable concern は流用しない（契約が redirect_to [:admin, record] + record.name 前提で、
  # show を持たず name も無いネストリソースと不一致）— 意図的非流用
  class UserWorkPatternsController < BaseController
    before_action :set_user
    before_action :set_user_work_pattern, only: %i[edit update deactivate activate]

    def new
      @user_work_pattern = @user.user_work_patterns.new
      authorize [ :admin, @user_work_pattern ]
    end

    def create
      @user_work_pattern = @user.user_work_patterns.new(user_work_pattern_params)
      authorize [ :admin, @user_work_pattern ]
      if rescue_exclusion_conflict { @user_work_pattern.save }
        redirect_to admin_user_path(@user), status: :see_other, notice: "勤務パターンを割り当てました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @user_work_pattern ]
    end

    def update
      authorize [ :admin, @user_work_pattern ]
      if rescue_exclusion_conflict { @user_work_pattern.update(user_work_pattern_params) }
        redirect_to admin_user_path(@user), status: :see_other, notice: "割当を更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def deactivate
      authorize [ :admin, @user_work_pattern ]
      if @user_work_pattern.update(active: false)
        redirect_to admin_user_path(@user), status: :see_other, notice: "割当を無効化しました"
      else
        redirect_to admin_user_path(@user), status: :see_other,
                    alert: @user_work_pattern.errors.full_messages.join("。")
      end
    end

    # 再有効化は重複検証・パターン有効性検証が再実行される（モデル側の発火条件）。
    # フォームが無いため失敗は 303 + alert（create/update の 422 再描画と非対称なのは意図）
    def activate
      authorize [ :admin, @user_work_pattern ]
      if rescue_exclusion_conflict { @user_work_pattern.update(active: true) }
        redirect_to admin_user_path(@user), status: :see_other, notice: "割当を再有効化しました"
      else
        redirect_to admin_user_path(@user), status: :see_other,
                    alert: @user_work_pattern.errors.full_messages.join("。")
      end
    end

    private

    # 他テナント user_id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_user
      @user = policy_scope([ :admin, User ]).find(params[:user_id])
    end

    # user 経由 + テナント default scope の二重絞り → 他テナント/他ユーザーの割当 id は 404
    def set_user_work_pattern
      @user_work_pattern = @user.user_work_patterns.find(params[:id])
    end

    # exclusion constraint 違反（TOCTOU 競合窓）だけを拾う — 広い StatementInvalid を rescue
    # すると無関係な SQL 失敗が「競合しました」に化けてシグナルを失う（0b-4 設計 §2-4）
    def rescue_exclusion_conflict
      yield
    rescue ActiveRecord::ExclusionViolation
      @user_work_pattern.errors.add(:base, "他の操作と競合しました。再度お試しください")
      false
    end

    # user_id は URL（ネスト）から・active はメンバーアクション専用 — 改竄代入経路を閉じる（§3.6(2)）
    def user_work_pattern_params
      params.require(:user_work_pattern).permit(:work_pattern_id, :start_date, :end_date)
    end
  end
end
```

- [ ] **Step 6: ビュー実装**

`app/views/admin/user_work_patterns/_form.html.erb`:

```erb
<%= form_with model: [:admin, user, user_work_pattern], class: "max-w-md space-y-4 text-sm" do |f| %>
  <% if user_work_pattern.errors.any? %>
    <div class="rounded border border-red-400 bg-red-50 p-3 text-red-800">
      <ul><% user_work_pattern.errors.full_messages.each do |msg| %><li><%= msg %></li><% end %></ul>
    </div>
  <% end %>

  <div>
    <%= f.label :work_pattern_id, "勤務パターン", class: "block font-bold" %>
    <%# 候補は有効パターンのみ・policy_scope 起点（生 where 禁止・SPEC §3.4）。
        edit で無効パターンを参照中の場合のみ現在値を「（無効）」付きで含める —
        選択肢から消すと保存時に無言で別パターンへ書き換わる（0b-4 設計 §5） %>
    <% options = policy_scope([:admin, WorkPattern]).where(active: true).order(:name).pluck(:name, :id) %>
    <% current = user_work_pattern.work_pattern %>
    <% if user_work_pattern.persisted? && current && !current.active? %>
      <% options += [["#{current.name}（無効）", current.id]] %>
    <% end %>
    <%= f.select :work_pattern_id, options, {}, class: "w-full rounded border p-2" %>
  </div>
  <div>
    <%= f.label :start_date, "適用開始日", class: "block font-bold" %>
    <%= f.date_field :start_date, class: "w-full rounded border p-2" %>
  </div>
  <div>
    <%= f.label :end_date, "適用終了日", class: "block font-bold" %>
    <%= f.date_field :end_date, class: "w-full rounded border p-2" %>
    <p class="mt-1 text-xs text-gray-600">空欄 = 無期限。パターン切替は「旧割当に終了日を設定 → 新しい割当を作成」の順で行ってください。</p>
  </div>
  <%= f.submit user_work_pattern.persisted? ? "更新する" : "割り当てる", class: "rounded bg-gray-800 px-4 py-2 text-white" %>
<% end %>
```

`app/views/admin/user_work_patterns/new.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold"><%= @user.name %> — 勤務パターン割当</h2>
<%= render "form", user: @user, user_work_pattern: @user_work_pattern %>
```

`app/views/admin/user_work_patterns/edit.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold"><%= @user.name %> — 割当の編集</h2>
<%= render "form", user: @user, user_work_pattern: @user_work_pattern %>
```

- [ ] **Step 7: green 確認 + 全 suite + rubocop + commit**

Run: `bundle exec rspec spec/requests/admin_user_work_patterns_spec.rb && bundle exec rspec && bundle exec rubocop --force-exclusion app/controllers/admin/user_work_patterns_controller.rb spec/requests/admin_user_work_patterns_spec.rb config/routes.rb`

```bash
git add config/routes.rb config/locales/ja.yml app/controllers/admin/user_work_patterns_controller.rb app/views/admin/user_work_patterns/ spec/requests/admin_user_work_patterns_spec.rb
git commit -m "feat: 割当 CRUD（社員詳細ネスト・ExclusionViolation rescue・IDOR 一本道）"
```

---

### Task 7: 社員詳細の割当セクション + 未割当バナー

**Files:**
- Modify: `app/controllers/admin/users_controller.rb`（show に ivar 3 つ）
- Modify: `app/views/admin/users/show.html.erb`（セクション render 追加）
- Create: `app/views/admin/users/_work_pattern_assignments.html.erb`
- Modify: `app/helpers/application_helper.rb`（状態バッジ）
- Modify: `spec/requests/admin_user_work_patterns_spec.rb`（表示系 describe 追加）

- [ ] **Step 1: 失敗するテストを書く**

`spec/requests/admin_user_work_patterns_spec.rb` の末尾（最後の `end` の前）に追加:

```ruby
  describe "社員詳細の割当セクション（0b-4 設計 §5）" do
    before { sign_in admin }

    it "未割当なら警告バナー・有効割当があれば消える（対照ペア）" do
      get admin_user_url(target, host: tenant_host(org))
      expect(response.body).to include("現在有効な勤務パターン割当がありません")

      create_assignment(start_date: org.today - 30) # 今日をカバーする有効割当
      get admin_user_url(target, host: tenant_host(org))
      expect(response.body).not_to include("現在有効な勤務パターン割当がありません")
    end

    it "過去割当のみではバナーが出る（述語は effective_on — 「割当行ゼロ」ではない）" do
      create_assignment(start_date: Date.new(2020, 1, 1), end_date: Date.new(2020, 12, 31))
      get admin_user_url(target, host: tenant_host(org))
      expect(response.body).to include("現在有効な勤務パターン割当がありません")
    end

    it "一覧は状態バッジ・無期限表示・無効パターン名の（無効）付記を出す" do
      create_assignment(start_date: org.today - 30) # 有効・無期限
      retired = ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "旧早番") }
      ActsAsTenant.with_tenant(org) do
        create(:user_work_pattern, user: target, work_pattern: retired,
               start_date: Date.new(2020, 1, 1), end_date: Date.new(2020, 12, 31))
        retired.update!(active: false) # 過去のみの割当ゆえガードを通る
      end
      get admin_user_url(target, host: tenant_host(org))
      expect(response.body).to include("有効").and include("過去")
        .and include("（無期限）").and include("旧早番（無効）")
    end

    it "new フォームの選択肢に inactive パターンは出ない" do
      ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "旧夜勤", active: false) }
      get new_admin_user_user_work_pattern_url(target, host: tenant_host(org))
      expect(response.body).to include("日勤")
      expect(response.body).not_to include("旧夜勤")
    end

    it "edit フォームは無効パターン参照中のみ現在値を（無効）付きで選択肢に含める" do
      retired = ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "旧早番") }
      assignment = ActsAsTenant.with_tenant(org) do
        a = create(:user_work_pattern, user: target, work_pattern: retired,
                   start_date: Date.new(2020, 1, 1), end_date: Date.new(2020, 12, 31))
        retired.update!(active: false)
        a
      end
      get edit_admin_user_user_work_pattern_url(target, assignment, host: tenant_host(org))
      expect(response.body).to include("旧早番（無効）")
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/requests/admin_user_work_patterns_spec.rb -e "社員詳細の割当セクション"`
Expected: FAIL（バナー・セクション未実装）

- [ ] **Step 3: ヘルパ実装**

`app/helpers/application_helper.rb` に追加:

```ruby
  # 割当の状態バッジ（0b-4 設計 §5 — 単一リスト + 状態バッジ。today は組織 TZ の Organization#today）
  def user_work_pattern_status(assignment, today)
    return "無効" unless assignment.active?
    return "未来" if assignment.start_date > today
    return "過去" if assignment.end_date && assignment.end_date < today

    "有効"
  end
```

- [ ] **Step 4: UsersController#show を拡張**

`app/controllers/admin/users_controller.rb` の `show` を置き換え:

```ruby
    def show
      authorize [ :admin, @user ]
      @user_work_patterns = @user.user_work_patterns.includes(:work_pattern)
                                 .order(start_date: :desc, id: :desc)
      @org_today = @user.organization.today
      # 述語は effective_on（Phase 1 取得条件と同一の単一ソース）— 「割当行ゼロ」で判定しない
      @no_effective_assignment = @user.user_work_patterns.effective_on(@org_today).none?
    end
```

- [ ] **Step 5: ビュー実装**

`app/views/admin/users/_work_pattern_assignments.html.erb`（全文）:

```erb
<section class="mt-8 max-w-2xl">
  <div class="flex items-center justify-between">
    <h3 class="text-base font-bold">勤務パターン割当</h3>
    <%= link_to "+ 新規割当", new_admin_user_user_work_pattern_path(@user), class: "rounded border px-3 py-1 text-sm" %>
  </div>

  <% if @no_effective_assignment %>
    <%# E 原則（SPEC §8 冒頭）: 「打刻不能」とは書かない — 打刻のブロックは一切行わない %>
    <div class="mt-2 rounded border border-yellow-400 bg-yellow-50 p-3 text-sm text-yellow-800">
      現在有効な勤務パターン割当がありません。割当が無い日は労働時間の自動計算・コンプライアンス判定ができません（打刻自体は妨げられません）。
    </div>
  <% end %>

  <% if @user_work_patterns.any? %>
    <table class="mt-3 w-full text-left text-sm">
      <thead>
        <tr class="border-b">
          <th class="py-1">状態</th><th>パターン</th><th>適用開始</th><th>適用終了</th><th></th>
        </tr>
      </thead>
      <tbody>
        <% @user_work_patterns.each do |assignment| %>
          <% status = user_work_pattern_status(assignment, @org_today) %>
          <tr class="border-b <%= "text-gray-400" if %w[過去 無効].include?(status) %>">
            <td class="py-1"><%= status %></td>
            <td><%= assignment.work_pattern.name %><%= "（無効）" unless assignment.work_pattern.active? %></td>
            <td><%= assignment.start_date %></td>
            <td><%= assignment.end_date || "（無期限）" %></td>
            <td class="py-1">
              <div class="flex gap-2">
                <%= link_to "編集", edit_admin_user_user_work_pattern_path(@user, assignment), class: "underline" %>
                <% if assignment.active? %>
                  <%= button_to "無効化", deactivate_admin_user_user_work_pattern_path(@user, assignment),
                        method: :patch,
                        data: { turbo_confirm: "この割当を無効化しますか？（誤登録の取り消し専用。終了・切替は終了日の設定で行ってください）" },
                        class: "text-red-700 underline" %>
                <% else %>
                  <%= button_to "再有効化", activate_admin_user_user_work_pattern_path(@user, assignment),
                        method: :patch, class: "underline" %>
                <% end %>
              </div>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% end %>
</section>
```

`app/views/admin/users/show.html.erb` — 末尾（操作ボタンの `</div>` の後）に追加:

```erb
<%= render "work_pattern_assignments" %>
```

- [ ] **Step 6: green 確認 + 全 suite + rubocop + commit**

Run: `bundle exec rspec spec/requests/admin_user_work_patterns_spec.rb spec/requests/admin_users_spec.rb && bundle exec rspec && bundle exec rubocop --force-exclusion app/controllers/admin/users_controller.rb app/helpers/application_helper.rb`

注: `admin_users_spec.rb` が show の追加クエリで落ちないことを必ず確認（落ちたら原因を直す — spec を緩めない）。

```bash
git add app/controllers/admin/users_controller.rb app/views/admin/users/ app/helpers/application_helper.rb spec/requests/admin_user_work_patterns_spec.rb
git commit -m "feat: 社員詳細の割当セクション + 未割当バナー（effective_on 述語・E 原則文言）"
```

---

### Task 8: seeds + docs 逆反映（SPEC・NOTES #12・ROADMAP バックログ）

**Files:**
- Modify: `db/seeds.rb`
- Modify: `docs/SPEC.md`（§4.6 差し替え）
- Modify: `docs/LABOR_LAW_REVIEW_NOTES.md`（#12 追記）
- Modify: `docs/ROADMAP.md`（バックログ 3 件追記）
- Test: `spec/db/seeds_spec.rb`（既存があれば example 追加・なければ既存検証方法に従う）

- [ ] **Step 1: seeds に割当を追加**

`db/seeds.rb` — employee の `User.find_or_create_by!` を変数で受けるよう変更:

```ruby
    emp = User.find_or_create_by!(email: "employee@#{org.subdomain}.example.com") do |u|
      u.name = "#{org.name} 社員"
      u.employee_code = "#{org.subdomain.upcase}-003"
      u.role = :employee
      u.manager = boss
      u.password = password
    end
```

WorkPattern 群の作成より**後**（CompanyCalendar ブロックの前後どちらでも可）に追加:

```ruby
    # 勤務パターン割当（0b-4）— §16.7-4 の動作確認用。found 経路は再実行で落ちない（冪等）
    UserWorkPattern.find_or_create_by!(user: emp, work_pattern: WorkPattern.find_by!(name: "日勤")) do |a|
      a.start_date = Date.new(2026, 4, 1) # end_date なし = 無期限
    end
```

- [ ] **Step 2: seeds の冪等性を検証**

Run: `bin/rails db:seed && bin/rails db:seed && bundle exec rspec`
Expected: 2 回連続成功（冪等）+ 既存 seeds spec が green（seeds spec が存在する場合、割当 1 件の assert を追加する）

- [ ] **Step 3: SPEC §4.6 を差し替え**

`docs/SPEC.md` の `### 4.6 UserWorkPattern（パターン割当）` セクション（テーブル + 「**重複制約:** ...」段落）を以下に置き換え:

```markdown
### 4.6 UserWorkPattern（パターン割当）

| カラム | 型 | 説明 |
|--------|-----|------|
| user_id / work_pattern_id | bigint | 割当先・パターン |
| start_date / end_date | date | 適用期間（end_date null = 無期限） |
| active | boolean | 有効フラグ（**誤登録の論理削除専用** — 正常な終了・切替は end_date で表現） |

**重複制約:** 同一ユーザーで有効な割当の日付範囲は重複不可（`end_date = null` は全未来日と重複扱い）。防衛は**モデルバリデーション + PostgreSQL exclusion constraint（btree_gist・`WHERE (active)`）の二重**（0b-4: Phase 1 の「有効な 1 件」取得が重複データで 2 件になると賃金計算の入力が非決定化するため DB 層を追加）。打刻時は「打刻日時点で有効な 1 件」を `start_date <= 当日 AND (end_date >= 当日 OR end_date IS NULL) AND active` で取得 — 述語の単一ソースは `UserWorkPattern.effective_on`。

**運用（0b-4）:** 割当は無効化のみ（destroy なし）。過去割当は未打刻日の所定根拠として温存する。今日以降も有効な割当が残る WorkPattern は無効化不可（先に割当を付け替える）。inactive な WorkPattern の新規割当・変更も拒否（無効化ガードの代入側対称）。「今日」の判定は組織 TZ（`Organization#today`）。

**将来拡張（v2・§8.8 と同期）:** 属人的法定制限の割当時警告 — 年少者×夜勤パターン（労基法 61 条 1 項）・flextime パターン×労使協定の対象労働者範囲（労基法 32 条の 3 第 1 項 1 号）。人×パターンの適法性検証は割当が結節点となる。
```

- [ ] **Step 4: LABOR_LAW_REVIEW_NOTES に #12 を追記**

`docs/LABOR_LAW_REVIEW_NOTES.md` を読み、既存の表形式（#10/#11 と同形）に従って追記する。内容:

> **#12 UserWorkPattern の隙間・保存期間（§4.6・0b-4）**
> (a) 無割当日に打たれた打刻の暫定計算基準 — 所定不明時に保守的計算（法定 8h 基準等）で §8 集計へ参入させてよいか（集計から漏らすより安全側か）
> (b) 勤務パターン割当記録の労基法 109 条「労働関係に関する重要な書類」該当性 — 該当する場合「無効化のみ・物理削除なし」で保存義務（5 年・経過措置 143 条は原典未照合のため当分 3 年とされる点も含め）を満たすか
> (c) flextime パターン割当者と 32 条の 3 労使協定の対象労働者範囲の突合を運用とシステムのどちらで担保するか
> 出典: 労基法 109 条（照合済み 2026-06-12）・143 条（未照合）・32 条の 3 第 1 項 1 号（照合済み）・61 条 1 項（照合済み）

- [ ] **Step 5: ROADMAP バックログに 3 件追記**

`docs/ROADMAP.md` の「横断バックログ」末尾に追加:

```markdown
- [ ] **社員一覧の未割当バッジ + 期限切れ先読み**: 0b-4 は社員詳細バナーのみ（述語 = `effective_on`）。一覧バッジは Phase 1 の打刻導線で実害が出てから、「N 日以内に割当終了 + 後継なし」の先読み通知は Phase 4-1 の通知基盤接続後（0b-4 労務レビュー）
- [ ] **割当隙間日の遡及補正**: 無割当期間に打たれた打刻は `work_pattern_id` NULL で計算スキップ（§5.4）になるが、§4.8 の不遡及原則により後追い割当でも補正されない。Phase 1 の打刻設計で「NULL レコード限定の遡及スナップショット + 再計算」の例外を判断（労務レビュー High・社労士確認 #12-(a)）
- [ ] **割当変更履歴**: 過去に食い込む日付編集が監査証跡ゼロで可能（労基法 109 条の趣旨・社労士確認 #12-(b)）。Phase 1-3 AttendanceHistory 設計時に同棲で判断 — 履歴機構を二系統作らない（0b-4 設計 §0）
```

- [ ] **Step 6: Commit**

```bash
git add db/seeds.rb docs/SPEC.md docs/LABOR_LAW_REVIEW_NOTES.md docs/ROADMAP.md
git commit -m "docs: SPEC §4.6 逆反映 + NOTES #12 + ROADMAP バックログ 3 件 + seeds 割当"
```

---

### Task 9: 最終ゲート（preflight・レビュー・PR）

- [ ] **Step 1: 静的検証の全実行**

Run:
```bash
bundle exec rspec && \
bundle exec rubocop --force-exclusion && \
bin/brakeman --no-pager -q -w2 && \
bundle exec bundle-audit check --update
```
Expected: 全 PASS（rspec 全 green・rubocop no offenses・brakeman 0 warnings）

- [ ] **Step 2: 専門レビュアー 2 種を起動**

models / migration に触れたため `tenant-isolation-reviewer`、§8 接点（E 原則文言・労務帰結）のため `labor-law-compliance-reviewer` を起動し、Critical/High が出れば修正してから次へ。

- [ ] **Step 3: ROADMAP 0b-4 行の更新を準備**

`docs/ROADMAP.md` の 0b-4 行を `[x]` + PR 番号（PR 作成後に判明する番号）で更新し、コミットして push（**PR にこの行更新を含めてからマージ**する規約）。

- [ ] **Step 4: push + PR 作成**

```bash
git push -u origin feat/0b-4-user-work-pattern
gh pr create --title "feat: Phase 0b-4 UserWorkPattern（割当 CRUD・期間重複二重防衛・無効化ガード）" --body "..."
```
PR 本文: 設計仕様へのリンク・5 視点レビュー反映の要点・検証結果。gh のアカウントが kei1110 であることを `gh auth status` で確認（sub-account になっていたら `gh auth switch -u kei1110`）。

- [ ] **Step 5: CI 緑を確認**

`gh pr checks --watch` で lint / security / test の 3 チェック緑を確認。マージはユーザー指示を待つ。

---

## Self-Review 済み事項

- 設計 §0〜§7 の全項目にタスクが対応（§0 TZ→Task 1・§1→Task 2・§2→Task 3・§3→Task 4・§4→Task 5/6・§5→Task 6/7・§6→各タスクの spec・§7→Task 8）
- 型整合: `effective_on(date)`（Task 3 定義・Task 7 使用）/ `Organization#today`（Task 1 定義・Task 4/7 使用）/ `rescue_exclusion_conflict`（Task 6 内で定義・使用）
- 重複検証の発火条件（`if: :active?`）と Task 3 の activate example・Task 6 の activate request example が同じ意味論を指す
- daterange 逆転（end < start）は日付検証が先に拾い、重複検証は自衛 guard で DB エラーを回避
