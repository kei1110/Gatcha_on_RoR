# Phase 2-1 承認エンジン core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 対象モデル非依存の承認エンジン中核（ApprovalAssignment・Approvable concern(AASM)・固定2段ルート解決・承認/却下サービス・自己承認防止の二層）を、テスト専用 approvable で end-to-end 検証して構築する。

**Architecture:** SPEC §7.1 の polymorphic 設計。実行時状態は `ApprovalAssignment`（polymorphic・複合 FK でテナント分離）、業務ステータスは `Approvable` concern の AASM（applying/approved/rejected/canceled、段階情報は持たず assignment 群から導出）。ルート解決・承認・却下は `app/services/approvals/` のコマンドサービス。自己承認防止は `Approvals::SelfApproval` を単一ソースにサービス層と Pundit の二層で enforce。

**Tech Stack:** Rails 8 / Ruby 4 / PostgreSQL 17 / AASM（本 repo 初導入）/ acts_as_tenant / Pundit / RSpec + FactoryBot + pundit-matchers。

**設計 SSOT:** `docs/superpowers/specs/2026-06-14-phase2-1-approval-engine-core-design.md`（多視点レビュー反映済）。
**ブランチ:** `feat/phase2-1-approval-engine-core`（main へ rebase 済）。

**全タスク共通の留意（RAILS_GOTCHAS）:**
- rubocop はファイル明示渡し時 `--force-exclusion` 必須。
- model/service/policy spec は `around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }` でテナント文脈を張る（既存 `attendance_history_spec.rb` 準拠）。
- AASM は repo 初。`enum` を `aasm` より先に宣言（class ロード時マッピング解決）。`whiny_persistence: true` で bang の save 失敗を例外化。
- `app/` に触れる commit は完了前に `bin/brakeman --no-pager` も回す。

---

## File Structure（このスライスで触るファイル）

| ファイル | 責務 |
|---|---|
| `Gemfile` / `Gemfile.lock` | `aasm` 追加（bundle 経由） |
| `db/migrate/*_create_approval_assignments.rb` | テーブル + 複合 FK + index |
| `app/models/approval_assignment.rb` | 実行時状態モデル（テナント検証2種・decision片道・acted_at整合） |
| `app/models/concerns/approvable.rb` | AASM 業務ステータス + `has_many :approval_assignments` + 段階導出 |
| `app/services/approvals/errors.rb` | `Error`/`RouteError`/`SelfApprovalError`/`NotCurrentApprover`/`ProxyNotSupported` |
| `app/services/approvals/self_approval.rb` | 自己承認規則の単一ソース |
| `app/services/approvals/route_resolver.rb` | 固定2段ルート解決・縮約 |
| `app/services/approvals/start.rb` | route → pending assignment 生成（明示起動） |
| `app/services/approvals/approve.rb` | 承認（terminal/pin/自己承認/段階順序・最終 AASM） |
| `app/services/approvals/reject.rb` | 却下（全体却下） |
| `app/policies/approval_assignment_policy.rb` | 自己承認防止の認可層（approve?/reject?） |
| `spec/support/approvable_test_model.rb` | テスト専用ホスト（before(:suite) で一時テーブル） |
| `spec/models/approval_assignment_spec.rb` | モデル検証・テナント・DB 最終防衛 |
| `spec/models/concerns/approvable_spec.rb` | AASM・導出ヘルパ・迂回封じ |
| `spec/services/approvals/route_resolver_spec.rb` | ルート分岐・縮約・エラー |
| `spec/services/approvals/self_approval_spec.rb` | predicate |
| `spec/services/approvals/start_spec.rb` | assignment 生成・冪等・rollback |
| `spec/services/approvals/approve_spec.rb` | 段階進行・自己承認・段階順序・terminal |
| `spec/services/approvals/reject_spec.rb` | 全体却下・comment・残置 |
| `spec/policies/approval_assignment_policy_spec.rb` | permit/forbid・SelfApproval 共有 |

**2-2 へ後置（本スライスで作らない）:** `Approvals::Cancel` サービス・`ApprovalAssignmentPolicy::Scope`・ヘルパ `single_stage?`/`pending_approver`・approvable 別 `cancel?` Pundit・controller・UI。

---

## Task 1: AASM gem 導入

**Files:**
- Modify: `Gemfile`
- Modify: `Gemfile.lock`（bundle 経由・手編集禁止）

- [ ] **Step 1: Gemfile に aasm を追加**

`Gemfile` の主要 gem 群（`gem "pundit"` の近く）に追記:

```ruby
gem "aasm"
```

- [ ] **Step 2: bundle install**

Run: `bundle install`
Expected: `Bundle complete`。`Gemfile.lock` に `aasm (x.y.z)` が追加される。

- [ ] **Step 3: ロード確認**

Run: `bin/rails runner "puts AASM::VERSION"`
Expected: バージョン文字列が出力され、例外が出ない。

- [ ] **Step 4: Commit**

```bash
git add Gemfile Gemfile.lock
git commit -m "chore: AASM gem 導入（Phase 2-1 承認エンジンの状態機械・repo 初）"
```

---

## Task 2: ApprovalAssignment マイグレーション

**Files:**
- Create: `db/migrate/<timestamp>_create_approval_assignments.rb`

- [ ] **Step 1: マイグレーション生成**

Run: `bin/rails generate migration CreateApprovalAssignments`
Expected: `db/migrate/<timestamp>_create_approval_assignments.rb` が生成。

- [ ] **Step 2: マイグレーション内容を記述**

生成ファイルを以下で**置き換える**（複合 FK は既存 `user_work_patterns` 実装と同型）:

```ruby
# frozen_string_literal: true

class CreateApprovalAssignments < ActiveRecord::Migration[8.0]
  def change
    create_table :approval_assignments do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :approvable, polymorphic: true, null: false
      t.integer :position, null: false
      t.bigint :approver_id, null: false
      t.integer :decision, null: false, default: 0
      t.timestamptz :acted_at
      t.text :comment

      t.timestamps
    end

    add_index :approval_assignments,
              [ :organization_id, :approvable_type, :approvable_id, :position ],
              unique: true, name: "index_approval_assignments_unique_stage"
    add_index :approval_assignments,
              [ :organization_id, :approver_id, :decision ],
              name: "index_approval_assignments_on_approver"

    # 承認者のクロステナント参照を DB レベルで排除（users の [organization_id, id] unique index へ複合 FK）
    add_foreign_key :approval_assignments, :users,
                    column: [ :organization_id, :approver_id ], primary_key: [ :organization_id, :id ]
  end
end
```

- [ ] **Step 3: マイグレーション実行**

Run: `bin/rails db:migrate`
Expected: `create_table(:approval_assignments)` が成功し、`db/schema.rb` が更新される（schema.rb は自動更新ゆえ手編集しない）。

- [ ] **Step 4: テスト DB を整える**

Run: `bin/rails db:test:prepare`
Expected: エラーなく完了（test DB に approval_assignments が反映）。

- [ ] **Step 5: スキーマ確認**

Run: `grep -A14 'create_table "approval_assignments"' db/schema.rb`
Expected: `position` `approver_id` `decision` `acted_at`(timestamptz) `comment` と 2 つの index が出力される。

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb
git commit -m "feat: approval_assignments テーブル（polymorphic・複合 FK でテナント分離）"
```

---

## Task 3: ApprovalAssignment モデル（TDD）

**Files:**
- Create: `app/models/approval_assignment.rb`
- Test: `spec/models/approval_assignment_spec.rb`

> テスト用 approvable は次タスクで作る正式ホストではなく、本タスクでは既存の `AttendanceRecord`（acts_as_tenant 済・テナントを持つ任意の AR）を polymorphic approvable の同テナント／越境スタブとして使う。これによりモデル単体検証をホスト未完成でも進められる。

- [ ] **Step 1: モデル spec を書く（失敗する）**

`spec/models/approval_assignment_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApprovalAssignment do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:requester) { create(:user, organization: org) }
  let(:approver)  { create(:user, :manager_role, organization: org) }
  # polymorphic approvable のスタブ（同テナントの任意 AR）
  let(:approvable) { create(:attendance_record, organization: org, user: requester) }

  def build_assignment(**attrs)
    described_class.new(organization: org, approvable:, approver:, position: 1, decision: :pending, **attrs)
  end

  # 監査拒否相当の DB 例外を savepoint 隔離（transactional fixtures の example tx 道連れ防止）
  def in_savepoint
    ActiveRecord::Base.transaction(requires_new: true) { yield }
  end

  describe "作成" do
    it "有効なら保存できる" do
      expect { build_assignment.save! }.to change(described_class, :count).by(1)
    end
  end

  describe "position" do
    it "1/2 以外は無効" do
      a = build_assignment(position: 3)
      expect(a).to be_invalid
      expect(a.errors[:position]).to be_present
    end

    it "同一 approvable で position 重複は無効" do
      build_assignment(position: 1).save!
      dup = build_assignment(position: 1, approver: create(:user, :hr_admin, organization: org))
      expect(dup).to be_invalid
      expect(dup.errors[:position]).to be_present
    end
  end

  describe "decision" do
    it "不正な値は ArgumentError でなく検証で弾く（毒入力）" do
      a = build_assignment
      expect { a.decision = "bogus" }.to raise_error(ArgumentError) # Rails enum の代入時 raise
    end

    it "pending→approved の片道のみ（決裁後の再変更は無効）" do
      a = build_assignment(decision: :approved, acted_at: Time.current).tap(&:save!)
      a.decision = :rejected
      expect(a).to be_invalid
      expect(a.errors[:decision]).to be_present
    end
  end

  describe "acted_at 整合" do
    it "pending なのに acted_at 有りは無効" do
      a = build_assignment(decision: :pending, acted_at: Time.current)
      expect(a).to be_invalid
      expect(a.errors[:acted_at]).to be_present
    end

    it "decision 済なのに acted_at なしは無効" do
      a = build_assignment(decision: :approved, acted_at: nil)
      expect(a).to be_invalid
      expect(a.errors[:acted_at]).to be_present
    end
  end

  describe "テナント分離（approver）" do
    it "他テナントの approver を拒否（association 経路）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, :manager_role, organization: other) }
      a = build_assignment(approver: foreign)
      expect(a).to be_invalid
      expect(a.errors[:approver]).to be_present
    end

    it "他テナント approver_id の直接代入を拒否（fail-closed）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, :manager_role, organization: other) }
      a = build_assignment.tap { |rec| rec.approver = nil; rec.approver_id = foreign.id }
      expect(a.approver).to be_nil          # スコープ外ゆえ nil 解決
      expect(a).to be_invalid
      expect(a.errors[:approver]).to be_present
    end
  end

  describe "テナント分離（approvable・polymorphic の唯一の構造防衛）" do
    it "他テナントの approvable を拒否" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:attendance_record, organization: other, user: create(:user, organization: other))
      end
      a = build_assignment(approvable: foreign)
      expect(a).to be_invalid
      expect(a.errors[:approvable]).to be_present
    end

    it "他テナント approvable_id の直接代入を拒否（fail-closed）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:attendance_record, organization: other, user: create(:user, organization: other))
      end
      a = build_assignment.tap do |rec|
        rec.approvable = nil
        rec.approvable_type = "AttendanceRecord"
        rec.approvable_id = foreign.id
      end
      expect(a.approvable).to be_nil
      expect(a).to be_invalid
      expect(a.errors[:approvable]).to be_present
    end
  end

  describe "DB 最終防衛" do
    it "position 重複は UNIQUE 制約で弾く（検証迂回時）" do
      build_assignment(position: 1).save!
      dup = build_assignment(position: 1, approver: create(:user, :hr_admin, organization: org))
      expect { in_savepoint { dup.save!(validate: false) } }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/approval_assignment_spec.rb`
Expected: FAIL（`uninitialized constant ApprovalAssignment` 等）。

- [ ] **Step 3: モデルを実装**

`app/models/approval_assignment.rb`:

```ruby
# frozen_string_literal: true

# 承認の実行時状態（SPEC §7.1）。段階情報は本テーブル群から導出する。
class ApprovalAssignment < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :approvable, polymorphic: true
  belongs_to :approver, class_name: "User"

  enum :decision, { pending: 0, approved: 1, rejected: 2 }, validate: true

  validates :position, inclusion: { in: [ 1, 2 ] }
  validates :position, uniqueness: { scope: [ :organization_id, :approvable_type, :approvable_id ] }
  validate :approver_must_belong_to_same_organization
  validate :approvable_must_belong_to_same_organization
  validate :acted_at_consistency_with_decision
  validate :decision_is_one_way, on: :update

  private

  # users.rb の manager_must_belong_to_same_organization と同型（nil＝スコープ外も明示エラー）
  def approver_must_belong_to_same_organization
    return if approver&.organization_id == organization_id

    errors.add(:approver, "は同一組織のユーザーである必要があります")
  end

  # polymorphic ゆえ実 FK 不可 → この検証が唯一の構造防衛。整数 ID 直接代入の fail-closed も担保
  def approvable_must_belong_to_same_organization
    return if approvable_type.blank? && approvable_id.blank? # belongs_to 必須検証に委ねる
    return if approvable&.organization_id == organization_id

    errors.add(:approvable, "は同一組織のレコードである必要があります")
  end

  def acted_at_consistency_with_decision
    if pending? && acted_at.present?
      errors.add(:acted_at, "は pending 中は設定できません")
    elsif !pending? && acted_at.blank?
      errors.add(:acted_at, "は決裁時に必須です")
    end
  end

  # pending からの一方向のみ許可（決裁の取消・付け替えを禁止）
  def decision_is_one_way
    return unless decision_changed?
    return if decision_was == "pending"

    errors.add(:decision, "は決裁後に変更できません")
  end
end
```

- [ ] **Step 4: パスを確認**

Run: `bundle exec rspec spec/models/approval_assignment_spec.rb`
Expected: 全 example PASS。

- [ ] **Step 5: lint + brakeman**

Run: `bundle exec rubocop --force-exclusion app/models/approval_assignment.rb spec/models/approval_assignment_spec.rb && bin/brakeman --no-pager`
Expected: rubocop offense 0、brakeman 警告 0。

- [ ] **Step 6: Commit**

```bash
git add app/models/approval_assignment.rb spec/models/approval_assignment_spec.rb
git commit -m "feat: ApprovalAssignment モデル（テナント検証2種・decision片道・acted_at整合）"
```

---

## Task 4: Approvable concern + テスト専用ホスト（TDD）

**Files:**
- Create: `app/models/concerns/approvable.rb`
- Create: `spec/support/approvable_test_model.rb`
- Test: `spec/models/concerns/approvable_spec.rb`

- [ ] **Step 1: テスト専用ホストを作る**

`spec/support/approvable_test_model.rb`（一時テーブルは `maintain_test_schema!`(rails_helper:35) より後の `before(:suite)` で生成 — require 時生成だと schema purge で drop される）:

```ruby
# frozen_string_literal: true

# Approvable concern を検証するためのテスト専用ホスト（Phase 2-1: 本番 approvable 不在）。
# クラス定義は load 時でよい（enum/aasm は列を introspect しない）。テーブルだけ before(:suite) で作る。
class ApprovalTestRecord < ApplicationRecord
  acts_as_tenant(:organization)
  belongs_to :requester, class_name: "User"
  include Approvable
end

RSpec.configure do |config|
  config.before(:suite) do
    conn = ActiveRecord::Base.connection
    unless conn.table_exists?(:approval_test_records)
      conn.create_table(:approval_test_records) do |t|
        t.references :organization, null: false
        t.references :requester, null: false
        t.integer :approval_status, null: false, default: 0
        t.timestamps
      end
    end
  end
end
```

- [ ] **Step 2: concern spec を書く（失敗する）**

`spec/models/concerns/approvable_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvable do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:requester) { create(:user, organization: org) }
  let(:approver1) { create(:user, :manager_role, organization: org) }
  let(:approver2) { create(:user, :hr_admin, organization: org) }
  let(:host) { ApprovalTestRecord.create!(requester:) }

  def add_assignment(position:, approver:, decision: :pending, acted_at: nil)
    host.approval_assignments.create!(organization: org, approver:, position:, decision:, acted_at:)
  end

  describe "初期状態（§7.7）" do
    it "新規作成で applying" do
      expect(host).to be_applying
      expect(host.approval_status).to eq("applying")
    end
  end

  describe "enum 整数マッピング（凍結）" do
    it "0–3 完全一致（4/5 は未定義＝2-5 予約）" do
      expect(ApprovalTestRecord.approval_statuses)
        .to eq("applying" => 0, "approved" => 1, "rejected" => 2, "canceled" => 3)
    end
  end

  describe "AASM 遷移" do
    it "approve（最終段階）で approved" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      expect(host.all_stages_approved?).to be true
      host.approve!
      expect(host).to be_approved
    end

    it "reject で rejected" do
      host.reject!
      expect(host).to be_rejected
    end

    it "cancel で canceled" do
      host.cancel!
      expect(host).to be_canceled
    end

    it "terminal からは InvalidTransition" do
      host.reject!
      expect { host.approve! }.to raise_error(AASM::InvalidTransition)
    end

    it "全段階 approved でなければ approve! の guard で弾く" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      add_assignment(position: 2, approver: approver2, decision: :pending)
      expect(host.all_stages_approved?).to be false
      expect { host.approve! }.to raise_error(AASM::InvalidTransition)
    end

    it "撤回イベントは未定義（2-5）" do
      expect(host).not_to respond_to(:request_withdrawal!)
    end
  end

  describe "段階導出ヘルパ" do
    it "current_approval_position は最小の pending 段階" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      add_assignment(position: 2, approver: approver2, decision: :pending)
      expect(host.current_approval_position).to eq(2)
    end

    it "current_approval_position は pending 皆無なら nil" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      expect(host.current_approval_position).to be_nil
    end

    it "all_stages_approved? は rejected を含むと false" do
      add_assignment(position: 1, approver: approver1, decision: :rejected, acted_at: Time.current)
      expect(host.all_stages_approved?).to be false
    end

    it "all_stages_approved? は assignment 皆無なら false" do
      expect(host.all_stages_approved?).to be false
    end
  end

  describe "§7.3 #5 AASM 限定（最小回帰）" do
    it "enum bang で直接 approved にしても guard を経ない（迂回経路の存在を固定）" do
      # bang は AASM 迂回ゆえ承認エンジン外から呼ばない契約。ここでは「迂回し得る」事実を回帰固定し、
      # 正規経路（approve!）は guard を経ることと対比する
      host.approved!
      expect(host).to be_approved      # bang は guard を経ずに状態を変える＝呼んではならない
    end
  end
end
```

- [ ] **Step 3: 失敗を確認**

Run: `bundle exec rspec spec/models/concerns/approvable_spec.rb`
Expected: FAIL（`uninitialized constant Approvable`）。

- [ ] **Step 4: concern を実装**

`app/models/concerns/approvable.rb`:

```ruby
# frozen_string_literal: true

# 承認対象に業務ステータス（AASM）と段階導出を与える（SPEC §7.1・§13.2）。
# 段階情報は status に持たず ApprovalAssignment 群から導出する。
# host は `belongs_to :requester, class_name: "User"` を持つこと。
module Approvable
  extend ActiveSupport::Concern

  included do
    has_many :approval_assignments, as: :approvable, dependent: :destroy

    # enum を aasm より先に宣言（class ロード時にマッピングを解決するため）。
    # 整数 0–3 は凍結。4=withdrawal_requested / 5=withdrawn は 2-5 用に予約（§4.14 同型）。
    enum :approval_status, { applying: 0, approved: 1, rejected: 2, canceled: 3 }

    include AASM
    aasm column: :approval_status, enum: true, whiny_persistence: true do
      state :applying, initial: true
      state :approved
      state :rejected
      state :canceled

      event :approve do
        transitions from: :applying, to: :approved, guard: :all_stages_approved?
      end
      event :reject do
        transitions from: :applying, to: :rejected
      end
      event :cancel do
        transitions from: :applying, to: :canceled
      end
    end
  end

  # 最小の pending 段階 position（なければ nil）。association キャッシュに依存せず DB を引く
  def current_approval_position
    approval_assignments.where(decision: :pending).minimum(:position)
  end

  # 全 assignment が approved（最終 approve の guard）。assignment 皆無なら false
  def all_stages_approved?
    approval_assignments.exists? &&
      !approval_assignments.where.not(decision: :approved).exists?
  end
end
```

- [ ] **Step 5: パスを確認**

Run: `bundle exec rspec spec/models/concerns/approvable_spec.rb`
Expected: 全 example PASS。

- [ ] **Step 6: 全体回帰（テストホスト導入が既存に影響しないこと）**

Run: `bundle exec rspec`
Expected: 既存 spec を含め全 PASS（一時テーブル・定数漏れの副作用が無いこと）。

- [ ] **Step 7: lint + brakeman + commit**

```bash
bundle exec rubocop --force-exclusion app/models/concerns/approvable.rb spec/support/approvable_test_model.rb spec/models/concerns/approvable_spec.rb
bin/brakeman --no-pager
git add app/models/concerns/approvable.rb spec/support/approvable_test_model.rb spec/models/concerns/approvable_spec.rb
git commit -m "feat: Approvable concern（AASM 4状態・段階導出・テスト専用ホスト）"
```

---

## Task 5: Approvals エラー + RouteResolver（TDD）

**Files:**
- Create: `app/services/approvals/errors.rb`
- Create: `app/services/approvals/route_resolver.rb`
- Test: `spec/services/approvals/route_resolver_spec.rb`

- [ ] **Step 1: RouteResolver spec を書く（失敗する）**

`spec/services/approvals/route_resolver_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::RouteResolver do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  # 階層: hr（hr_admin）← dept（manager・hr 配下）← boss（manager・dept 配下）← emp（employee）
  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:dept) { create(:user, :manager_role, organization: org, manager: hr) }
  let(:boss) { create(:user, :manager_role, organization: org, manager: dept) }

  def resolve(user) = described_class.call(user)

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

    it "チェーン上の hr_admin が自分のみなら単段（部門長）に縮約" do
      requester_hr = create(:user, :hr_admin, organization: org, manager: boss) # boss←dept←hr だが hr は別人
      # boss/dept は manager、hr は別 → first_hr_admin_up_chain は hr を拾い [boss, hr]
      expect(resolve(requester_hr)).to eq([ boss, hr ])
    end
  end

  describe "テナント安全（クロステナント manager は解決しない）" do
    it "越境 manager_id を直接植えても Resolver は解決せず :manager_unset" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, :manager_role, organization: other) }
      emp = create(:user, organization: org)
      emp.update_column(:manager_id, foreign.id) # 検証迂回で越境 ID を植える
      expect { resolve(emp.reload) }.to raise_error(Approvals::RouteError) { |e| expect(e.reason).to eq(:manager_unset) }
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/approvals/route_resolver_spec.rb`
Expected: FAIL（`uninitialized constant Approvals::RouteResolver`）。

- [ ] **Step 3: エラークラスを実装**

`app/services/approvals/errors.rb`:

```ruby
# frozen_string_literal: true

module Approvals
  class Error < StandardError; end

  # ルート解決不能（manager 未設定 / チェーンに hr_admin 不在）。上位は「申請不可・セットアップ要」で握る
  class RouteError < Error
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("approval route error: #{reason}")
    end
  end

  class SelfApprovalError < Error; end   # #1/#2 自己承認
  class NotCurrentApprover < Error; end  # 現段階の担当者でない / 段階順序違反
  class ProxyNotSupported < Error; end   # 2-1 は acting_user==approver を pin（代理は §7.5）
end
```

- [ ] **Step 4: RouteResolver を実装**

`app/services/approvals/route_resolver.rb`:

```ruby
# frozen_string_literal: true

module Approvals
  # 固定 2 段ルート解決（SPEC §7.2）。requester → [stage1, stage2] or [stage1]（単段縮約）。
  # テナント文脈下で呼ぶこと（User#manager は acts_as_tenant スコープ）。
  class RouteResolver
    def self.call(requester) = new(requester).call

    def initialize(requester)
      @requester = requester
    end

    def call
      stage1 = @requester.manager
      raise RouteError.new(:manager_unset) if stage1.nil?

      [ stage1, resolve_stage2(stage1) ].compact.uniq(&:id)
    end

    private

    def resolve_stage2(stage1)
      if @requester.employee?
        stage1.manager                                  # 部門長（上上長）。nil なら単段縮約
      else
        first_hr_admin_up_chain || raise(RouteError.new(:hr_admin_unset))
      end
    end

    # requester.manager から上昇し最初の hr_admin を返す（requester 自身は始点に含めず自動除外）
    def first_hr_admin_up_chain
      node = @requester.manager
      while node
        return node if node.hr_admin?

        node = node.manager
      end
      nil
    end
  end
end
```

- [ ] **Step 5: パスを確認**

Run: `bundle exec rspec spec/services/approvals/route_resolver_spec.rb`
Expected: 全 example PASS。

- [ ] **Step 6: lint + commit**

```bash
bundle exec rubocop --force-exclusion app/services/approvals/errors.rb app/services/approvals/route_resolver.rb spec/services/approvals/route_resolver_spec.rb
git add app/services/approvals/errors.rb app/services/approvals/route_resolver.rb spec/services/approvals/route_resolver_spec.rb
git commit -m "feat: Approvals::RouteResolver（固定2段・縮約・role分岐+チェーン上hr_admin）"
```

---

## Task 6: Approvals::SelfApproval（TDD）

**Files:**
- Create: `app/services/approvals/self_approval.rb`
- Test: `spec/services/approvals/self_approval_spec.rb`

- [ ] **Step 1: spec を書く（失敗する）**

`spec/services/approvals/self_approval_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::SelfApproval do
  def violated?(req:, app:, act:)
    described_class.violated?(requester_id: req, approver_id: app, acting_user_id: act)
  end

  it "approver が requester 本人なら violated（#1 直接）" do
    expect(violated?(req: 1, app: 1, act: 1)).to be true
  end

  it "acting_user が requester 本人なら violated（#2 代理）" do
    expect(violated?(req: 1, app: 2, act: 1)).to be true
  end

  it "いずれも requester でなければ violated でない" do
    expect(violated?(req: 1, app: 2, act: 2)).to be false
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/approvals/self_approval_spec.rb`
Expected: FAIL（`uninitialized constant Approvals::SelfApproval`）。

- [ ] **Step 3: 実装**

`app/services/approvals/self_approval.rb`:

```ruby
# frozen_string_literal: true

module Approvals
  # 自己承認規則の単一ソース（SPEC §7.3 #1/#2）。enforce はサービス層と Pundit の二層。
  module SelfApproval
    module_function

    def violated?(requester_id:, approver_id:, acting_user_id:)
      approver_id == requester_id || acting_user_id == requester_id
    end
  end
end
```

- [ ] **Step 4: パス確認 + lint + commit**

```bash
bundle exec rspec spec/services/approvals/self_approval_spec.rb
bundle exec rubocop --force-exclusion app/services/approvals/self_approval.rb spec/services/approvals/self_approval_spec.rb
git add app/services/approvals/self_approval.rb spec/services/approvals/self_approval_spec.rb
git commit -m "feat: Approvals::SelfApproval（自己承認規則の単一ソース）"
```

---

## Task 7: Approvals::Start（TDD）

**Files:**
- Create: `app/services/approvals/start.rb`
- Test: `spec/services/approvals/start_spec.rb`

- [ ] **Step 1: spec を書く（失敗する）**

`spec/services/approvals/start_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::Start do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:dept) { create(:user, :manager_role, organization: org, manager: hr) }
  let(:boss) { create(:user, :manager_role, organization: org, manager: dept) }
  let(:emp)  { create(:user, organization: org, manager: boss) }

  it "ルート長に応じた pending assignment を position 順に生成する" do
    host = ApprovalTestRecord.create!(requester: emp)
    described_class.call(host)

    assignments = host.approval_assignments.order(:position)
    expect(assignments.map(&:position)).to eq([ 1, 2 ])
    expect(assignments.map(&:approver)).to eq([ boss, dept ])
    expect(assignments.map(&:decision)).to all(eq("pending"))
  end

  it "単段縮約時は 1 件だけ生成" do
    top = create(:user, :manager_role, organization: org)
    solo = create(:user, organization: org, manager: top)
    host = ApprovalTestRecord.create!(requester: solo)
    described_class.call(host)
    expect(host.approval_assignments.count).to eq(1)
  end

  it "冪等（再呼出で増えない）" do
    host = ApprovalTestRecord.create!(requester: emp)
    described_class.call(host)
    expect { described_class.call(host) }.not_to change { host.approval_assignments.count }
  end

  it "RouteError 時は呼び出し側 tx をロールバック（host 未永続）" do
    no_manager = create(:user, organization: org, manager: nil)
    expect {
      ActiveRecord::Base.transaction do
        host = ApprovalTestRecord.create!(requester: no_manager)
        described_class.call(host)
      end
    }.to raise_error(Approvals::RouteError)
    expect(ApprovalTestRecord.count).to eq(0)
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/approvals/start_spec.rb`
Expected: FAIL（`uninitialized constant Approvals::Start`）。

- [ ] **Step 3: 実装**

`app/services/approvals/start.rb`:

```ruby
# frozen_string_literal: true

module Approvals
  # 承認エンジンの明示起動（SPEC §7.7）。route 解決 → pending な ApprovalAssignment を生成。
  # 2-2+ の申請作成サービスが save! と同一 tx で呼ぶ。2-1 は spec が呼ぶ。
  class Start
    def self.call(approvable) = new(approvable).call

    def initialize(approvable)
      @approvable = approvable
    end

    def call
      return @approvable if @approvable.approval_assignments.exists? # 冪等

      approvers = RouteResolver.call(@approvable.requester)
      ApprovalAssignment.transaction do
        approvers.each_with_index do |approver, idx|
          @approvable.approval_assignments.create!(
            organization: @approvable.organization,
            approver:,
            position: idx + 1,
            decision: :pending
          )
        end
      end
      @approvable
    end
  end
end
```

- [ ] **Step 4: パス確認 + lint + commit**

```bash
bundle exec rspec spec/services/approvals/start_spec.rb
bundle exec rubocop --force-exclusion app/services/approvals/start.rb spec/services/approvals/start_spec.rb
git add app/services/approvals/start.rb spec/services/approvals/start_spec.rb
git commit -m "feat: Approvals::Start（route→pending assignment 生成・冪等・明示起動）"
```

---

## Task 8: Approvals::Approve（TDD）

**Files:**
- Create: `app/services/approvals/approve.rb`
- Test: `spec/services/approvals/approve_spec.rb`

- [ ] **Step 1: spec を書く（失敗する）**

`spec/services/approvals/approve_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::Approve do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:dept) { create(:user, :manager_role, organization: org, manager: hr) }
  let(:boss) { create(:user, :manager_role, organization: org, manager: dept) }
  let(:emp)  { create(:user, organization: org, manager: boss) }     # route: [boss, dept]
  let(:host) { ApprovalTestRecord.create!(requester: emp).tap { |h| Approvals::Start.call(h) } }

  def approve(approver:, **kw) = described_class.call(approvable: host, approver:, **kw)

  describe "段階進行" do
    it "stage1 承認後も applying を維持（premature approve! を撃たない）" do
      approve(approver: boss)
      expect(host.reload).to be_applying
      expect(host.approval_assignments.find_by(position: 1).decision).to eq("approved")
    end

    it "最終段階の承認で approved になる" do
      approve(approver: boss)
      approve(approver: dept)
      expect(host.reload).to be_approved
    end

    it "単段ルートは 1 回の承認で approved" do
      top = create(:user, :manager_role, organization: org)
      solo = create(:user, organization: org, manager: top)
      h = ApprovalTestRecord.create!(requester: solo).tap { |x| Approvals::Start.call(x) }
      described_class.call(approvable: h, approver: top)
      expect(h.reload).to be_approved
    end
  end

  describe "自己承認防止" do
    it "#1 直接: approver が requester 本人なら SelfApprovalError" do
      # emp 自身を stage1 approver に差し替えて検証
      host.approval_assignments.find_by(position: 1).update_column(:approver_id, emp.id)
      expect { approve(approver: emp) }.to raise_error(Approvals::SelfApprovalError)
    end

    it "#2 代理: acting_user が requester なら SelfApprovalError" do
      # acting_user pin を外すため approver は正当な boss、acting_user に requester を渡す → まず pin で弾く前に
      # pin より自己承認を優先したくないので、ここは acting_user==approver の正当系に requester を混ぜない。
      # 代理の自己承認は pin 解除後（§7.5）の経路ゆえ、2-1 では #2 は pin で到達不能であることを下の pin テストで担保する。
      skip "2-1 は acting_user==approver を pin。#2 単独は §7.5 で検証"
    end

    it "代理 pin: acting_user != approver は ProxyNotSupported" do
      expect { approve(approver: boss, acting_user: dept) }.to raise_error(Approvals::ProxyNotSupported)
    end
  end

  describe "段階順序 / 現段階担当" do
    it "現段階でない承認者は NotCurrentApprover" do
      expect { approve(approver: dept) }.to raise_error(Approvals::NotCurrentApprover) # stage2 を先に
    end

    it "第三者は NotCurrentApprover" do
      stranger = create(:user, :manager_role, organization: org)
      expect { approve(approver: stranger) }.to raise_error(Approvals::NotCurrentApprover)
    end
  end

  describe "terminal / 残 pending バイパス防止" do
    it "却下後の残 pending を approve しても applying? ガードで弾く" do
      Approvals::Reject.call(approvable: host, approver: boss, comment: "却下")
      expect(host.reload).to be_rejected
      expect { approve(approver: dept) }.to raise_error(AASM::InvalidTransition)
      expect(host.approval_assignments.find_by(position: 2).decision).to eq("pending") # 黙って approved にしない
    end

    it "同一 assignment の二重承認は 2 回目で弾く（冪等）" do
      approve(approver: boss)
      expect { approve(approver: boss) }.to raise_error(Approvals::NotCurrentApprover)
    end
  end
end
```

> 注: 上記 `#2 代理` example は 2-1 の pin 仕様（acting_user==approver 強制）により単独到達不能ゆえ `skip` で意図を残す（§7.5 で有効化）。pin 自体は「代理 pin」example で検証する。

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/approvals/approve_spec.rb`
Expected: FAIL（`uninitialized constant Approvals::Approve`）。`Approvals::Reject` 参照箇所も未定義だが、本タスクでは Reject 依存 example（terminal）も含むため、Reject 実装後に緑化する。まず Approve を実装し、Reject 依存 example は次タスクで通す（順序上、本タスクの `bundle exec rspec` は terminal example のみ赤が残り得る — その 1 件は Task 9 完了時に緑になることを確認する）。

- [ ] **Step 3: 実装**

`app/services/approvals/approve.rb`:

```ruby
# frozen_string_literal: true

module Approvals
  # 承認（SPEC §7.3）。terminal/pin/自己承認/段階順序を gate し、現段階 assignment を approved に。
  # 最終段階なら host の AASM approve! を発火（2-1 は副作用なし）。with_lock で段階進行を直列化。
  class Approve
    def self.call(approvable:, approver:, acting_user: approver, comment: nil)
      new(approvable:, approver:, acting_user:, comment:).call
    end

    def initialize(approvable:, approver:, acting_user:, comment:)
      @approvable = approvable
      @approver = approver
      @acting_user = acting_user
      @comment = comment
    end

    def call
      @approvable.with_lock do
        guard!
        assignment = current_assignment!
        assignment.update!(decision: :approved, acted_at: Time.current, comment: @comment)
        @approvable.approve! if @approvable.all_stages_approved?
      end
      @approvable
    end

    private

    def guard!
      raise AASM::InvalidTransition.new(@approvable, :approve, :default) unless @approvable.applying?
      raise ProxyNotSupported unless @acting_user.id == @approver.id # 2-1 pin（代理は §7.5）

      return unless SelfApproval.violated?(
        requester_id: @approvable.requester_id,
        approver_id: @approver.id,
        acting_user_id: @acting_user.id
      )

      raise SelfApprovalError
    end

    def current_assignment!
      position = @approvable.current_approval_position
      assignment = @approvable.approval_assignments.find_by(position:, decision: :pending)
      raise NotCurrentApprover unless assignment && assignment.approver_id == @approver.id

      assignment
    end
  end
end
```

- [ ] **Step 4: パスを確認（terminal example を除く）**

Run: `bundle exec rspec spec/services/approvals/approve_spec.rb`
Expected: `Approvals::Reject` 依存の terminal example 以外は PASS。terminal example の赤は Task 9 完了で解消する旨を確認。

- [ ] **Step 5: lint + commit**

```bash
bundle exec rubocop --force-exclusion app/services/approvals/approve.rb spec/services/approvals/approve_spec.rb
git add app/services/approvals/approve.rb spec/services/approvals/approve_spec.rb
git commit -m "feat: Approvals::Approve（段階進行・自己承認#1#2#3・terminal/pin ガード・最終AASM）"
```

---

## Task 9: Approvals::Reject（TDD）

**Files:**
- Create: `app/services/approvals/reject.rb`
- Test: `spec/services/approvals/reject_spec.rb`

- [ ] **Step 1: spec を書く（失敗する）**

`spec/services/approvals/reject_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::Reject do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:dept) { create(:user, :manager_role, organization: org, manager: hr) }
  let(:boss) { create(:user, :manager_role, organization: org, manager: dept) }
  let(:emp)  { create(:user, organization: org, manager: boss) }     # route: [boss, dept]
  let(:host) { ApprovalTestRecord.create!(requester: emp).tap { |h| Approvals::Start.call(h) } }

  def reject(approver:, comment: "却下理由", **kw)
    described_class.call(approvable: host, approver:, comment:, **kw)
  end

  it "どの段階でも全体却下になる" do
    reject(approver: boss)
    expect(host.reload).to be_rejected
  end

  it "却下理由(comment)が空なら拒否" do
    expect { reject(approver: boss, comment: nil) }.to raise_error(ArgumentError)
  end

  it "却下後も残 pending は残置（行を消さない）" do
    reject(approver: boss)
    expect(host.approval_assignments.find_by(position: 2).decision).to eq("pending")
  end

  it "却下後に他段階承認者が approve できない（terminal）" do
    reject(approver: boss)
    expect { Approvals::Approve.call(approvable: host, approver: dept) }
      .to raise_error(AASM::InvalidTransition)
  end

  it "現段階でない承認者は NotCurrentApprover" do
    expect { reject(approver: dept) }.to raise_error(Approvals::NotCurrentApprover)
  end

  it "代理 pin: acting_user != approver は ProxyNotSupported" do
    expect { reject(approver: boss, acting_user: dept) }.to raise_error(Approvals::ProxyNotSupported)
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/approvals/reject_spec.rb`
Expected: FAIL（`uninitialized constant Approvals::Reject`）。

- [ ] **Step 3: 実装**

`app/services/approvals/reject.rb`:

```ruby
# frozen_string_literal: true

module Approvals
  # 却下（SPEC §7.3）。どの段階でも全体却下。terminal/pin/自己承認/段階順序を gate。
  class Reject
    def self.call(approvable:, approver:, comment:, acting_user: approver)
      new(approvable:, approver:, acting_user:, comment:).call
    end

    def initialize(approvable:, approver:, acting_user:, comment:)
      @approvable = approvable
      @approver = approver
      @acting_user = acting_user
      @comment = comment
    end

    def call
      raise ArgumentError, "却下理由が必要です" if @comment.blank?

      @approvable.with_lock do
        guard!
        assignment = current_assignment!
        assignment.update!(decision: :rejected, acted_at: Time.current, comment: @comment)
        @approvable.reject!
      end
      @approvable
    end

    private

    def guard!
      raise AASM::InvalidTransition.new(@approvable, :reject, :default) unless @approvable.applying?
      raise ProxyNotSupported unless @acting_user.id == @approver.id

      return unless SelfApproval.violated?(
        requester_id: @approvable.requester_id,
        approver_id: @approver.id,
        acting_user_id: @acting_user.id
      )

      raise SelfApprovalError
    end

    def current_assignment!
      position = @approvable.current_approval_position
      assignment = @approvable.approval_assignments.find_by(position:, decision: :pending)
      raise NotCurrentApprover unless assignment && assignment.approver_id == @approver.id

      assignment
    end
  end
end
```

> `guard!` / `current_assignment!` は Approve と同形。重複を嫌うなら本タスク完了後に共有モジュール（`Approvals::DecisionGuards` 等）へ抽出してよいが、本スライスでは 2 サービスのみゆえ各サービスに保持する（早すぎる抽象を避ける）。

- [ ] **Step 4: パス確認（Reject + Approve の terminal example も緑化）**

Run: `bundle exec rspec spec/services/approvals/reject_spec.rb spec/services/approvals/approve_spec.rb`
Expected: 両ファイルとも全 example PASS（Task 8 で残した terminal example もここで緑）。

- [ ] **Step 5: lint + commit**

```bash
bundle exec rubocop --force-exclusion app/services/approvals/reject.rb spec/services/approvals/reject_spec.rb
git add app/services/approvals/reject.rb spec/services/approvals/reject_spec.rb
git commit -m "feat: Approvals::Reject（全体却下・comment必須・残置・terminal/pin ガード）"
```

---

## Task 10: ApprovalAssignmentPolicy（TDD）

**Files:**
- Create: `app/policies/approval_assignment_policy.rb`
- Test: `spec/policies/approval_assignment_policy_spec.rb`

- [ ] **Step 1: policy spec を書く（失敗する）**

`spec/policies/approval_assignment_policy_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApprovalAssignmentPolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:dept) { create(:user, :manager_role, organization: org, manager: hr) }
  let(:boss) { create(:user, :manager_role, organization: org, manager: dept) }
  let(:emp)  { create(:user, organization: org, manager: boss) }
  let(:host) { ApprovalTestRecord.create!(requester: emp).tap { |h| Approvals::Start.call(h) } }
  let(:record) { host.approval_assignments.find_by(position: 1) } # 現段階 = boss

  context "現段階の担当者本人" do
    let(:actor) { boss }
    it { is_expected.to permit_actions(%i[approve reject]) }
  end

  context "申請者本人（自己承認 #1）" do
    let(:actor) { emp }
    before { record.update_column(:approver_id, emp.id) } # emp を担当者に差し替え
    it { is_expected.to forbid_actions(%i[approve reject]) }
  end

  context "現段階でない担当者（stage2 を先に）" do
    let(:actor) { dept }
    let(:record) { host.approval_assignments.find_by(position: 2) }
    it { is_expected.to forbid_actions(%i[approve reject]) }
  end

  context "第三者" do
    let(:actor) { create(:user, :manager_role, organization: org) }
    it { is_expected.to forbid_actions(%i[approve reject]) }
  end

  context "terminal な approvable" do
    let(:actor) { boss }
    before { Approvals::Reject.call(approvable: host, approver: boss, comment: "却下") }
    it "却下後は不可" do
      expect(subject.approve?).to be(false)
    end
  end

  context "決裁済 assignment" do
    let(:actor) { boss }
    before { Approvals::Approve.call(approvable: host, approver: boss) }
    it "再決裁は不可（pending でない）" do
      expect(described_class.new(boss, record.reload).approve?).to be(false)
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/policies/approval_assignment_policy_spec.rb`
Expected: FAIL（`uninitialized constant ApprovalAssignmentPolicy`）。

- [ ] **Step 3: 実装**

`app/policies/approval_assignment_policy.rb`:

```ruby
# frozen_string_literal: true

# 自己承認防止の認可層（SPEC §7.3・サービス層と独立した二層の片側）。
# 自己承認規則の定義は Approvals::SelfApproval に一元化（enforce のみ二層）。
class ApprovalAssignmentPolicy < ApplicationPolicy
  def approve? = actionable?
  def reject?  = actionable?

  private

  def actionable?
    record.pending? &&
      record.approvable.applying? &&                                    # terminal は不可
      record.approver_id == user.id &&                                  # 現段階の担当者本人（§7.5 で delegate 緩和）
      record.position == record.approvable.current_approval_position && # 段階順序
      !Approvals::SelfApproval.violated?(
        requester_id: record.approvable.requester_id,
        approver_id: record.approver_id,
        acting_user_id: user.id
      )
  end
end
```

- [ ] **Step 4: パスを確認**

Run: `bundle exec rspec spec/policies/approval_assignment_policy_spec.rb`
Expected: 全 example PASS。

- [ ] **Step 5: lint + brakeman + commit**

```bash
bundle exec rubocop --force-exclusion app/policies/approval_assignment_policy.rb spec/policies/approval_assignment_policy_spec.rb
bin/brakeman --no-pager
git add app/policies/approval_assignment_policy.rb spec/policies/approval_assignment_policy_spec.rb
git commit -m "feat: ApprovalAssignmentPolicy（自己承認防止の認可層・SelfApproval 共有）"
```

---

## Task 11: 仕上げ — 全体回帰・ROADMAP 更新・preflight

**Files:**
- Modify: `docs/ROADMAP.md`（Phase 2-1 行）

- [ ] **Step 1: 全体回帰**

Run: `bundle exec rspec`
Expected: 全 example PASS（既存 + 新規）。

- [ ] **Step 2: lint 全体 + brakeman**

Run: `bundle exec rubocop && bin/brakeman --no-pager`
Expected: offense 0・警告 0。

- [ ] **Step 3: ROADMAP の 2-1 行を更新**

`docs/ROADMAP.md` の Phase 2 の該当行をチェック済みにし PR 番号を付す（PR 作成後に番号確定 → 番号は PR 本文/マージ前に追記）:

```markdown
- [x] **2-1 承認エンジン core**: ApprovalAssignment・固定 2 段ルート解決（単段縮約）・自己承認防止 4 種（§7.2〜7.3）・AASM 業務ステータス（#<PR番号>）
```

> 撤回（#4）と代理（#2 の delegate 実体）は §7.5/2-5 へ後置である旨を行末か脚注で明記してよい（設計 doc §0 後置に準拠）。

- [ ] **Step 4: preflight**

Run: `/preflight`（push / PR 前の CI 等価チェック）
Expected: rspec・rubocop・brakeman・coverage が緑。

- [ ] **Step 5: Commit（ROADMAP）**

```bash
git add docs/ROADMAP.md
git commit -m "docs: ROADMAP 2-1 承認エンジン core を完了に更新"
```

- [ ] **Step 6: PR 作成（gh アカウント確認）**

`gh api user --jq .login` で active を確認し `kei1110` でなければ `gh auth switch -u kei1110`（メモリ: gh-cli-account-mismatch）。PR 本文に設計 doc リンク・多視点レビュー反映の要点・後置（撤回/代理/UI）を明記。PR 番号確定後、ROADMAP の `#<PR番号>` を実番号へ修正してからマージ。

---

## Self-Review（writing-plans のチェックリスト結果）

**1. Spec coverage（設計 §1–§8 → タスク対応）:**
- §1 ApprovalAssignment（テーブル/モデル/検証/複合FK）→ Task 2, 3 ✓
- §2 Approvable concern（AASM・enum凍結・helper・whiny・宣言順）→ Task 1(gem), 4 ✓
- §3 RouteResolver（role分岐・縮約・エラー・hr_admin エッジ・クロステナント）→ Task 5 ✓
- §4 Start/Approve/Reject（with_lock・自己承認#1#2#3・pin・terminal・SelfApproval）→ Task 6, 7, 8, 9 ✓
- §5 ApprovalAssignmentPolicy（二層・SelfApproval 共有）→ Task 10 ✓
- §6 テスト戦略（テストホスト before(:suite)・負例・DB最終防衛・中間状態 assert）→ 各 Task の spec ✓
- §7 manifest → File Structure 表 + 各 Task ✓（Cancel/Scope/helper は後置で不在＝意図的）
- §8 RAILS_GOTCHAS → 共通留意 + Task 内コメント ✓

**2. Placeholder scan:** TBD/TODO/「適宜」なし。各コード step は完全コードを掲載。1 箇所 `skip`（#2 代理単独）は 2-1 pin 仕様による到達不能を意図的に残すもので、理由を明記済（プレースホルダではない）。

**3. Type consistency:** `Approvals::{RouteResolver,Start,Approve,Reject,SelfApproval}` の `.call` 署名、`RouteError#reason`、`ApprovalAssignment.decisions`/`approval_statuses`、`current_approval_position`/`all_stages_approved?`、Policy の `actionable?` は全タスク間で一致。エラークラス（RouteError/SelfApprovalError/NotCurrentApprover/ProxyNotSupported）は Task 5 で定義し Task 8/9/10 で参照。

**既知の順序依存:** Task 8 の terminal example は `Approvals::Reject`（Task 9）に依存するため、Task 8 単独実行ではその 1 件が赤。Task 9 完了時に緑になることを Task 9 Step 4 で確認する（plan 内に明記済）。
