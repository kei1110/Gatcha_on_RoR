# Phase 3-2 締め状態機械 + 申請制限 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `MonthlyAttendanceSummary` に締め状態機械（提出→確定→差戻し→再提出）を載せ、締め済み月への申請・撤回・承認を fail-closed で制限し、複数社員分の確定を SolidQueue で非同期化する。

**Architecture:** 既存の型非依存承認エンジン（`Approvable`/`Withdrawable`/`Approvals::Approve`）と 3-1 の集計エンジン（`AttendancePeriod`/`MonthlySummaries::Aggregate`）の上に、(1) `MonthlyAttendanceSummary` の AASM、(2) 締めロック述語 `ClosingLock` と注入 concern `ClosingRestricted` を単一チョークポイント（`Approve#guard!`）へ差し込む横断制限、(3) 提出前チェック `PendingRequests`、(4) `BulkFinalizeJob`（初の SolidQueue）を重ねる。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / AASM / acts_as_tenant / Pundit / SolidQueue / RSpec / FactoryBot / Hotwire(Turbo)。

## Global Constraints

設計 spec: `docs/superpowers/specs/2026-06-20-phase-3-2-closing-state-machine-design.md`（本計画の典拠・各 Task が参照）。

- **マルチテナント安全（SPEC §3.6）:** 全ドメインモデルに `acts_as_tenant(:organization)`。リクエスト文脈を持たない経路（SolidQueue ジョブ）は `ActsAsTenant.with_tenant(org)` でラップ必須。ユーザー参照 FK は同一テナント強制。
- **サーバ権威（mass-assignment 締め出し）:** `status` / `deferral_reason` は AASM イベント（submit/finalize/defer）経由のみで更新。`update_column`/`update_all`/mass-assignment 禁止。controller の strong params で両カラムを一切 permit しない。`deferral_reason` は `MonthlySummaries::Defer` サービス権威でのみ代入。
- **認可（Pundit）:** 全 action に `authorize`、一覧は `policy_scope`（`verify_policy_scoped` が index で発火）。単一操作の record 取得は `policy_scope(Model).find(params[:id])`（scope 外 404）。一括は enqueue 前に `policy_scope` 交差。
- **書き込み redirect は `status: :see_other`**（Turbo の 302 メソッド保持回避・RAILS_GOTCHAS）。
- **enum は `validate: true`**（不正値を 422 に・RAILS_GOTCHAS）。値名が AR メソッドと衝突するなら `prefix:`。
- **コミット:** 1 Task = 1 コミット（squash 前提）。各 Task 完了時に `bundle exec rspec <該当spec>` と、app/ に触れたら `bundle exec rubocop --force-exclusion <files>` が緑であること。
- **コミット境界（部分 revert 可能・spec §5）:** Group A（Task 1–8 状態機械+サービス・同期）/ Group B（Task 9–14 横断制限）/ Group C（Task 15–17 SolidQueue+一括）。Group A は SolidQueue 不在でも動く。
- **テナント文脈の spec 作法（gen-spec）:** model/policy spec は `test_tenant` 自動。request/system は `tenant_host(org)` でホストを名乗り `with_tenant` で factory を明示包み。新 factory のテナント帰属カラムは `ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization)` を踏襲。
- **RAILS_GOTCHAS 注入:** `Date.strptime` は厳格でない→`AttendancePeriod::YEAR_MONTH_FORMAT` で regex 検証後に。`ShowExceptions` 経由は session 非 commit→`rescue_from` で controller 層 404。

---

## 既存コードの consume サマリ（全 Task 共通の参照・実物確認済）

- `AttendancePeriod.new(organization:, year_month:)` → `#range`(Range<Date>) / `#week_window` / `#next` / `#prev` / `#label`(= year_month) / `::YEAR_MONTH_FORMAT`(`/\A\d{4}-(0[1-9]|1[0-2])\z/`)。`app/models/attendance_period.rb`
- `MonthlySummaries::Aggregate.call(user:, period:, day_types: nil)` → `MonthlyAttendanceSummary` を返す（`find_or_initialize_by(user:, year_month: period.label)` → `update!`）。`app/services/monthly_summaries/aggregate.rb`
- `Organization#setting`(lazy) / `#today`(組織 TZ の Date) / `#fiscal_year_for(date)` / `#time_zone`。`app/models/organization.rb`
- `Approvals::Approve.call(approvable:, approver:, acting_user: approver, comment: nil)`。`#guard!` 内に `raise ... unless @approvable.awaiting_decision?` などの gate。`app/services/approvals/approve.rb`
- `Approvable`（concern）: `enum :approval_status`、`awaiting_decision?`、`active_purpose`、`current_approval_position`、`all_stages_approved?`、`apply_approval_effects!(acting_user:)=nil`(no-op 既定)、`has_many :approval_assignments, as: :approvable`。`app/models/concerns/approvable.rb`
- `Withdrawable`（concern・`include Approvable`）: `aasm` 再オープンで `request_withdrawal`(guard `no_prior_withdrawal_round?`)/`approve_withdrawal`/`reject_withdrawal`。`app/models/concerns/withdrawable.rb`
- `Approvals` エラー: `module Approvals` 直下に `class Error < StandardError`、`ConflictError < Error` 等。`app/services/approvals.rb`
- `ApprovalAssignment`: `purpose`(enum・`purpose_withdrawal?`)、`position`、`decision`(enum pending/approved/...)、`approver_id`、`acted_at`、`approvable`(polymorphic)。
- 申請モデルの対象日: LR=`start_date`/`end_date`（`belongs_to :requester`）、CCR=`attendance_record.work_date`（`belongs_to :attendance_record, optional: true`・`belongs_to :requester`）、HWR=`work_date`（`belongs_to :requester`）。
- `User`: `manager_id` / `belongs_to :manager` / `has_many :subordinates`（`foreign_key: :manager_id`）/ `enum :role {employee:0, manager:1, hr_admin:2}` / `#hr_admin?` / `#manager?`。**`subordinate_of?` は未実装**（直属 manager で判定する／後述 Task 12 の決定）。
- Policy: `ApplicationPolicy`（既定 deny・`index?=false` 等）+ `Scope`(既定 `scope.none`)。precedent: `ProxyClockingPolicy`（role ゲート + Scope は `manager_id: user.id` 直属）。`app/policies/`
- Controller precedent: `LeaveRequestsController`（`set_x = policy_scope(X).find(params[:id])`・`authorize`・`redirect ... status: :see_other`）、`ApprovalAssignmentsController#approve`（`rescue Approvals::ConflictError` の文言分岐箇所）。
- factory: `:monthly_attendance_summary`(organization/user/year_month "2026-03")、`:leave_request`、`:clock_change_request`(attendance_record `:done`)、`:holiday_work_request`(work_date 日曜)。`spec/factories/`
- 本番 queue 設定（既存）: `config/environments/production.rb` に `config.active_job.queue_adapter = :solid_queue` + `config.solid_queue.connects_to = { database: { writing: :queue } }`。dev/test は未設定。`db/queue_schema.rb` 存在。

---

## Task 1: migration — status / deferral_reason カラム追加

**Files:**
- Create: `db/migrate/YYYYMMDDHHMMSS_add_status_to_monthly_attendance_summaries.rb`
- Modify: `db/schema.rb`（migration 実行で自動・手編集禁止）

**Interfaces:**
- Produces: `monthly_attendance_summaries.status`(integer NOT NULL default 0) / `.deferral_reason`(text NULL)

- [ ] **Step 1: migration を生成**

Run: `bin/rails g migration AddStatusToMonthlyAttendanceSummaries`

- [ ] **Step 2: migration 本文を書く**

```ruby
# frozen_string_literal: true

class AddStatusToMonthlyAttendanceSummaries < ActiveRecord::Migration[8.1]
  def change
    add_column :monthly_attendance_summaries, :status, :integer, null: false, default: 0
    add_column :monthly_attendance_summaries, :deferral_reason, :text
  end
end
```

> 補助 index `(organization_id, status)` は v1 では入れない（spec §1.1・YAGNI・§16.1 規模では full scan 許容）。

- [ ] **Step 3: migrate**

Run: `bin/rails db:migrate`
Expected: `monthly_attendance_summaries` に 2 カラム追加。`db/schema.rb` に反映。

- [ ] **Step 4: 既存行が aggregating で読めることを確認（backfill 検証）**

Run: `bin/rails runner 'ActsAsTenant.with_tenant(Organization.first) { p MonthlyAttendanceSummary.columns_hash["status"].default }'`
Expected: `"0"`（既存行は status=0=aggregating）。

- [ ] **Step 5: Commit**

```bash
git add db/migrate db/schema.rb
git commit -m "feat(3-2): MonthlyAttendanceSummary に status/deferral_reason カラム追加"
```

---

## Task 2: AASM 状態機械を MonthlyAttendanceSummary に載せる

**Files:**
- Modify: `app/models/monthly_attendance_summary.rb`
- Test: `spec/models/monthly_attendance_summary_spec.rb`

**Interfaces:**
- Produces: `enum :status {aggregating:0, submitted:1, finalized:2, deferred:3}`、AASM events `submit`/`finalize`/`defer`（bang 版 `submit!`/`finalize!`/`defer!`）、`deferral_reason` presence validation（deferred 時）

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/monthly_attendance_summary_spec.rb` に追記（既存の集計列 spec は残す）:

```ruby
require "rails_helper"

RSpec.describe MonthlyAttendanceSummary, type: :model do
  describe "締め状態機械（AASM・§13.4）" do
    let(:summary) { create(:monthly_attendance_summary) }

    it "初期状態は aggregating" do
      expect(summary).to be_aggregating
    end

    it "submit で aggregating → submitted" do
      summary.submit!
      expect(summary).to be_submitted
    end

    it "submit で deferred → submitted（再提出）" do
      summary.update!(status: :deferred, deferral_reason: "修正依頼")
      summary.submit!
      expect(summary).to be_submitted
    end

    it "finalize で submitted → finalized" do
      summary.submit!
      summary.finalize!
      expect(summary).to be_finalized
    end

    it "defer で submitted → deferred（reason 必須）" do
      summary.submit!
      summary.deferral_reason = "打刻漏れ"
      summary.defer!
      expect(summary).to be_deferred
    end

    it "defer で finalized → deferred（finalized は terminal でない）" do
      summary.submit!
      summary.finalize!
      summary.deferral_reason = "確定後の修正"
      summary.defer!
      expect(summary).to be_deferred
    end

    # 負例（fail-closed・偽テスト防止）
    it "aggregating から finalize! は InvalidTransition" do
      expect { summary.finalize! }.to raise_error(AASM::InvalidTransition)
    end

    it "aggregating から defer! は InvalidTransition" do
      expect { summary.defer! }.to raise_error(AASM::InvalidTransition)
    end

    it "finalized から submit! 直行は InvalidTransition（deferred 経由必須）" do
      summary.submit!
      summary.finalize!
      expect { summary.submit! }.to raise_error(AASM::InvalidTransition)
    end

    it "差戻しは aggregating へ戻さない（defer の遷移先は deferred のみ）" do
      summary.submit!
      summary.deferral_reason = "x"
      summary.defer!
      expect(summary).not_to be_aggregating
    end

    it "deferred で deferral_reason 空なら invalid（whiny_persistence で defer! 例外）" do
      summary.submit!
      summary.deferral_reason = nil
      expect { summary.defer! }.to raise_error(ActiveRecord::RecordInvalid)
    end

    it "resubmit 後も deferral_reason を保持する（監査痕）" do
      summary.update!(status: :deferred, deferral_reason: "修正依頼")
      summary.submit!
      expect(summary.deferral_reason).to eq("修正依頼")
      expect(summary).to be_valid
    end
  end
end
```

- [ ] **Step 2: テストが落ちるのを確認**

Run: `bundle exec rspec spec/models/monthly_attendance_summary_spec.rb -e "締め状態機械"`
Expected: FAIL（`submit!` 等が未定義・NoMethodError）

- [ ] **Step 3: 最小実装**

`app/models/monthly_attendance_summary.rb` を編集。既存の `validates :year_month ...` の後ろに enum/AASM を追加し、冒頭コメントを更新:

```ruby
# frozen_string_literal: true

# 月次（締め期間）サマリ（SPEC §4.13・3-1 設計 §1.1・3-2 設計 §1.2）。永久保持・長期参照の基点。
# 締め状態機械（AASM・§13.4）を 3-2 で追加。status/deferral_reason はサーバ権威（AASM event 経由のみ・
# strong params 不受領・update_column/all 禁止）。
class MonthlyAttendanceSummary < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user

  AGGREGATE_COLUMNS = %i[
    scheduled_work_days work_days total_work_hours total_overtime_hours
    overtime_hours_over_60 holiday_work_hours total_deep_night_hours late_days early_leave_days
  ].freeze

  # enum を aasm より先に宣言（class ロード時マッピング解決・Approvable と同型）
  enum :status, { aggregating: 0, submitted: 1, finalized: 2, deferred: 3 }

  validates :year_month, presence: true, format: { with: /\A\d{4}-(0[1-9]|1[0-2])\z/ }
  validates_uniqueness_to_tenant :year_month, scope: :user_id
  validates(*AGGREGATE_COLUMNS, numericality: { greater_than_or_equal_to: 0 })
  validates :deferral_reason, presence: true, if: :deferred?
  validate :user_must_belong_to_same_organization

  include AASM
  aasm column: :status, enum: true, whiny_persistence: true do # bang の save 失敗を例外化
    state :aggregating, initial: true
    state :submitted
    state :finalized
    state :deferred

    event :submit do # 提出 / 再提出（副作用＝MonthlySummaries::Submit 側・3-2 設計 D2）
      transitions from: %i[aggregating deferred], to: :submitted
    end
    event :finalize do
      transitions from: :submitted, to: :finalized
    end
    event :defer do # 差戻し（deferral_reason 必須・whiny_persistence で空は例外）
      transitions from: %i[submitted finalized], to: :deferred
    end
  end

  private

  # ID 基点 fail-closed（leave_balance.rb:27 同型・§3.6）。
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id

    errors.add(:user, "は同一組織でなければなりません")
  end
end
```

- [ ] **Step 4: テストが通るのを確認**

Run: `bundle exec rspec spec/models/monthly_attendance_summary_spec.rb`
Expected: PASS（全 example）

- [ ] **Step 5: rubocop**

Run: `bundle exec rubocop --force-exclusion app/models/monthly_attendance_summary.rb`
Expected: no offenses

- [ ] **Step 6: Commit**

```bash
git add app/models/monthly_attendance_summary.rb spec/models/monthly_attendance_summary_spec.rb
git commit -m "feat(3-2): MonthlyAttendanceSummary に締め状態機械（AASM 5 遷移）"
```

---

## Task 3: AttendancePeriod.containing（date → 締め期間の逆写像）

**Files:**
- Modify: `app/models/attendance_period.rb`
- Test: `spec/models/attendance_period_spec.rb`

**Interfaces:**
- Consumes: `AttendancePeriod.new(organization:, year_month:)` / `#range` / `#next`（既存）
- Produces: `AttendancePeriod.containing(organization:, date:)` → `AttendancePeriod`（date を含む締め期間）

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/attendance_period_spec.rb` に追記:

```ruby
RSpec.describe AttendancePeriod, type: :model do
  describe ".containing（逆写像・3-2 設計 §2.1）" do
    let(:org) { create(:organization) }

    context "closing_day = 31（月末締め）" do
      before { org.setting.update!(closing_day: 31) }

      it "月内の任意日は同暦月期を返す（下限は常に満たす）" do
        period = described_class.containing(organization: org, date: Date.new(2026, 3, 31))
        expect(period.label).to eq("2026-03")
      end

      it "月初日も同暦月期" do
        period = described_class.containing(organization: org, date: Date.new(2026, 3, 1))
        expect(period.label).to eq("2026-03")
      end
    end

    context "closing_day = 20" do
      before { org.setting.update!(closing_day: 20) }

      it "期末日（3/20）は当期（2026-03）" do
        period = described_class.containing(organization: org, date: Date.new(2026, 3, 20))
        expect(period.label).to eq("2026-03")
      end

      it "期末日+1（3/21）は翌期（2026-04）" do
        period = described_class.containing(organization: org, date: Date.new(2026, 3, 21))
        expect(period.label).to eq("2026-04")
      end

      it "年跨ぎ（12/25 → 翌年 1 月期）" do
        period = described_class.containing(organization: org, date: Date.new(2026, 12, 25))
        expect(period.label).to eq("2027-01")
      end
    end
  end
end
```

- [ ] **Step 2: テストが落ちるのを確認**

Run: `bundle exec rspec spec/models/attendance_period_spec.rb -e "containing"`
Expected: FAIL（`NoMethodError: undefined method 'containing'`）

- [ ] **Step 3: 最小実装**

`app/models/attendance_period.rb` の `def initialize` の直前（`attr_reader :year_month` より前でも可・class メソッドゆえ先頭付近）に追加:

```ruby
  # date を含む締め期間を返す（逆写像・3-2 設計 §2.1・D4）。
  # 候補＝date の暦月期。range.cover? なら当期、外れたら翌期（下限は月初を必ず含むので .prev 不要）。
  def self.containing(organization:, date:)
    candidate = new(organization:, year_month: date.strftime("%Y-%m"))
    candidate.range.cover?(date) ? candidate : candidate.next
  end
```

- [ ] **Step 4: テストが通るのを確認**

Run: `bundle exec rspec spec/models/attendance_period_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/models/attendance_period.rb
git add app/models/attendance_period.rb spec/models/attendance_period_spec.rb
git commit -m "feat(3-2): AttendancePeriod.containing（date→締め期間の逆写像）"
```

---

## Task 4: MonthlySummaries::ClosingLock（締めロック述語）

**Files:**
- Create: `app/services/monthly_summaries/closing_lock.rb`
- Test: `spec/services/monthly_summaries/closing_lock_spec.rb`

**Interfaces:**
- Consumes: `AttendancePeriod.containing(organization:, date:)` / `#label` / `#next`、`MonthlyAttendanceSummary`（status enum）
- Produces: `MonthlySummaries::ClosingLock.locked?(user:, dates:)` → Boolean（dates: Date / Range<Date> / Array<Date>）

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "rails_helper"

RSpec.describe MonthlySummaries::ClosingLock, type: :model do
  # model spec ゆえ test_tenant 自動。closing_day はデフォルト 31。
  let(:user) { create(:user) }
  let(:march) { Date.new(2026, 3, 10) }

  def summary_for(label, status)
    create(:monthly_attendance_summary, user:, year_month: label, status:)
  end

  describe ".locked?" do
    it "summary 行が無ければ unlocked（締めていない＝締まっていない）" do
      expect(described_class.locked?(user:, dates: march)).to be(false)
    end

    it "submitted は locked" do
      summary_for("2026-03", :submitted)
      expect(described_class.locked?(user:, dates: march)).to be(true)
    end

    it "finalized は locked" do
      summary_for("2026-03", :finalized)
      expect(described_class.locked?(user:, dates: march)).to be(true)
    end

    it "deferred は unlocked" do
      summary_for("2026-03", :deferred)
      expect(described_class.locked?(user:, dates: march)).to be(false)
    end

    it "aggregating は unlocked" do
      summary_for("2026-03", :aggregating)
      expect(described_class.locked?(user:, dates: march)).to be(false)
    end

    it "別 user の submitted は引かない" do
      other = create(:user)
      create(:monthly_attendance_summary, user: other, year_month: "2026-03", status: :submitted)
      expect(described_class.locked?(user:, dates: march)).to be(false)
    end

    it "Range で複数期に跨り 1 期だけ locked なら true" do
      summary_for("2026-04", :submitted) # 4 月だけ締め
      range = Date.new(2026, 3, 25)..Date.new(2026, 4, 5)
      expect(described_class.locked?(user:, dates: range)).to be(true)
    end

    it "Range で全期 unlocked なら false" do
      range = Date.new(2026, 3, 25)..Date.new(2026, 4, 5)
      expect(described_class.locked?(user:, dates: range)).to be(false)
    end

    it "Array でも判定できる" do
      summary_for("2026-03", :submitted)
      expect(described_class.locked?(user:, dates: [Date.new(2026, 3, 1), Date.new(2026, 3, 31)])).to be(true)
    end

    it "他テナントの summary を引かない（with_tenant スコープ）" do
      # user は test_tenant 所属。別 org に同 user は作れないため、別 org の別 user で submitted を作っても
      # locked? は user の org スコープで引くため false（クロステナント遮断の実証）
      other_org = create(:organization)
      ActsAsTenant.with_tenant(other_org) do
        ou = create(:user)
        create(:monthly_attendance_summary, user: ou, year_month: "2026-03", status: :submitted)
      end
      expect(described_class.locked?(user:, dates: march)).to be(false)
    end
  end
end
```

- [ ] **Step 2: テストが落ちるのを確認**

Run: `bundle exec rspec spec/services/monthly_summaries/closing_lock_spec.rb`
Expected: FAIL（`uninitialized constant MonthlySummaries::ClosingLock`）

- [ ] **Step 3: 最小実装**

```ruby
# frozen_string_literal: true

module MonthlySummaries
  # 締めロック述語（query object・3-2 設計 §2.1・D4）。
  # (user, dates) の各日が属する締め期間の status が submitted/finalized なら locked。
  # 行なし＝aggregating＝unlocked（締めていないものは締まっていない＝この向きは fail-open が正）。
  class ClosingLock
    LOCKED = %w[submitted finalized].freeze

    def self.locked?(user:, dates:) = new(user:, dates:).locked?

    def initialize(user:, dates:)
      @user = user
      @dates = dates
    end

    def locked?
      ActsAsTenant.with_tenant(@user.organization) do
        MonthlyAttendanceSummary
          .where(user: @user, year_month: period_labels, status: LOCKED)
          .exists?
      end
    end

    private

    # containing(min)..containing(max) を walk して distinct labels（3-2 設計 §2.1）。
    def period_labels
      ds = Array(@dates).flatten
      org = @user.organization
      first = AttendancePeriod.containing(organization: org, date: ds.min)
      last  = AttendancePeriod.containing(organization: org, date: ds.max)
      labels = []
      period = first
      loop do
        labels << period.label
        break if period.label == last.label

        period = period.next
      end
      labels
    end
  end
end
```

> 注（spec §2.1）: `with_tenant(@user.organization)` はデータ由来 org を信頼する＝`@user` が同一テナント FK 不変条件（§3.6）を満たす前提。`Array(range)` は Range を全 Date 展開するが `.min`/`.max` の両端のみ使う（範囲最大 366 日でも実害なし・素直さ優先で現状維持）。

- [ ] **Step 4: テストが通るのを確認**

Run: `bundle exec rspec spec/services/monthly_summaries/closing_lock_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/services/monthly_summaries/closing_lock.rb
git add app/services/monthly_summaries/closing_lock.rb spec/services/monthly_summaries/closing_lock_spec.rb
git commit -m "feat(3-2): MonthlySummaries::ClosingLock（締めロック述語）"
```

---

## Task 5: ClosingRestricted concern + Approvable 既定 + 3 申請モデルへ適用

**Files:**
- Create: `app/models/concerns/closing_restricted.rb`
- Modify: `app/models/concerns/approvable.rb`（`closing_locked? = false` 既定追加）
- Modify: `app/models/leave_request.rb` / `app/models/clock_change_request.rb` / `app/models/holiday_work_request.rb`（include + `closing_target_dates`）
- Test: `spec/models/leave_request_spec.rb` / `clock_change_request_spec.rb` / `holiday_work_request_spec.rb`（締め制限 describe を各々に追記）

**Interfaces:**
- Consumes: `MonthlySummaries::ClosingLock.locked?(user:, dates:)`、`requester`（3 型共通）
- Produces: `ClosingRestricted#closing_locked?` / `#closing_unlocked?` / `#closing_target_dates`（host が実装）、`Approvable#closing_locked? = false`（既定）、各申請モデルの `validate :target_dates_not_in_closed_period, on: :create`

- [ ] **Step 1: Approvable に既定 closing_locked? を追加（失敗テスト不要・既定 no-op）**

`app/models/concerns/approvable.rb` の `def apply_withdrawal_effects!(acting_user:) = nil` の直後に追加:

```ruby
  # 締め再チェック hook（既定 false＝テスト専用 approvable / 非日付 host は安全 no-op）。
  # ClosingRestricted を include する host（LR/CCR/HWR）が override（3-2 設計 §2.4・D3）。
  def closing_locked? = false
```

- [ ] **Step 2: ClosingRestricted concern を書く**

```ruby
# frozen_string_literal: true

# 締めステータスによる申請制限（SPEC §6.7・3-2 設計 §2.2）。
# host（LR/CCR/HWR）に include する。**Approvable/Withdrawable より後に include すること**
# （ancestor 順で本 concern の closing_locked? が Approvable 既定 false に勝つ・withdrawable.rb の評価順注記と同型）。
module ClosingRestricted
  extend ActiveSupport::Concern

  included do
    validate :target_dates_not_in_closed_period, on: :create
  end

  # host が実装する締め判定の対象日（複数可）。
  # LR: start_date..end_date / CCR: [attendance_record&.work_date].compact / HWR: [work_date]
  def closing_target_dates = raise NotImplementedError, "#{self.class} must implement #closing_target_dates"

  # 承認時の締め再チェック（§2.4）。Approvable 既定 false を上書き。
  # 注: 名称は apply_*_effects! との対称性を優先し closing_locked? を維持（3-2 設計 §2.4）。
  def closing_locked?
    dates = closing_target_dates
    dates.present? && MonthlySummaries::ClosingLock.locked?(user: requester, dates:)
  end

  def closing_unlocked? = !closing_locked?

  private

  def target_dates_not_in_closed_period
    return unless closing_locked?

    errors.add(:base, "締め済みの月（提出済 / 確定）の日付は申請できません")
  end
end
```

- [ ] **Step 3: 3 申請モデルへ include + closing_target_dates（失敗テストを各 spec に書く）**

`spec/models/leave_request_spec.rb` に追記:

```ruby
  describe "締めステータスによる作成制限（§6.7・3-2）" do
    let(:requester) { create(:user) }

    it "対象日が submitted 月なら作成 invalid" do
      create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :submitted)
      lr = build(:leave_request, requester:, start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(lr).not_to be_valid
      expect(lr.errors[:base]).to include(a_string_including("締め済み"))
    end

    it "対象日が aggregating 月なら作成 valid" do
      lr = build(:leave_request, requester:, start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1), days_requested: 1)
      expect(lr).to be_valid
    end

    it "月跨ぎで一部が締め済みなら all-or-nothing で弾く" do
      create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :finalized)
      lr = build(:leave_request, requester:, start_date: Date.new(2026, 4, 28), end_date: Date.new(2026, 5, 2), days_requested: 5)
      expect(lr).not_to be_valid
    end
  end
```

`spec/models/clock_change_request_spec.rb` に追記:

```ruby
  describe "締めステータスによる作成制限（§6.7・3-2）" do
    let(:requester) { create(:user) }

    it "対象 AR の work_date が submitted 月なら invalid" do
      ar = create(:attendance_record, :done, user: requester, work_date: Date.new(2026, 5, 1))
      create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :submitted)
      ccr = build(:clock_change_request, requester:, attendance_record: ar)
      expect(ccr).not_to be_valid
      expect(ccr.errors[:base]).to include(a_string_including("締め済み"))
    end

    it "attendance_record 不在なら closing_target_dates 空 → 締め制限を通す（偽陽性ロック防止）" do
      ccr = build(:clock_change_request, requester:, attendance_record: nil)
      # 他検証で invalid になるが base の締めエラーは出ない
      ccr.valid?
      expect(ccr.errors[:base]).not_to include(a_string_including("締め済み"))
    end
  end
```

`spec/models/holiday_work_request_spec.rb` に追記:

```ruby
  describe "締めステータスによる作成制限（§6.7・3-2）" do
    let(:requester) { create(:user) }

    it "work_date が submitted 月なら invalid" do
      create(:monthly_attendance_summary, user: requester, year_month: "2026-06", status: :submitted)
      hwr = build(:holiday_work_request, requester:, work_date: Date.new(2026, 6, 7))
      expect(hwr).not_to be_valid
      expect(hwr.errors[:base]).to include(a_string_including("締め済み"))
    end
  end
```

- [ ] **Step 4: テストが落ちるのを確認**

Run: `bundle exec rspec spec/models/leave_request_spec.rb spec/models/clock_change_request_spec.rb spec/models/holiday_work_request_spec.rb -e "締めステータス"`
Expected: FAIL（include 未追加・NotImplementedError 等）

- [ ] **Step 5: 3 モデルへ実装**

`app/models/leave_request.rb` の `include Withdrawable` の**次の行**に追加:

```ruby
  include ClosingRestricted # §6.7 締め制限（Withdrawable より後＝ancestor 順で closing_locked? が勝つ）
```

`leave_request.rb` の `private` 直後（または public メソッド領域）に:

```ruby
  # 締め判定の対象日（§6.7・3-2）。start_date..end_date の全日。
  def closing_target_dates = (start_date && end_date) ? (start_date..end_date) : []
```

`app/models/clock_change_request.rb` の `include Withdrawable` の次の行に:

```ruby
  include ClosingRestricted # §6.7 締め制限
```

`clock_change_request.rb` に（public 領域）:

```ruby
  # 締め判定の対象日（§6.7・3-2）。対象 AR の work_date。AR 不在なら空（偽陽性ロック防止・設計 §2.2）。
  def closing_target_dates = [ attendance_record&.work_date ].compact
```

`app/models/holiday_work_request.rb` の `include Approvable` の次の行に:

```ruby
  include ClosingRestricted # §6.7 締め制限（Approvable より後）
```

`holiday_work_request.rb` に（public 領域）:

```ruby
  # 締め判定の対象日（§6.7・3-2）。
  def closing_target_dates = [ work_date ].compact
```

- [ ] **Step 6: テストが通るのを確認**

Run: `bundle exec rspec spec/models/leave_request_spec.rb spec/models/clock_change_request_spec.rb spec/models/holiday_work_request_spec.rb`
Expected: PASS（締め制限 + 既存全 example）

- [ ] **Step 7: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/models/concerns/closing_restricted.rb app/models/concerns/approvable.rb app/models/leave_request.rb app/models/clock_change_request.rb app/models/holiday_work_request.rb
git add app/models/concerns/closing_restricted.rb app/models/concerns/approvable.rb app/models/leave_request.rb app/models/clock_change_request.rb app/models/holiday_work_request.rb spec/models/leave_request_spec.rb spec/models/clock_change_request_spec.rb spec/models/holiday_work_request_spec.rb
git commit -m "feat(3-2): ClosingRestricted concern で申請の新規作成を締め月で制限（§6.7）"
```

---

## Task 6: Withdrawable に撤回の締め制限 guard を追加

**Files:**
- Modify: `app/models/concerns/withdrawable.rb`
- Test: `spec/models/concerns/withdrawable_spec.rb`（または LR/CCR の spec）

**Interfaces:**
- Consumes: `ClosingRestricted#closing_unlocked?`（LR/CCR は ClosingRestricted も include 済）
- Produces: `request_withdrawal` event に guard `closing_unlocked?` 追加（locked なら `InvalidTransition`）

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/concerns/withdrawable_spec.rb` に追記（既存 spec の文脈に合わせる・LeaveRequest を host として使う例）:

```ruby
  describe "撤回の締め制限（§6.7・§7.6 L910・3-2）" do
    let(:requester) { create(:user) }

    def approved_lr(start_date:)
      lr = create(:leave_request, requester:, start_date:, end_date: start_date, days_requested: 1)
      lr.update!(status: :approved) # AASM 直叩きでなく status 直接（撤回 guard のみ検証する単体）
      lr
    end

    it "対象日が submitted 月なら request_withdrawal! は InvalidTransition" do
      lr = approved_lr(start_date: Date.new(2026, 5, 1))
      create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :submitted)
      lr.withdrawal_reason = "撤回したい"
      expect { lr.request_withdrawal! }.to raise_error(AASM::InvalidTransition)
    end

    it "対象日が unlocked 月なら request_withdrawal! は成功" do
      lr = approved_lr(start_date: Date.new(2026, 5, 1))
      lr.withdrawal_reason = "撤回したい"
      expect { lr.request_withdrawal! }.not_to raise_error
      expect(lr).to be_withdrawal_requested
    end

    it "撤回世代が無くても closing-lock 単独で弾ける（新 guard 効果の隔離）" do
      lr = approved_lr(start_date: Date.new(2026, 5, 1))
      create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :finalized)
      lr.withdrawal_reason = "x"
      # no_prior_withdrawal_round? は true（撤回 assignment 皆無）。closing_unlocked? が false で弾く
      expect { lr.request_withdrawal! }.to raise_error(AASM::InvalidTransition)
    end
  end
```

> 注: テスト内 `update!(status: :approved)` は AASM 機械の approved 状態を直接置くショートカット（承認エンジン全体を経由せず撤回 guard のみ単体検証する意図）。`days_requested` は factory default。締め月の summary は requester の所属で作る。

- [ ] **Step 2: テストが落ちるのを確認**

Run: `bundle exec rspec spec/models/concerns/withdrawable_spec.rb -e "撤回の締め制限"`
Expected: FAIL（締め済みでも request_withdrawal! が成功してしまう）

- [ ] **Step 3: 最小実装**

`app/models/concerns/withdrawable.rb` の `request_withdrawal` event の guard に `closing_unlocked?` を追加:

```ruby
      event :request_withdrawal do
        transitions from: :approved, to: :withdrawal_requested,
                    guard: %i[no_prior_withdrawal_round? closing_unlocked?] # §6.7 締め制限（3-2）
      end
```

- [ ] **Step 4: テストが通るのを確認**

Run: `bundle exec rspec spec/models/concerns/withdrawable_spec.rb`
Expected: PASS（既存 + 締め制限）

- [ ] **Step 5: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/models/concerns/withdrawable.rb
git add app/models/concerns/withdrawable.rb spec/models/concerns/withdrawable_spec.rb
git commit -m "feat(3-2): 撤回申請を締め月で制限（Withdrawable guard・§6.7）"
```

---

## Task 7: 承認時の締め再チェックを Approve#guard! へ注入（Approach A）

**Files:**
- Modify: `app/services/approvals.rb`（`ClosingLockedError < ConflictError` 追加）
- Modify: `app/services/approvals/approve.rb`（`guard!` に 1 行）
- Test: `spec/services/approvals/approve_spec.rb`

**Interfaces:**
- Consumes: `@approvable.closing_locked?`（全 host が応答・既定 false / LR/CCR/HWR は override）
- Produces: `Approvals::ClosingLockedError`（`ConflictError` のサブクラス・既存 rescue は親で拾う）、`Approve#guard!` が locked で raise

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/approvals/approve_spec.rb` に追記。3 型それぞれで「作成→締め→approve が締め由来エラー」を検証する。ここでは LR を代表に + closing_locked? の no-op 回帰:

```ruby
  describe "締め再チェック（§6.6・Approach A・3-2）" do
    let(:requester) { create(:user, :with_manager) } # 承認ルート解決可能な factory trait（無ければ manager 設定）
    let(:approver) { requester.manager }

    it "approve 直前に対象月が submitted なら ClosingLockedError（ConflictError サブクラス）" do
      lr = LeaveRequests::Create.call(
        requester:, leave_type: create(:leave_type),
        start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1),
        half_day_type: :none, reason: "x"
      )
      create(:monthly_attendance_summary, user: requester, year_month: "2026-05", status: :submitted)
      expect {
        Approvals::Approve.call(approvable: lr, approver:)
      }.to raise_error(Approvals::ClosingLockedError)
      expect(Approvals::ClosingLockedError.ancestors).to include(Approvals::ConflictError)
    end

    it "unlocked なら approve は正常進行（guard が常時 raise でない）" do
      lr = LeaveRequests::Create.call(
        requester:, leave_type: create(:leave_type),
        start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1),
        half_day_type: :none, reason: "x"
      )
      expect { Approvals::Approve.call(approvable: lr, approver:) }.not_to raise_error
    end

    it "非日付 host（closing_locked? 既定 false）は approve に影響しない（no-op 回帰）" do
      # 既存のテスト専用 approvable（ApprovalTestRecord 等）を使う既存 example が
      # 締め注入後も緑であることを確認（このブロックは既存 approve_spec の通過で代替可）
      expect(Approvable.instance_method(:closing_locked?)).to be_present
    end
  end
```

> 注: `requester`/`approver` の作り方は既存 `approve_spec.rb` のセットアップに合わせる（manager を持つ user・承認ルートが解決できる状態）。`:with_manager` trait が無ければ `create(:user)` + `requester.update!(manager: create(:user, :manager_role))` 等で代替。CCR/HWR 版の example も同型で追加（attendance_record / work_date を締め月に置く）。

- [ ] **Step 2: テストが落ちるのを確認**

Run: `bundle exec rspec spec/services/approvals/approve_spec.rb -e "締め再チェック"`
Expected: FAIL（`uninitialized constant Approvals::ClosingLockedError` / approve が通ってしまう）

- [ ] **Step 3: ClosingLockedError を定義**

`app/services/approvals.rb` の `class ConflictError < Error; end` の直後に:

```ruby
  class ClosingLockedError < ConflictError; end # 締め済み月への承認（§6.6・3-2）。既存 rescue ConflictError が親で拾う
```

- [ ] **Step 4: Approve#guard! へ注入**

`app/services/approvals/approve.rb` の `guard!` メソッド冒頭（`raise AASM::InvalidTransition ...` の**前**）に:

```ruby
      raise ClosingLockedError if @approvable.closing_locked? # 締め再チェック（§6.6・3-2・入口で fail-closed）
```

- [ ] **Step 5: テストが通るのを確認**

Run: `bundle exec rspec spec/services/approvals/approve_spec.rb`
Expected: PASS（既存 + 締め再チェック）

- [ ] **Step 6: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/services/approvals.rb app/services/approvals/approve.rb
git add app/services/approvals.rb app/services/approvals/approve.rb spec/services/approvals/approve_spec.rb
git commit -m "feat(3-2): 承認時の締め再チェックを Approve#guard! へ注入（Approach A・§6.6）"
```

---

## Task 8: ガード spec（Approvable include 型は ClosingRestricted も include）

**Files:**
- Create: `spec/models/concerns/closing_restricted_coverage_spec.rb`

**Interfaces:**
- Consumes: `Approvable`, `ClosingRestricted`（eager_load 後の本番 app/models 列挙）

- [ ] **Step 1: ガード spec を書く（これ自体が検証なので最初から緑を狙う）**

```ruby
# frozen_string_literal: true

require "rails_helper"

# silent-gap 塞ぎ（3-2 設計 §2.4・D3）。
# Approvable を include する本番モデルは ClosingRestricted も include し、
# closing_locked? の実体が ClosingRestricted 由来であることを機械検証する。
RSpec.describe "ClosingRestricted coverage", type: :model do
  before { Rails.application.eager_load! }

  # テスト専用 approvable（spec/support 配下）は対象外。本番 app/models のみ。
  def production_approvables
    ApplicationRecord.descendants.select do |klass|
      klass.include?(Approvable) && klass.name.present? &&
        klass.instance_methods(false) || klass.ancestors.include?(Approvable)
    end.select { |k| k.include?(Approvable) && !k.name.start_with?("Approval") }
  end

  it "本番の Approvable host は空でない（列挙ロジックの偽 green 防止）" do
    hosts = ApplicationRecord.descendants.select { |k| k.include?(Approvable) }
    expect(hosts).to include(LeaveRequest, ClockChangeRequest, HolidayWorkRequest)
  end

  it "全 Approvable host が ClosingRestricted を include する" do
    hosts = [LeaveRequest, ClockChangeRequest, HolidayWorkRequest]
    hosts.each do |klass|
      expect(klass.include?(ClosingRestricted)).to be(true), "#{klass} must include ClosingRestricted"
    end
  end

  it "closing_locked? の実体が ClosingRestricted 由来（Approvable 既定 false に勝つ）" do
    [LeaveRequest, ClockChangeRequest, HolidayWorkRequest].each do |klass|
      owner = klass.instance_method(:closing_locked?).owner
      expect(owner).to eq(ClosingRestricted), "#{klass}#closing_locked? は #{owner} 由来（ClosingRestricted であるべき）"
    end
  end

  it "各 host の closing_target_dates が呼べる（NotImplementedError でない）" do
    requester = create(:user)
    lr = build(:leave_request, requester:, start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 3))
    expect(lr.closing_target_dates.to_a).to eq([Date.new(2026, 5, 1), Date.new(2026, 5, 2), Date.new(2026, 5, 3)])

    hwr = build(:holiday_work_request, requester:, work_date: Date.new(2026, 6, 7))
    expect(hwr.closing_target_dates).to eq([Date.new(2026, 6, 7)])
  end
end
```

> 実装注: `production_approvables` の素朴版で十分。要件は「LeaveRequest/ClockChangeRequest/HolidayWorkRequest が ClosingRestricted を include し closing_locked? が ClosingRestricted 由来」を assert すること。テスト専用 approvable（`ApprovalTestRecord` 等・ApplicationRecord 非継承の PORO double の場合は descendants に出ない）は自然に除外される。複雑な動的列挙が不安定なら明示 3 型の allowlist で固定してよい（上記 it 群は明示 3 型で書いてある）。

- [ ] **Step 2: テストが通るのを確認**

Run: `bundle exec rspec spec/models/concerns/closing_restricted_coverage_spec.rb`
Expected: PASS（Task 5 で 3 型に include 済ゆえ緑）

- [ ] **Step 3: わざと壊して実効性を確認（任意・赤を見る）**

`leave_request.rb` の `include ClosingRestricted` を一時コメントアウト → 上記 spec が FAIL することを目視 → 戻す。

- [ ] **Step 4: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion spec/models/concerns/closing_restricted_coverage_spec.rb
git add spec/models/concerns/closing_restricted_coverage_spec.rb
git commit -m "test(3-2): ClosingRestricted カバレッジのガード spec（silent-gap 塞ぎ）"
```

---

## Task 9: MonthlySummaries::PendingRequests（提出前チェック）

**Files:**
- Create: `app/services/monthly_summaries/pending_requests.rb`
- Test: `spec/services/monthly_summaries/pending_requests_spec.rb`

**Interfaces:**
- Consumes: `AttendancePeriod#range`、LR/CCR/HWR（status enum・approval_assignments）
- Produces: `MonthlySummaries::PendingRequests.new(user:, period:)` → `#any?`(Boolean・Submit ゲート用) / `#started`(Array・承認進行中) / `#not_started`(Array・未起動)

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "rails_helper"

RSpec.describe MonthlySummaries::PendingRequests, type: :model do
  let(:user) { create(:user) }
  let(:period) { AttendancePeriod.new(organization: user.organization, year_month: "2026-05") }

  def in_period_lr(status: :applying)
    create(:leave_request, requester: user, start_date: Date.new(2026, 5, 10),
           end_date: Date.new(2026, 5, 10), days_requested: 1).tap { |lr| lr.update!(status:) }
  end

  describe "#any?" do
    it "in-flight 申請が無ければ false" do
      expect(described_class.new(user:, period:).any?).to be(false)
    end

    it "applying の LR が期間内にあれば true" do
      in_period_lr
      expect(described_class.new(user:, period:).any?).to be(true)
    end

    it "approved/canceled/withdrawn は in-flight でない（誤検出しない）" do
      in_period_lr(status: :approved)
      expect(described_class.new(user:, period:).any?).to be(false)
    end

    it "期間外の applying は拾わない" do
      create(:leave_request, requester: user, start_date: Date.new(2026, 7, 1),
             end_date: Date.new(2026, 7, 1), days_requested: 1)
      expect(described_class.new(user:, period:).any?).to be(false)
    end
  end

  describe "#started / #not_started" do
    it "acted assignment があれば started" do
      lr = in_period_lr
      # 承認進行中 = active purpose に pending でない assignment が 1 件以上
      create(:approval_assignment, approvable: lr, position: 1, decision: :approved, approver: create(:user))
      pr = described_class.new(user:, period:)
      expect(pr.started).to include(lr)
      expect(pr.not_started).not_to include(lr)
    end

    it "全 assignment が pending なら not_started" do
      lr = in_period_lr
      create(:approval_assignment, approvable: lr, position: 1, decision: :pending, approver: create(:user))
      pr = described_class.new(user:, period:)
      expect(pr.not_started).to include(lr)
      expect(pr.started).not_to include(lr)
    end
  end
end
```

> 注: `:approval_assignment` factory・`purpose`/`position`/`decision` のデフォルトは既存 factory を確認して合わせる（無ければ `spec/factories/approval_assignments.rb` の有無を確認。purpose は `:approval`）。

- [ ] **Step 2: テストが落ちるのを確認**

Run: `bundle exec rspec spec/services/monthly_summaries/pending_requests_spec.rb`
Expected: FAIL（`uninitialized constant`）

- [ ] **Step 3: 最小実装**

```ruby
# frozen_string_literal: true

module MonthlySummaries
  # 提出前チェック（SPEC §6.6・3-2 設計 §3.1・D6）。
  # (user, period) の期間に重なる in-flight 申請（LR/CCR/HWR）を横断収集し、
  # 承認進行中（started）/ 未起動（not_started）に二分する。
  # Submit のゲートは any?（boolean）で足り、二分は UI 表示専用（N+1 回避）。
  class PendingRequests
    IN_FLIGHT = %w[applying withdrawal_requested].freeze

    def initialize(user:, period:)
      @user = user
      @period = period
    end

    def any? = in_flight_records.any?

    # 承認進行中 = active purpose に pending でない assignment が存在
    def started = @started ||= in_flight_records.select { |r| acted?(r) }

    def not_started = @not_started ||= in_flight_records.reject { |r| acted?(r) }

    private

    def range = @period.range

    def in_flight_records
      @in_flight_records ||= leave_requests + clock_change_requests + holiday_work_requests
    end

    def leave_requests
      LeaveRequest.where(requester: @user, approval_status: IN_FLIGHT)
                  .where("start_date <= ? AND end_date >= ?", range.last, range.first).to_a
    end

    def clock_change_requests
      ClockChangeRequest.where(requester: @user, approval_status: IN_FLIGHT)
                        .joins(:attendance_record)
                        .where(attendance_records: { work_date: range }).to_a
    end

    def holiday_work_requests
      # HWR は Approvable のみ（withdrawal_requested 状態なし）。applying のみが in-flight
      HolidayWorkRequest.where(requester: @user, approval_status: :applying)
                        .where(work_date: range).to_a
    end

    # active purpose に decision != pending の assignment が 1 件でもあれば「起動済み」
    def acted?(record)
      record.approval_assignments
            .where(purpose: record.active_purpose)
            .where.not(decision: :pending).exists?
    end
  end
end
```

> N+1 注（spec §3.1）: `acted?` は record ごとに 1 クエリ。in-flight 件数は §16.1 規模で小（1 社員 1 締め期間）ゆえ許容。さらなる最適化（`where(approvable: records)` の一括ロード）は計測後。

- [ ] **Step 4: テストが通るのを確認**

Run: `bundle exec rspec spec/services/monthly_summaries/pending_requests_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/services/monthly_summaries/pending_requests.rb
git add app/services/monthly_summaries/pending_requests.rb spec/services/monthly_summaries/pending_requests_spec.rb
git commit -m "feat(3-2): MonthlySummaries::PendingRequests（提出前チェック・起動済/未起動 二分）"
```

---

## Task 10: Finalize / Defer サービス

**Files:**
- Create: `app/services/monthly_summaries/finalize.rb`
- Create: `app/services/monthly_summaries/defer.rb`
- Test: `spec/services/monthly_summaries/finalize_spec.rb` / `defer_spec.rb`

**Interfaces:**
- Consumes: `MonthlyAttendanceSummary#finalize!` / `#defer!`
- Produces: `MonthlySummaries::Finalize.call(summary:)` → summary / `MonthlySummaries::Defer.call(summary:, reason:)` → summary

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/monthly_summaries/finalize_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe MonthlySummaries::Finalize, type: :model do
  let(:summary) { create(:monthly_attendance_summary, status: :submitted) }

  it "submitted を finalized にする" do
    described_class.call(summary:)
    expect(summary.reload).to be_finalized
  end

  it "submitted 以外は InvalidTransition" do
    summary.update!(status: :aggregating)
    expect { described_class.call(summary:) }.to raise_error(AASM::InvalidTransition)
  end

  it "D7: Aggregate を呼ばない（確定値が確定後に動かない）" do
    expect(MonthlySummaries::Aggregate).not_to receive(:call)
    described_class.call(summary:)
  end
end
```

`spec/services/monthly_summaries/defer_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe MonthlySummaries::Defer, type: :model do
  let(:summary) { create(:monthly_attendance_summary, status: :submitted) }

  it "submitted を deferred にし reason を保存する" do
    described_class.call(summary:, reason: "打刻漏れあり")
    summary.reload
    expect(summary).to be_deferred
    expect(summary.deferral_reason).to eq("打刻漏れあり")
  end

  it "reason 空なら RecordInvalid（deferral_reason 必須）" do
    expect { described_class.call(summary:, reason: "") }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "finalized からも deferred にできる" do
    summary.update!(status: :finalized)
    described_class.call(summary:, reason: "確定後修正")
    expect(summary.reload).to be_deferred
  end

  it "D7: Aggregate を呼ばない" do
    expect(MonthlySummaries::Aggregate).not_to receive(:call)
    described_class.call(summary:, reason: "x")
  end
end
```

- [ ] **Step 2: テストが落ちるのを確認**

Run: `bundle exec rspec spec/services/monthly_summaries/finalize_spec.rb spec/services/monthly_summaries/defer_spec.rb`
Expected: FAIL（`uninitialized constant`）

- [ ] **Step 3: 実装**

`app/services/monthly_summaries/finalize.rb`:

```ruby
# frozen_string_literal: true

module MonthlySummaries
  # 締め確定（SPEC §6.6・3-2 設計 §1.3）。submitted → finalized。
  # 確定の唯一経路（単一・一括 BulkFinalizeJob の両方がここを通る・divergence 防止）。
  # D7: Aggregate を呼ばない（確定値は確定後に動かさない）。
  class Finalize
    def self.call(summary:) = new(summary:).call

    def initialize(summary:)
      @summary = summary
    end

    def call
      @summary.with_lock { @summary.finalize! }
      @summary
    end
  end
end
```

`app/services/monthly_summaries/defer.rb`:

```ruby
# frozen_string_literal: true

module MonthlySummaries
  # 締め差戻し（SPEC §6.6・3-2 設計 §1.3）。submitted/finalized → deferred。
  # deferral_reason 必須（whiny_persistence で空は RecordInvalid）。通知は 4-1（in-app バナーのみ）。
  class Defer
    def self.call(summary:, reason:) = new(summary:, reason:).call

    def initialize(summary:, reason:)
      @summary = summary
      @reason = reason
    end

    def call
      @summary.with_lock do
        @summary.deferral_reason = @reason
        @summary.defer!
      end
      @summary
    end
  end
end
```

- [ ] **Step 4: テストが通るのを確認**

Run: `bundle exec rspec spec/services/monthly_summaries/finalize_spec.rb spec/services/monthly_summaries/defer_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/services/monthly_summaries/finalize.rb app/services/monthly_summaries/defer.rb
git add app/services/monthly_summaries/finalize.rb app/services/monthly_summaries/defer.rb spec/services/monthly_summaries/finalize_spec.rb spec/services/monthly_summaries/defer_spec.rb
git commit -m "feat(3-2): MonthlySummaries::Finalize / Defer サービス"
```

---

## Task 11: Submit サービス（提出前チェック→集計→遷移）

**Files:**
- Create: `app/services/monthly_summaries/submit.rb`
- Test: `spec/services/monthly_summaries/submit_spec.rb`

**Interfaces:**
- Consumes: `MonthlySummaries::PendingRequests.new(user:, period:).any?`、`MonthlySummaries::Aggregate.call(user:, period:)`、`MonthlyAttendanceSummary#submit!`、`Approvals::ConflictError`
- Produces: `MonthlySummaries::Submit.call(user:, period:)` → summary（submitted）

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "rails_helper"

RSpec.describe MonthlySummaries::Submit, type: :model do
  let(:user) { create(:user) }
  let(:period) { AttendancePeriod.new(organization: user.organization, year_month: "2026-05") }

  it "summary 行が無くても初回提出で lazy 生成し submitted にする" do
    summary = described_class.call(user:, period:)
    expect(summary).to be_persisted
    expect(summary).to be_submitted
    expect(summary.year_month).to eq("2026-05")
  end

  it "deferred からの再提出も submitted にする" do
    create(:monthly_attendance_summary, user:, year_month: "2026-05", status: :deferred, deferral_reason: "x")
    summary = described_class.call(user:, period:)
    expect(summary).to be_submitted
  end

  it "in-flight 申請があれば ConflictError（fail-closed）" do
    create(:leave_request, requester: user, start_date: Date.new(2026, 5, 10),
           end_date: Date.new(2026, 5, 10), days_requested: 1) # applying
    expect { described_class.call(user:, period:) }.to raise_error(Approvals::ConflictError)
  end

  it "in-flight 検出時は Aggregate を呼ばない（再集計前に fail-closed）" do
    create(:leave_request, requester: user, start_date: Date.new(2026, 5, 10),
           end_date: Date.new(2026, 5, 10), days_requested: 1)
    expect(MonthlySummaries::Aggregate).not_to receive(:call)
    expect { described_class.call(user:, period:) }.to raise_error(Approvals::ConflictError)
  end

  it "Aggregate を 1 回呼び、その返り値に submit! する（順序・同一インスタンス）" do
    summary = create(:monthly_attendance_summary, user:, year_month: "2026-05")
    expect(MonthlySummaries::Aggregate).to receive(:call).with(user:, period:).once.and_return(summary)
    result = described_class.call(user:, period:)
    expect(result).to eq(summary)
    expect(result).to be_submitted
  end
end
```

- [ ] **Step 2: テストが落ちるのを確認**

Run: `bundle exec rspec spec/services/monthly_summaries/submit_spec.rb`
Expected: FAIL（`uninitialized constant`）

- [ ] **Step 3: 実装**

```ruby
# frozen_string_literal: true

module MonthlySummaries
  # 締め提出 / 再提出（SPEC §6.6・3-2 設計 §1.3・D2/D6/D7）。
  # ① 提出前チェック（in-flight 申請があれば ConflictError・再集計の前に fail-closed）
  # ② Aggregate.call（全件再集計・status 非干渉の純関数）→ ③ submit!（同一インスタンス・順序固定）。
  # 副作用→遷移の順は §13.6 の唯一の例外（D7: locked 行は再集計しない＝集計は unlocked のうちに）。
  class Submit
    def self.call(user:, period:) = new(user:, period:).call

    def initialize(user:, period:)
      @user = user
      @period = period
    end

    def call
      ActiveRecord::Base.transaction do
        raise Approvals::ConflictError if PendingRequests.new(user: @user, period: @period).any?

        summary = Aggregate.call(user: @user, period: @period)
        summary.submit!
        summary
      end
    end
  end
end
```

- [ ] **Step 4: テストが通るのを確認**

Run: `bundle exec rspec spec/services/monthly_summaries/submit_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/services/monthly_summaries/submit.rb
git add app/services/monthly_summaries/submit.rb spec/services/monthly_summaries/submit_spec.rb
git commit -m "feat(3-2): MonthlySummaries::Submit（提出前チェック→再集計→提出）"
```

---

## Task 12: MonthlyAttendanceSummaryPolicy + Scope

**Files:**
- Create: `app/policies/monthly_attendance_summary_policy.rb`
- Test: `spec/policies/monthly_attendance_summary_policy_spec.rb`

**設計判断（plan 確定）:** SPEC §4.1 の「階層述語（例 subordinate_of?）」は `subordinate_of?` が**未実装**ゆえ、precedent（`ProxyClockingPolicy` = 直属 manager）に倣い **直属 manager + hr_admin** で action 述語と Scope を一致させる。多段 `subordinate_of?` は Phase 5 ダッシュボードが必要とするまで YAGNI（本判断を policy にコメント）。

**Interfaces:**
- Produces: `MonthlyAttendanceSummaryPolicy#index?/show?/submit?/finalize?/defer?/bulk_finalize?` + `Scope`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "rails_helper"

RSpec.describe MonthlyAttendanceSummaryPolicy, type: :policy do
  subject { described_class.new(user, summary) }

  let(:owner) { create(:user) }
  let(:summary) { create(:monthly_attendance_summary, user: owner) }

  context "本人" do
    let(:user) { owner }
    it { is_expected.to permit_actions(%i[index show submit]) }
    it { is_expected.to forbid_actions(%i[finalize defer]) }
  end

  context "直属 manager" do
    let(:user) { create(:user, :manager_role) }
    before { owner.update!(manager: user) }
    it { is_expected.to permit_actions(%i[index show finalize defer]) }
    it { is_expected.to forbid_actions(%i[submit]) }
  end

  context "無関係な manager（別部下の上長）" do
    let(:user) { create(:user, :manager_role) }
    it { is_expected.to forbid_actions(%i[show finalize defer]) }
  end

  context "hr_admin" do
    let(:user) { create(:user, :hr_admin_role) }
    it { is_expected.to permit_actions(%i[index show finalize defer]) }
  end

  describe "Scope" do
    it "自分 + 直属部下の summary のみ返す" do
      manager = create(:user, :manager_role)
      sub = create(:user, manager:)
      other = create(:user)
      own = create(:monthly_attendance_summary, user: manager)
      sub_s = create(:monthly_attendance_summary, user: sub)
      create(:monthly_attendance_summary, user: other)

      resolved = described_class::Scope.new(manager, MonthlyAttendanceSummary).resolve
      expect(resolved).to contain_exactly(own, sub_s)
    end

    it "hr_admin は組織全件" do
      admin = create(:user, :hr_admin_role)
      s1 = create(:monthly_attendance_summary)
      s2 = create(:monthly_attendance_summary)
      resolved = described_class::Scope.new(admin, MonthlyAttendanceSummary).resolve
      expect(resolved).to include(s1, s2)
    end
  end
end
```

> 注: `:manager_role` / `:hr_admin_role` trait は既存 user factory にある想定（`leave_request_policy_spec` 等で使用実績）。無ければ `role: :manager` 等で代替。

- [ ] **Step 2: テストが落ちるのを確認**

Run: `bundle exec rspec spec/policies/monthly_attendance_summary_policy_spec.rb`
Expected: FAIL（`uninitialized constant`）

- [ ] **Step 3: 実装**

```ruby
# frozen_string_literal: true

# 締めの認可（SPEC §6.6・§3.4・3-2 設計 §4.1）。
# 本人=提出、直属 manager/hr_admin=確定/差戻し。
# 注: SPEC §4.1 の「階層述語（例 subordinate_of?）」は未実装ゆえ ProxyClockingPolicy 同型の
# 直属 manager で action 述語と Scope を一致させる（多段は Phase 5 ダッシュボードまで YAGNI）。
class MonthlyAttendanceSummaryPolicy < ApplicationPolicy
  def index? = user.present?
  def show? = own? || manages? || user.hr_admin?
  def submit? = own? || user.hr_admin?
  def finalize? = manages? || user.hr_admin?
  def defer? = finalize?
  def bulk_finalize? = user.manager? || user.hr_admin? # class-level（対象は Scope 交差で固定）

  private

  def own? = record.user_id == user.id
  def manages? = record.user.manager_id == user.id

  class Scope < ApplicationPolicy::Scope
    # 自分 + 直属部下（§3.4・ProxyClockingPolicy 同型）。organization_id 明示（without_tenant 耐性）。
    def resolve
      if user.hr_admin?
        scope.where(organization_id: user.organization_id)
      else
        subordinate_ids = User.where(organization_id: user.organization_id, manager_id: user.id).select(:id)
        scope.where(organization_id: user.organization_id, user_id: subordinate_ids)
             .or(scope.where(organization_id: user.organization_id, user_id: user.id))
      end
    end
  end
end
```

- [ ] **Step 4: テストが通るのを確認**

Run: `bundle exec rspec spec/policies/monthly_attendance_summary_policy_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/policies/monthly_attendance_summary_policy.rb
git add app/policies/monthly_attendance_summary_policy.rb spec/policies/monthly_attendance_summary_policy_spec.rb
git commit -m "feat(3-2): MonthlyAttendanceSummaryPolicy（本人=提出/上長=確定・差戻し）"
```

---

## Task 13: controller + routes + UI（提出/確定/差戻し・同期）

**Files:**
- Create: `app/controllers/monthly_attendance_summaries_controller.rb`
- Modify: `config/routes.rb`
- Create: `app/views/monthly_attendance_summaries/index.html.erb`（社員: 締め期間一覧 + 提出）
- Create: `app/views/monthly_attendance_summaries/show.html.erb`（締めページ: status/集計値/提出ボタン/in-flight 一覧/deferred バナー）
- Modify: ナビ（必要なら）
- Test: `spec/requests/monthly_attendance_summaries_spec.rb`

**Interfaces:**
- Consumes: `MonthlySummaries::Submit/Finalize/Defer`、`PendingRequests`、`AttendancePeriod`、Policy
- Produces: routes `monthly_attendance_summaries`（index/show + member submit / finalize / defer）

- [ ] **Step 1: routes 追加**

`config/routes.rb` の `resources :approval_assignments ...` の後ろに:

```ruby
  resources :monthly_attendance_summaries, only: %i[index show] do
    member do
      patch :submit
      patch :finalize
      patch :defer
    end
  end
```

- [ ] **Step 2: 失敗する request spec を書く**

```ruby
require "rails_helper"

RSpec.describe "MonthlyAttendanceSummaries", type: :request do
  let(:org) { create(:organization) }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  before { sign_in user }

  def host_headers = { "HOST" => tenant_host(org) }

  it "本人が自分の締めを提出できる" do
    summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user:) }
    patch submit_monthly_attendance_summary_path(summary), headers: host_headers
    expect(response).to have_http_status(:see_other)
    expect(summary.reload).to be_submitted
  end

  it "scope 外の summary は 404（IDOR）" do
    other = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: create(:user)) }
    patch submit_monthly_attendance_summary_path(other), headers: host_headers
    expect(response).to have_http_status(:not_found)
  end

  it "上長が部下の締めを確定できる" do
    manager = ActsAsTenant.with_tenant(org) { create(:user, :manager_role) }
    sub = ActsAsTenant.with_tenant(org) { create(:user, manager:) }
    summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: sub, status: :submitted) }
    sign_in manager
    patch finalize_monthly_attendance_summary_path(summary), headers: host_headers
    expect(summary.reload).to be_finalized
  end

  it "差戻しは reason 必須（空なら再描画・遷移しない）" do
    manager = ActsAsTenant.with_tenant(org) { create(:user, :manager_role) }
    sub = ActsAsTenant.with_tenant(org) { create(:user, manager:) }
    summary = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: sub, status: :submitted) }
    sign_in manager
    patch defer_monthly_attendance_summary_path(summary), params: { deferral_reason: "" }, headers: host_headers
    expect(summary.reload).to be_submitted # 遷移していない
  end
end
```

- [ ] **Step 3: テストが落ちるのを確認**

Run: `bundle exec rspec spec/requests/monthly_attendance_summaries_spec.rb`
Expected: FAIL（controller/route 未定義）

- [ ] **Step 4: controller を実装**

```ruby
# frozen_string_literal: true

# 月次締め（SPEC §6.6・3-2 設計 §4.2）。本人=提出、上長/hr_admin=確定/差戻し。
class MonthlyAttendanceSummariesController < ApplicationController
  before_action :set_summary, only: %i[show submit finalize defer]

  def index
    authorize MonthlyAttendanceSummary
    @summaries = policy_scope(MonthlyAttendanceSummary).order(year_month: :desc)
  end

  def show
    authorize @summary
    @period = AttendancePeriod.new(organization: current_tenant, year_month: @summary.year_month)
    @pending = MonthlySummaries::PendingRequests.new(user: @summary.user, period: @period)
  end

  def submit
    authorize @summary, :submit?
    period = AttendancePeriod.new(organization: current_tenant, year_month: @summary.year_month)
    MonthlySummaries::Submit.call(user: @summary.user, period:)
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, notice: "締めを提出しました"
  rescue Approvals::ConflictError
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other,
                alert: "承認手続き中の申請があります。完了またはキャンセル後に提出してください"
  rescue AASM::InvalidTransition
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, alert: "この締めは提出できません"
  end

  def finalize
    authorize @summary, :finalize?
    MonthlySummaries::Finalize.call(summary: @summary)
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, notice: "締めを確定しました"
  rescue AASM::InvalidTransition
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, alert: "この締めは確定できません"
  end

  def defer
    authorize @summary, :defer?
    MonthlySummaries::Defer.call(summary: @summary, reason: params[:deferral_reason])
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, notice: "差戻しました"
  rescue ActiveRecord::RecordInvalid
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, alert: "差戻し理由を入力してください"
  rescue AASM::InvalidTransition
    redirect_to monthly_attendance_summary_path(@summary), status: :see_other, alert: "この締めは差戻しできません"
  end

  private

  def current_tenant = ActsAsTenant.current_tenant

  def set_summary
    @summary = policy_scope(MonthlyAttendanceSummary).find(params[:id])
  end
end
```

> 注: `status`/`deferral_reason` を strong params で permit しない（サーバ権威）。`deferral_reason` は `params[:deferral_reason]`（trusted・Defer サービスが検証）を直接渡す。

- [ ] **Step 5: 最小ビューを作る**

`app/views/monthly_attendance_summaries/index.html.erb`:

```erb
<h1>月次締め</h1>
<table>
  <thead><tr><th>対象月</th><th>状態</th><th></th></tr></thead>
  <tbody>
    <% @summaries.each do |s| %>
      <tr>
        <td><%= s.year_month %></td>
        <td><%= t("activerecord.attributes.monthly_attendance_summary.statuses.#{s.status}", default: s.status) %></td>
        <td><%= link_to "詳細", monthly_attendance_summary_path(s) %></td>
      </tr>
    <% end %>
  </tbody>
</table>
```

`app/views/monthly_attendance_summaries/show.html.erb`:

```erb
<h1><%= @summary.year_month %> の締め</h1>
<p>状態: <%= @summary.status %></p>

<% if @summary.deferred? && @summary.deferral_reason.present? %>
  <div class="banner banner-alert">差戻し理由: <%= @summary.deferral_reason %></div>
<% end %>

<dl>
  <dt>実出勤日数</dt><dd><%= @summary.work_days %></dd>
  <dt>総労働時間</dt><dd><%= @summary.total_work_hours %></dd>
  <dt>総残業</dt><dd><%= @summary.total_overtime_hours %></dd>
  <dt>深夜</dt><dd><%= @summary.total_deep_night_hours %></dd>
</dl>

<% if policy(@summary).submit? && (@summary.aggregating? || @summary.deferred?) %>
  <% if @pending.any? %>
    <p>承認手続き中・申請中の申請があるため提出できません:</p>
    <ul>
      <% @pending.started.each do |r| %><li>承認進行中: <%= r.class.model_name.human %> #<%= r.id %></li><% end %>
      <% @pending.not_started.each do |r| %><li>申請中（キャンセルで提出可）: <%= r.class.model_name.human %> #<%= r.id %></li><% end %>
    </ul>
    <%= button_to "提出", submit_monthly_attendance_summary_path(@summary), method: :patch, disabled: true %>
  <% else %>
    <%= button_to (@summary.deferred? ? "再提出" : "提出"), submit_monthly_attendance_summary_path(@summary), method: :patch %>
  <% end %>
<% end %>

<% if policy(@summary).finalize? && @summary.submitted? %>
  <%= button_to "確定", finalize_monthly_attendance_summary_path(@summary), method: :patch %>
<% end %>

<% if policy(@summary).defer? && (@summary.submitted? || @summary.finalized?) %>
  <%= form_with url: defer_monthly_attendance_summary_path(@summary), method: :patch do |f| %>
    <%= f.text_field :deferral_reason, placeholder: "差戻し理由" %>
    <%= f.submit "差戻し" %>
  <% end %>
<% end %>
```

- [ ] **Step 6: i18n の status ラベル（任意・default で動くが整える）**

`config/locales/ja.yml` の `activerecord.attributes` 下に追記（既存構造に合わせる）:

```yaml
      monthly_attendance_summary:
        statuses:
          aggregating: 集計中
          submitted: 提出済
          finalized: 確定
          deferred: 差戻し
```

- [ ] **Step 7: テストが通るのを確認**

Run: `bundle exec rspec spec/requests/monthly_attendance_summaries_spec.rb`
Expected: PASS

- [ ] **Step 8: rubocop + brakeman + commit**

```bash
bundle exec rubocop --force-exclusion app/controllers/monthly_attendance_summaries_controller.rb
bin/brakeman --no-pager
git add app/controllers/monthly_attendance_summaries_controller.rb config/routes.rb app/views/monthly_attendance_summaries config/locales/ja.yml spec/requests/monthly_attendance_summaries_spec.rb
git commit -m "feat(3-2): 締めの提出/確定/差戻し controller + UI（同期）"
```

---

## Task 14: ConflictError の締め由来文言分岐（承認インボックス）

**Files:**
- Modify: `app/controllers/approval_assignments_controller.rb`
- Test: `spec/requests/approval_assignments_spec.rb`（締め由来文言の example 追加）

**Interfaces:**
- Consumes: `Approvals::ClosingLockedError`（Task 7）

- [ ] **Step 1: 失敗するテストを書く**

`spec/requests/approval_assignments_spec.rb` に追記（既存 request spec の文脈に合わせる）:

```ruby
  it "締め済み月の承認は締め由来の flash を出す（ClosingLockedError）" do
    # 承認者でログインし、対象月が submitted の申請を approve しようとすると締め由来文言
    # （セットアップは既存 spec の承認フローに合わせる。要点は alert が「締め済み」を含むこと）
    # ... 申請作成 → 対象月 summary を submitted → approve patch
    # expect(flash[:alert]).to include("締め済み")
  end
```

> 実装注: 既存 `approval_assignments_spec.rb` の承認セットアップ（requester/approver/assignment）を流用し、対象月の summary を submitted にしてから `patch approve_approval_assignment_path(assignment)`。flash[:alert] が締め由来文言を含むことを assert。

- [ ] **Step 2: テストが落ちるのを確認**

Run: `bundle exec rspec spec/requests/approval_assignments_spec.rb -e "締め済み"`
Expected: FAIL（CCR 専用文言が出る）

- [ ] **Step 3: 文言分岐を実装**

`app/controllers/approval_assignments_controller.rb` の `rescue Approvals::ConflictError` を、ClosingLockedError を先に拾う形へ:

```ruby
  rescue Approvals::ClosingLockedError
    redirect_to approval_assignments_path, status: :see_other,
                alert: "対象月は締め済みのため承認できません（管理者へ差戻し依頼をご検討ください）"
  rescue Approvals::ConflictError
    msg = @assignment.purpose_withdrawal? ? "対象記録が変更されているため撤回できません" :
                                            "変更前時刻が現在の記録と一致しません（申請者へ再申請をご依頼ください）"
    redirect_to approval_assignments_path, status: :see_other, alert: msg
```

> 注: `rescue ClosingLockedError` を `rescue ConflictError` の**前**に置く（サブクラスゆえ順序が重要・後ろだと親が先に拾う）。

- [ ] **Step 4: テストが通るのを確認**

Run: `bundle exec rspec spec/requests/approval_assignments_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/controllers/approval_assignments_controller.rb
git add app/controllers/approval_assignments_controller.rb spec/requests/approval_assignments_spec.rb
git commit -m "feat(3-2): 承認インボックスで締め由来 ConflictError を専用文言に分岐"
```

---

## Task 15: SolidQueue を dev/test で動かす設定

**Files:**
- Modify: `config/environments/development.rb`
- Modify: `config/environments/test.rb`
- Modify: `config/database.yml`（dev に queue DB を追加・本番同型）
- Modify: `docs/RAILS_GOTCHAS.md`（SolidQueue dev 配線の罠を記録）

**Interfaces:**
- Produces: dev で `:solid_queue` adapter が enqueue→perform 可能・test で `:test` adapter（`assert_enqueued_with`）

- [ ] **Step 1: test 環境を :test に固定**

`config/environments/test.rb` に追加（ActiveJob のデフォルトだが明示）:

```ruby
  config.active_job.queue_adapter = :test
```

- [ ] **Step 2: dev 環境を solid_queue に**

`config/environments/development.rb` に追加:

```ruby
  # 初の SolidQueue 利用（3-2）。dev は本番同型の専用 queue DB に接続（primary を汚さない）。
  config.active_job.queue_adapter = :solid_queue
  config.solid_queue.connects_to = { database: { writing: :queue } }
```

- [ ] **Step 3: database.yml の development に queue / cable を追加（本番同型）**

`config/database.yml` の `development:` を本番の multi-db 形へ揃える。現状の単一 `development:` を primary 化し queue を足す:

```yaml
development:
  primary:
    <<: *default
    database: gatcha_development
  queue:
    <<: *default
    database: gatcha_development_queue
    migrations_paths: db/queue_migrate
```

（`*default` は既存アンカーに合わせる。`cable` は SolidCable 利用時に追加だが本スライスは queue のみで足りる）

- [ ] **Step 4: queue DB を作成しスキーマをロード**

Run:
```bash
bin/rails db:create
bin/rails db:prepare
```
Expected: `gatcha_development_queue` が作成され `db/queue_schema.rb` のテーブルがロードされる。

> 罠（plan 想定・実機で確認）: `db/queue_migrate` が無い場合は `config/database.yml` の `migrations_paths` を一旦外し、`db/queue_schema.rb` を `bin/rails runner "load 'db/queue_schema.rb'"` 相当でロードする。SolidQueue の標準は schema ロード方式。実機で `db:prepare` が queue スキーマを載せるか確認し、載らなければ schema ロードに切替。

- [ ] **Step 5: dev console で enqueue→perform を実機確認**

Run:
```bash
bin/rails runner 'ActsAsTenant.with_tenant(Organization.first) { ActiveJob::Base.queue_adapter.class.name.then { |n| puts n } }'
```
Expected: `ActiveJob::QueueAdapters::SolidQueueAdapter`（dev で solid_queue 解決）

別途 `bin/jobs` でワーカーが起動することを確認（Task 16 で実ジョブを流す）。

- [ ] **Step 6: RAILS_GOTCHAS に記録**

`docs/RAILS_GOTCHAS.md` の適切な節（Rails / ツールチェーン or 新設「SolidQueue」節）に WHAT/WHY/HOW/verified で追記:

```markdown
### SolidQueue を dev で動かすには queue 用 DB 配線が要る（本番のみ既定設定）

- **WHAT**: Phase 3-2 まで queue adapter は本番のみ `:solid_queue` + 専用 queue DB。dev/test 未設定で、dev で job を enqueue しても処理されない／`connects_to` 不整合で起動失敗し得る
- **WHY**: `config/environments/development.rb` に adapter 設定が無く、`database.yml` の dev が単一 DB（queue 接続先なし）だった
- **HOW**: test=`:test`（assert_enqueued）、dev=`:solid_queue` + `connects_to {database:{writing: :queue}}`、`database.yml` dev を primary/queue の multi-db 化し `gatcha_development_queue` を `db:prepare`。worker は `bin/jobs`
- verified: Rails 8.1 / SolidQueue / 2026-06-21（3-2 BulkFinalizeJob で実踏）
```

- [ ] **Step 7: 既存テスト全体が緑のままか確認（設定変更の波及確認）**

Run: `bundle exec rspec`
Expected: PASS（adapter 変更で既存が壊れていない）

- [ ] **Step 8: Commit**

```bash
git add config/environments/development.rb config/environments/test.rb config/database.yml docs/RAILS_GOTCHAS.md
git commit -m "chore(3-2): SolidQueue を dev(専用queue DB)/test(:test) で動かす設定"
```

---

## Task 16: BulkFinalizeJob（初の SolidQueue ジョブ）

**Files:**
- Create: `app/jobs/monthly_summaries/bulk_finalize_job.rb`
- Test: `spec/jobs/monthly_summaries/bulk_finalize_job_spec.rb`

**Interfaces:**
- Consumes: `MonthlySummaries::Finalize.call(summary:)`、`ActsAsTenant.with_tenant`
- Produces: `MonthlySummaries::BulkFinalizeJob.perform_later(organization_id:, summary_ids:)`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "rails_helper"

RSpec.describe MonthlySummaries::BulkFinalizeJob, type: :job do
  let(:org) { create(:organization) }

  it "submitted な summary 群を finalized にする" do
    s1, s2 = ActsAsTenant.with_tenant(org) do
      [create(:monthly_attendance_summary, status: :submitted),
       create(:monthly_attendance_summary, status: :submitted)]
    end
    described_class.perform_now(organization_id: org.id, summary_ids: [s1.id, s2.id])
    expect(s1.reload).to be_finalized
    expect(s2.reload).to be_finalized
  end

  it "submitted 以外は skip（冪等・at-least-once 再実行で壊れない）" do
    agg, sub = ActsAsTenant.with_tenant(org) do
      [create(:monthly_attendance_summary, status: :aggregating),
       create(:monthly_attendance_summary, status: :submitted)]
    end
    described_class.perform_now(organization_id: org.id, summary_ids: [agg.id, sub.id])
    expect(agg.reload).to be_aggregating
    expect(sub.reload).to be_finalized
  end

  it "他テナントの id が混じっても finalized にしない（with_tenant スコープ遮断）" do
    own = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, status: :submitted) }
    other_org = create(:organization)
    foreign = ActsAsTenant.with_tenant(other_org) { create(:monthly_attendance_summary, status: :submitted) }
    described_class.perform_now(organization_id: org.id, summary_ids: [own.id, foreign.id])
    expect(own.reload).to be_finalized
    expect(foreign.reload).to be_submitted # 別テナントは scope 外で触れない
  end

  it "1 件の失敗が他を巻き込まない（隔離）" do
    s1, s2 = ActsAsTenant.with_tenant(org) do
      [create(:monthly_attendance_summary, status: :submitted),
       create(:monthly_attendance_summary, status: :submitted)]
    end
    allow(MonthlySummaries::Finalize).to receive(:call).and_call_original
    allow(MonthlySummaries::Finalize).to receive(:call).with(summary: have_attributes(id: s1.id))
      .and_raise(ActiveRecord::RecordInvalid.new(s1))
    described_class.perform_now(organization_id: org.id, summary_ids: [s1.id, s2.id])
    expect(s2.reload).to be_finalized # s1 が落ちても s2 は確定
  end
end
```

> 注: 4 つ目の example の stub は `Finalize.call` の引数照合が難しければ、`s1` を別状態にして自然に skip させる形に簡略化してよい（要点は「1 件の例外が rescue で隔離され他が進む」）。

- [ ] **Step 2: テストが落ちるのを確認**

Run: `bundle exec rspec spec/jobs/monthly_summaries/bulk_finalize_job_spec.rb`
Expected: FAIL（`uninitialized constant`）

- [ ] **Step 3: 実装**

```ruby
# frozen_string_literal: true

module MonthlySummaries
  # 月次一括確定（SPEC §6.6・§16.2・3-2 設計 §3.2）。初の SolidQueue ジョブ。
  # 認可境界は enqueue 時の policy_scope 交差（controller・§3.3）。ジョブ内に再認可は無い。
  # organization_id は server 由来（ActsAsTenant.current_tenant.id）で渡すこと。
  class BulkFinalizeJob < ApplicationJob
    def perform(organization_id:, summary_ids:)
      org = Organization.find(organization_id)
      ActsAsTenant.with_tenant(org) do # §3.6 必須（リクエスト文脈なし）
        MonthlyAttendanceSummary.where(id: summary_ids).find_each do |summary|
          Finalize.call(summary:) if summary.submitted? # 唯一経路・冪等（非 submitted skip）
        rescue AASM::InvalidTransition, ActiveRecord::RecordInvalid => e
          Rails.logger.warn("[BulkFinalize] skip ##{summary.id}: #{e.class}") # 1 件失敗を隔離（4-1 で通知）
        end
      end
    end
  end
end
```

- [ ] **Step 4: テストが通るのを確認**

Run: `bundle exec rspec spec/jobs/monthly_summaries/bulk_finalize_job_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/jobs/monthly_summaries/bulk_finalize_job.rb
git add app/jobs/monthly_summaries/bulk_finalize_job.rb spec/jobs/monthly_summaries/bulk_finalize_job_spec.rb
git commit -m "feat(3-2): MonthlySummaries::BulkFinalizeJob（初の SolidQueue・with_tenant ラップ）"
```

---

## Task 17: 一括確定の controller action + IDOR 交差 + UI

**Files:**
- Modify: `config/routes.rb`（collection `bulk_finalize`）
- Modify: `app/controllers/monthly_attendance_summaries_controller.rb`（bulk_finalize action）
- Modify: `app/views/monthly_attendance_summaries/index.html.erb`（複数選択 + 一括確定ボタン）
- Test: `spec/requests/monthly_attendance_summaries_spec.rb`（一括 + IDOR enqueue）

**Interfaces:**
- Consumes: `MonthlySummaries::BulkFinalizeJob`、`policy_scope`、`MonthlyAttendanceSummaryPolicy#bulk_finalize?`

- [ ] **Step 1: routes に collection 追加**

`config/routes.rb` の `resources :monthly_attendance_summaries` ブロックに collection を追加:

```ruby
  resources :monthly_attendance_summaries, only: %i[index show] do
    collection { patch :bulk_finalize }
    member do
      patch :submit
      patch :finalize
      patch :defer
    end
  end
```

- [ ] **Step 2: 失敗する request spec を書く**

```ruby
  describe "一括確定" do
    let(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role) } }
    let(:sub) { ActsAsTenant.with_tenant(org) { create(:user, manager:) } }

    before { sign_in manager }

    it "scope 内 id のみで BulkFinalizeJob を enqueue する" do
      mine = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: sub, status: :submitted) }
      foreign = ActsAsTenant.with_tenant(org) { create(:monthly_attendance_summary, user: create(:user), status: :submitted) }
      expect {
        patch bulk_finalize_monthly_attendance_summaries_path,
              params: { summary_ids: [mine.id, foreign.id] }, headers: host_headers
      }.to have_enqueued_job(MonthlySummaries::BulkFinalizeJob)
        .with(organization_id: org.id, summary_ids: [mine.id]) # foreign は scope 交差で除外
    end

    it "employee は一括確定できない（403）" do
      sign_in user # 一般社員
      patch bulk_finalize_monthly_attendance_summaries_path,
            params: { summary_ids: [] }, headers: host_headers
      expect(response).to have_http_status(:forbidden)
    end
  end
```

> 注: `have_enqueued_job` の `summary_ids: [mine.id]` 照合は順序・型に依存するため、実装で `pluck(:id)` の結果（Integer 配列）に揃える。foreign が除外されることが要点。

- [ ] **Step 3: テストが落ちるのを確認**

Run: `bundle exec rspec spec/requests/monthly_attendance_summaries_spec.rb -e "一括確定"`
Expected: FAIL（action 未定義）

- [ ] **Step 4: controller に bulk_finalize を実装**

`monthly_attendance_summaries_controller.rb` に追加:

```ruby
  def bulk_finalize
    authorize MonthlyAttendanceSummary, :bulk_finalize?
    ids = policy_scope(MonthlyAttendanceSummary).where(id: params[:summary_ids]).pluck(:id) # IDOR 交差（§3.3）
    MonthlySummaries::BulkFinalizeJob.perform_later(organization_id: current_tenant.id, summary_ids: ids)
    redirect_to monthly_attendance_summaries_path, status: :see_other, notice: "#{ids.size} 件の確定を受け付けました"
  end
```

`before_action :set_summary` の `only:` に `bulk_finalize` を**含めない**こと（class-level・record 不要）。

- [ ] **Step 5: index ビューに一括フォームを追加**

`index.html.erb` を複数選択フォームで包む（最小）:

```erb
<%= form_with url: bulk_finalize_monthly_attendance_summaries_path, method: :patch do |f| %>
  <table>
    <thead><tr><th></th><th>対象月</th><th>状態</th><th></th></tr></thead>
    <tbody>
      <% @summaries.each do |s| %>
        <tr>
          <td><%= check_box_tag "summary_ids[]", s.id if s.submitted? %></td>
          <td><%= s.year_month %></td>
          <td><%= s.status %></td>
          <td><%= link_to "詳細", monthly_attendance_summary_path(s) %></td>
        </tr>
      <% end %>
    </tbody>
  </table>
  <% if policy(MonthlyAttendanceSummary).bulk_finalize? %>
    <%= f.submit "選択を一括確定" %>
  <% end %>
<% end %>
```

- [ ] **Step 6: テストが通るのを確認**

Run: `bundle exec rspec spec/requests/monthly_attendance_summaries_spec.rb`
Expected: PASS

- [ ] **Step 7: rubocop + brakeman + commit**

```bash
bundle exec rubocop --force-exclusion app/controllers/monthly_attendance_summaries_controller.rb
bin/brakeman --no-pager
git add config/routes.rb app/controllers/monthly_attendance_summaries_controller.rb app/views/monthly_attendance_summaries/index.html.erb spec/requests/monthly_attendance_summaries_spec.rb
git commit -m "feat(3-2): 月次一括確定 action（policy_scope 交差で IDOR 防御・SolidQueue enqueue）"
```

---

## Task 18: 仕上げ — preflight + ROADMAP 更新

**Files:**
- Modify: `docs/ROADMAP.md`（3-2 行にチェック + PR 番号）

- [ ] **Step 1: 全体テスト + lint + brakeman**

Run:
```bash
bundle exec rspec
bundle exec rubocop
bin/brakeman --no-pager
```
Expected: 全緑

- [ ] **Step 2: `/preflight` 相当の確認**（push 前の CI 等価チェック）

- [ ] **Step 3: ROADMAP の 3-2 行を更新**

`docs/ROADMAP.md` の `- [ ] **3-2 締め状態機械 + 申請制限**: ...` を `- [x]` にし末尾に `（PR #XX）` を追記。

- [ ] **Step 4: Commit + PR**

```bash
git add docs/ROADMAP.md
git commit -m "docs(3-2): ROADMAP の Phase 3-2 を完了マーク"
```

PR 作成前に `gh auth switch -u kei1110` を確認（CLAUDE.md・collaborator エラー回避）。

---

## レビュー / マージ前チェック（CLAUDE.md 規約）

- **`tenant-isolation-reviewer`**: Task 1（migration）/ Task 4,5,6（ClosingLock の with_tenant・concern）/ Task 16（job の with_tenant ラップ）に触れたため必須
- **`approval-engine-reviewer`**: Task 6（Withdrawable guard）/ Task 7（Approve#guard! 注入）/ Task 2（AASM 状態機械）/ Task 10,11（締めサービスの tx 境界）に触れたため必須
- **`/spec-check`**: フェーズ完了時に §6.6 / §6.7 / §13.4 の追従確認
- レビュアー subagent のプロンプトに `docs/RAILS_GOTCHAS.md` を注入（罠の再購入防止）

---

## Self-Review（writing-plans 手順 — spec 照合）

**1. Spec coverage（spec §1〜§5 → Task 対応）:**
- §1.1 migration → Task 1 ✓ / §1.2 AASM → Task 2 ✓ / §1.3 Submit/Finalize/Defer → Task 10,11 ✓
- §2.1 containing/ClosingLock → Task 3,4 ✓ / §2.2 ClosingRestricted → Task 5 ✓ / §2.3 Withdrawable guard → Task 6 ✓ / §2.4 Approve 注入 + ClosingLockedError + ガード spec → Task 7,8 ✓
- §3.1 PendingRequests → Task 9 ✓ / §3.2 BulkFinalizeJob + IDOR + org server 由来 → Task 16,17 ✓ / D9 dev queue → Task 15 ✓
- §4.1 Policy → Task 12 ✓ / §4.2 UI → Task 13,17 ✓ / §4.3 テスト → 各 Task の spec ✓ / §4.4 レビュー → レビュー節 ✓
- §5 コミット境界（Group A/B/C）→ Global Constraints + Task 配置 ✓ / read-skew 自動テスト対象外 → Task 7 の構造 backstop で代替 ✓
- サーバ権威（mass-assignment）→ Task 2 コメント + Task 13 strong params 不受領 ✓
- ConflictError 文言分岐 → Task 14 ✓

**2. Placeholder scan:** 各 Task に実コード・実コマンド・期待出力を記載。テスト内の「セットアップは既存 spec に合わせる」は既存パターン参照の指示であり TBD でない。

**3. Type consistency:** `MonthlySummaries::Submit/Finalize/Defer/PendingRequests/ClosingLock/BulkFinalizeJob`・`AttendancePeriod.containing`・`ClosingRestricted#closing_target_dates/closing_locked?/closing_unlocked?`・`Approvals::ClosingLockedError`・Policy 述語名は全 Task 通して一貫。`Finalize.call(summary:)` の引数名は Task 10/16/17 で一致。

**判明した plan 段の決定（spec からの精緻化）:**
- §4.1「階層述語（例 subordinate_of?）」→ `subordinate_of?` 未実装ゆえ **直属 manager + hr_admin**（ProxyClockingPolicy precedent）で action 述語と Scope を一致（Task 12 にコメント・多段は Phase 5 まで YAGNI）
- D9 dev queue 配線 → **本番同型の専用 queue DB**（dev に `gatcha_development_queue`）を採用（Task 15・実機で db:prepare の挙動を確認するフォールバック付き）
