# Phase 2-3 ClockChangeRequest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 社員が既存の打刻済記録の時刻変更を申請し、2 段承認 → §7.4 競合チェック → 記録時刻更新 + §5 再計算 + 前後値つき AttendanceHistory まで一周できるようにする。

**Architecture:** 2-2b で確立した「汎用承認エンジン hook → host 別 `ApplyApproval` service・同一 tx・atomic rollback」を 2 つ目の承認対象 `ClockChangeRequest` に適用する。CCR 固有ロジックは §7.4 競合チェック（Create が `original_*` を snapshot → 承認時 `FOR UPDATE` で現記録と厳密照合 → `ConflictError` で承認ごと巻き戻し）に局所化。エンジン（Start/Approve/Reject/Cancel）・Recalculate・承認インボックスは全面再利用。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / acts_as_tenant / Pundit / AASM / ViewComponent / Hotwire / RSpec + FactoryBot

**設計典拠:** `docs/superpowers/specs/2026-06-18-phase2-3-clock-change-request-design.md`（D1–D7・§1–§8）

## Global Constraints

- **Git identity:** コミットは `kei1110 <eoh2145@gmail.com>`（local config 済）。ステップ完了ごとに即コミット。メッセージ末尾に `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。
- **検証コマンド:** タスク完了時 `bundle exec rspec <該当 spec>` 緑 → `bundle exec rubocop --force-exclusion <触れたファイル>`（ファイル明示時は必ず `--force-exclusion`）。app/ 変更タスクは `bin/brakeman --no-pager`。
- **テナント文脈:** `acts_as_tenant` 越境ガードは **ID 基点 fail-closed**（`*_id.nil?` early return → association 比較）。`ApplyApproval` は `ActsAsTenant.with_tenant(org)` 明示ラップ（Recalculate 同型）。console/rake は先頭で `ActsAsTenant.current_tenant = Organization.find_by!(subdomain: "...")`。
- **スキーマ:** `db/schema.rb` を手編集しない（`block-schema-edit` フック）。変更は migration 経由のみ。
- **AASM:** `approval_status` は AASM イベント（`approve!`/`reject!`/`cancel!`）でのみ遷移。`original_*`/`new_*`/`approval_status` は strong params 恒久ブロック（writer は Create のみ）。
- **★ユーザー入力時刻は組織 TZ で parse（2-3 の新 gotcha）:** `new_clock_in`/`new_clock_out` は datetime 入力。`config.time_zone` 未設定（UTC）ゆえ `Time.zone.parse` だと組織 TZ とズレる。controller は **`ActiveSupport::TimeZone[current_user.organization.time_zone].parse(値)`** で組織 TZ 固定。
- **timestamptz 厳密比較:** 競合チェックは DB 由来値同士（snapshot した `original_*` と現 `record.clock_*`）を `==` で比較。`Time.parse` 値や精度を落とした値と比較しない（偽 ConflictError 防止）。
- **副作用は同一 tx・内側 rescue なし:** `ConflictError` は raise 伝播 → 承認ごと atomic rollback。controller 層で rescue して flash。

---

## File Structure

| ファイル | 責務 |
|---|---|
| `db/migrate/*_create_clock_change_requests.rb` | テーブル + 複合 FK + index |
| `app/models/clock_change_request.rb` | 申請モデル（Approvable・change_type 別検証・clocked_out 限定・所有・テナント） |
| `app/models/attendance_history.rb` | `clock_change_approved` の actor 必須（追記） |
| `app/services/approvals.rb` | `ConflictError`（追記） |
| `app/services/clock_change_requests/create.rb` | 申請作成（original_* snapshot・Start 起動） |
| `app/services/clock_change_requests/apply_approval.rb` | 側作用（競合チェック・時刻更新・recalc・前後値 history） |
| `app/policies/clock_change_request_policy.rb` | 本人 Scope・index?/new?/cancel? |
| `app/controllers/clock_change_requests_controller.rb` | index/new/create/cancel（requester 固定・Cancel 再利用・組織 TZ parse） |
| `app/controllers/approval_assignments_controller.rb` | approve に `ConflictError` rescue（追記） |
| `app/components/approvals/clock_change_request_row_component.{rb,html.erb}` | インボックス CCR 行 |
| `app/views/approval_assignments/index.html.erb` | `when ClockChangeRequest` dispatch（追記） |
| `app/views/clock_change_requests/{new,_form,index}.html.erb` | 申請フォーム・一覧 |
| `app/javascript/controllers/reason_chips_controller.js` | 理由チップの append（CCR 用・最小） |
| `config/routes.rb` | `resources :clock_change_requests`（追記） |
| `docs/ROADMAP.md` | 2-3 行更新 |

---

## Task 1: ClockChangeRequest モデル + migration

**Files:**
- Create: `db/migrate/<timestamp>_create_clock_change_requests.rb`
- Create: `app/models/clock_change_request.rb`
- Test: `spec/models/clock_change_request_spec.rb`
- Create: `spec/factories/clock_change_requests.rb`

**Interfaces:**
- Produces: `ClockChangeRequest`（`include Approvable`・`acts_as_tenant`・`belongs_to :requester, :attendance_record`）。enum `change_type { clock_in:0, clock_out:1, both:2, new_entry:3 }, prefix: :change`（述語 `change_clock_in?` 等）。検証群（change_type 別 new_clock_* presence・both で new_out>new_in・on_leave 拒否・clock_out 済限定・requester 所有・テナント越境）。

- [ ] **Step 1: factory を作成**

Create `spec/factories/clock_change_requests.rb`:

```ruby
# frozen_string_literal: true

FactoryBot.define do
  factory :clock_change_request do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    requester { association(:user) }
    attendance_record { association(:attendance_record, :done, user: requester) }
    change_type { :clock_in }
    new_clock_in { Time.utc(2026, 6, 1, 1) }   # JST 10:00
    reason { "打刻修正のため" }
  end
end
```

- [ ] **Step 2: 失敗するモデル spec を作成**

Create `spec/models/clock_change_request_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClockChangeRequest do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:user) { create(:user, organization: org) }
  let(:record) { create(:attendance_record, :done, user:, work_date: Date.new(2026, 6, 1)) }

  def build_ccr(**attrs)
    build(:clock_change_request, requester: user, attendance_record: record, **attrs)
  end

  it "デフォルト（clock_in 変更）は valid" do
    expect(build_ccr).to be_valid
  end

  describe "change_type 別 new_clock_* presence" do
    it "clock_in は new_clock_in 必須" do
      expect(build_ccr(change_type: :clock_in, new_clock_in: nil)).to be_invalid
    end

    it "clock_out は new_clock_out 必須" do
      expect(build_ccr(change_type: :clock_out, new_clock_in: nil, new_clock_out: nil)).to be_invalid
    end

    it "both は両方必須・new_out > new_in" do
      expect(build_ccr(change_type: :both, new_clock_in: Time.utc(2026, 6, 1, 1),
                       new_clock_out: Time.utc(2026, 6, 1, 9))).to be_valid
      expect(build_ccr(change_type: :both, new_clock_in: Time.utc(2026, 6, 1, 9),
                       new_clock_out: Time.utc(2026, 6, 1, 1))).to be_invalid   # out <= in
    end
  end

  it "reason 必須" do
    expect(build_ccr(reason: "")).to be_invalid
  end

  describe "対象記録の制約" do
    it "on_leave 記録は拒否" do
      leave = create(:attendance_record, user:, status: :on_leave, clock_in: nil,
                     work_date: Date.new(2026, 6, 2))
      expect(build_ccr(attendance_record: leave)).to be_invalid
    end

    it "working 記録（clock_out 無）は拒否・clocked_out は許可" do
      working = create(:attendance_record, user:, status: :working, work_date: Date.new(2026, 6, 3))
      expect(build_ccr(attendance_record: working)).to be_invalid
      expect(build_ccr(attendance_record: record)).to be_valid   # :done = clocked_out
    end

    it "他人の記録は拒否" do
      other = create(:user, organization: org)
      others_record = create(:attendance_record, :done, user: other, work_date: Date.new(2026, 6, 4))
      expect(build_ccr(attendance_record: others_record)).to be_invalid
    end
  end

  describe "テナント越境（ID 基点 fail-closed）" do
    it "他テナントの requester / attendance_record を拒否（association）" do
      other_org = create(:organization)
      other_user = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      ccr = build(:clock_change_request, organization: org, requester: other_user, attendance_record: record)
      expect(ccr).to be_invalid
      expect(ccr.errors[:requester]).to be_present
    end
  end

  it "approval_status は初期 applying" do
    expect(build_ccr.tap(&:validate)).to be_applying
  end
end
```

- [ ] **Step 3: spec を実行して fail を確認**

Run: `bundle exec rspec spec/models/clock_change_request_spec.rb`
Expected: FAIL（`ClockChangeRequest` 未定義 = `NameError`／テーブル不在）

- [ ] **Step 4: マイグレーションを生成・編集**

Run: `bin/rails g migration create_clock_change_requests`

生成ファイルを編集（複合 FK / index の idiom は `db/migrate/*_create_leave_requests.rb` と同型・実機確認済）:

```ruby
# frozen_string_literal: true

class CreateClockChangeRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :clock_change_requests do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :requester_id, null: false
      t.bigint :attendance_record_id              # new_entry は null（本スライスは非 null）
      t.integer :change_type, null: false
      t.date :target_date                         # new_entry 用予約（本スライス未使用）
      t.timestamptz :original_clock_in
      t.timestamptz :original_clock_out
      t.timestamptz :new_clock_in
      t.timestamptz :new_clock_out
      t.text :reason
      t.integer :approval_status, null: false, default: 0
      t.text :withdrawal_reason                   # 2-5 予約
      t.date :last_stale_notified_on              # Phase 4 予約
      t.timestamps
    end

    add_index :clock_change_requests, %i[organization_id id], unique: true
    add_index :clock_change_requests, %i[organization_id requester_id approval_status],
              name: "idx_ccr_requester_status"
    add_foreign_key :clock_change_requests, :users,
                    column: %i[organization_id requester_id], primary_key: %i[organization_id id]
    add_foreign_key :clock_change_requests, :attendance_records,
                    column: %i[organization_id attendance_record_id], primary_key: %i[organization_id id]
  end
end
```

- [ ] **Step 5: マイグレーション適用**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: 成功。`db/schema.rb` に `clock_change_requests` が追加。

- [ ] **Step 6: モデルを作成**

Create `app/models/clock_change_request.rb`:

```ruby
# frozen_string_literal: true

# 打刻変更申請（SPEC §4.11・Phase 2-3 設計 §1.1）。承認対象の 2 つ目。
# original_*/new_*/approval_status の writer は ClockChangeRequests::Create / 承認エンジンのみ（strong params 恒久ブロック）。
class ClockChangeRequest < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :requester, class_name: "User"
  belongs_to :attendance_record, optional: true   # new_entry は null（本スライスは非 null）

  include Approvable   # approval_status の AASM + has_many :approval_assignments

  # prefix: :change — 述語 change_clock_in? / change_clock_out? / change_both? / change_new_entry?
  enum :change_type, { clock_in: 0, clock_out: 1, both: 2, new_entry: 3 },
       validate: true, prefix: :change

  validates :reason, presence: true
  validate :new_times_present_for_change_type
  validate :new_clock_out_after_in
  validate :target_record_not_on_leave
  validate :target_record_clocked_out
  validate :requester_owns_target_record
  validate :requester_must_belong_to_same_organization
  validate :attendance_record_must_belong_to_same_organization

  private

  def new_times_present_for_change_type
    errors.add(:new_clock_in, "を入力してください") if (change_clock_in? || change_both?) && new_clock_in.blank?
    errors.add(:new_clock_out, "を入力してください") if (change_clock_out? || change_both?) && new_clock_out.blank?
  end

  def new_clock_out_after_in
    return unless change_both? && new_clock_in.present? && new_clock_out.present?
    return if new_clock_out > new_clock_in

    errors.add(:new_clock_out, "は出勤時刻以降にしてください")
  end

  def target_record_not_on_leave
    return unless attendance_record&.on_leave?

    errors.add(:attendance_record, "は全休日のため打刻変更できません")
  end

  def target_record_clocked_out
    return if attendance_record.nil? || attendance_record.clock_out.present?

    errors.add(:attendance_record, "は勤務中の記録のため変更できません（退勤後にお申し込みください）")
  end

  def requester_owns_target_record
    return if attendance_record.nil? || attendance_record.user_id == requester_id

    errors.add(:attendance_record, "は本人の記録ではありません")
  end

  # ID 基点 fail-closed（leave_request.rb 同型）
  def requester_must_belong_to_same_organization
    return if requester_id.nil?
    return if requester&.organization_id == organization_id

    errors.add(:requester, "は同一組織でなければなりません")
  end

  def attendance_record_must_belong_to_same_organization
    return if attendance_record_id.nil?
    return if attendance_record&.organization_id == organization_id

    errors.add(:attendance_record, "は同一組織でなければなりません")
  end
end
```

- [ ] **Step 7: spec を実行して pass を確認**

Run: `bundle exec rspec spec/models/clock_change_request_spec.rb`
Expected: PASS

- [ ] **Step 8: rubocop + コミット**

```bash
bundle exec rubocop --force-exclusion app/models/clock_change_request.rb db/migrate spec/factories/clock_change_requests.rb
git add app/models/clock_change_request.rb db/migrate db/schema.rb spec/models/clock_change_request_spec.rb spec/factories/clock_change_requests.rb
git commit -m "$(cat <<'EOF'
feat: ClockChangeRequest モデル + migration（打刻変更申請・2-3）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: AttendanceHistory の clock_change_approved に actor 必須

**Files:**
- Modify: `app/models/attendance_history.rb`
- Test: `spec/models/attendance_history_spec.rb`

**Interfaces:**
- Produces: `event_type: :clock_change_approved` の `AttendanceHistory` は `actor_id` 必須。

- [ ] **Step 1: 失敗する spec を追記**

`spec/models/attendance_history_spec.rb` の末尾 `end` 前に:

```ruby
  describe "clock_change_approved の actor 必須（2-3）" do
    around { |ex| ActsAsTenant.with_tenant(create(:organization)) { ex.run } }

    it "actor 無しは invalid" do
      record = build(:attendance_history, event_type: :clock_change_approved, actor: nil)
      expect(record).to be_invalid
      expect(record.errors[:actor_id]).to be_present
    end

    it "actor ありは valid" do
      record = build(:attendance_history, event_type: :clock_change_approved,
                                          actor: create(:user, :manager_role))
      expect(record).to be_valid
    end
  end
```

- [ ] **Step 2: fail を確認**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb -e "clock_change_approved"`
Expected: FAIL（actor 無しでも valid）

- [ ] **Step 3: モデルに検証を追記**

`app/models/attendance_history.rb` の `validates :actor_id, presence: true, if: :leave_approved?` の直後:

```ruby
  validates :actor_id, presence: true, if: :clock_change_approved?  # 2-3（不変ゆえ事前防御）
```

- [ ] **Step 4: pass を確認**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + コミット**

```bash
bundle exec rubocop --force-exclusion app/models/attendance_history.rb
git add app/models/attendance_history.rb spec/models/attendance_history_spec.rb
git commit -m "$(cat <<'EOF'
feat: AttendanceHistory の clock_change_approved に actor を必須化（2-3）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: ConflictError + ClockChangeRequests::ApplyApproval + hook

**Files:**
- Modify: `app/services/approvals.rb`（`ConflictError`）
- Create: `app/services/clock_change_requests/apply_approval.rb`
- Modify: `app/models/clock_change_request.rb`（`apply_approval_effects!`）
- Test: `spec/services/clock_change_requests/apply_approval_spec.rb`

**Interfaces:**
- Consumes: `Clockings::Recalculate.call(record:)`、`AttendanceHistory`（clock_change_approved・Task 2）、`AttendanceRecord`（lock/find）。
- Produces: `Approvals::ConflictError < Approvals::Error`。`ClockChangeRequests::ApplyApproval.call(clock_change_request:, acting_user:)`。`ClockChangeRequest#apply_approval_effects!(acting_user:)`。

- [ ] **Step 1: ConflictError を定義**

`app/services/approvals.rb` の `class OverBalanceError < Error; end` の直後に:

```ruby
  class ConflictError < Error; end        # 打刻変更承認時の競合（§7.4・2-3）
```

- [ ] **Step 2: 失敗する service spec を作成**

Create `spec/services/clock_change_requests/apply_approval_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClockChangeRequests::ApplyApproval do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org) }
  let(:pattern) { create(:work_pattern, start_time: "09:00", end_time: "18:00", break_minutes: 60) }
  # clocked_out・JST 10:00 出勤（遅刻）・JST 18:00 退勤
  let(:record) do
    create(:attendance_record, user:, work_pattern: pattern, status: :clocked_out,
           work_date: Date.new(2026, 6, 1),
           clock_in: Time.utc(2026, 6, 1, 1), clock_out: Time.utc(2026, 6, 1, 9))
  end

  def ccr(**attrs)
    create(:clock_change_request, requester: user, attendance_record: record,
           original_clock_in: record.clock_in, original_clock_out: record.clock_out, **attrs)
  end

  def apply(c) = described_class.call(clock_change_request: c, acting_user: approver)

  it "clock_in を JST 09:00 へ修正 → 記録更新 + 再計算（遅刻解消）" do
    apply(ccr(change_type: :clock_in, new_clock_in: Time.utc(2026, 6, 1, 0)))  # JST 09:00
    expect(record.reload.clock_in).to eq(Time.utc(2026, 6, 1, 0))
    expect(record.is_late).to be false   # 09:00 出勤ゆえ遅刻でない
  end

  it "clock_out のみ変更（clock_in は不変）" do
    apply(ccr(change_type: :clock_out, new_clock_in: nil, new_clock_out: Time.utc(2026, 6, 1, 10)))
    expect(record.reload.clock_out).to eq(Time.utc(2026, 6, 1, 10))
    expect(record.clock_in).to eq(Time.utc(2026, 6, 1, 1))
  end

  it "前後値つき clock_change_approved 履歴を 1 行記録（actor=承認者・source=ccr）" do
    c = ccr(change_type: :clock_in, new_clock_in: Time.utc(2026, 6, 1, 0))
    expect { apply(c) }.to change { AttendanceHistory.where(event_type: :clock_change_approved).count }.by(1)
    h = AttendanceHistory.find_by(event_type: :clock_change_approved)
    expect(h).to have_attributes(actor_id: approver.id, user_id: user.id,
                                 previous_clock_in: Time.utc(2026, 6, 1, 1),
                                 new_clock_in: Time.utc(2026, 6, 1, 0),
                                 previous_is_late: true, new_is_late: false)
  end

  it "status は不変（clocked_out のまま）" do
    apply(ccr(change_type: :clock_in, new_clock_in: Time.utc(2026, 6, 1, 0)))
    expect(record.reload.status).to eq("clocked_out")
  end

  describe "§7.4 競合チェック" do
    it "original が現在と一致すれば承認成功（未変更で偽 ConflictError を出さない）" do
      expect { apply(ccr(new_clock_in: Time.utc(2026, 6, 1, 0))) }.not_to raise_error
    end

    it "申請後に記録が変わっていたら ConflictError + rollback（記録/履歴不変）" do
      c = ccr(new_clock_in: Time.utc(2026, 6, 1, 0))
      record.update_column(:clock_in, Time.utc(2026, 6, 1, 2))   # 申請後に第三者が変更（JST 11:00）
      expect { apply(c) }.to raise_error(Approvals::ConflictError)
      expect(record.reload.clock_in).to eq(Time.utc(2026, 6, 1, 2))   # 巻き戻し（CCR の変更は入らない）
      expect(AttendanceHistory.where(event_type: :clock_change_approved).count).to eq(0)
    end
  end
end
```

- [ ] **Step 3: fail を確認**

Run: `bundle exec rspec spec/services/clock_change_requests/apply_approval_spec.rb`
Expected: FAIL（`ClockChangeRequests::ApplyApproval` 未定義 = `NameError`）

- [ ] **Step 4: ApplyApproval を作成**

Create `app/services/clock_change_requests/apply_approval.rb`:

```ruby
# frozen_string_literal: true

module ClockChangeRequests
  # 打刻変更承認の副作用本体（SPEC §6.3・§7.4・2-3 設計 §2）。
  # 呼び出し元: ClockChangeRequest#apply_approval_effects!（Approvals::Approve の with_lock 内・同一 tx）。
  # 内側で rescue しない — ConflictError は raise 伝播し承認ごと atomic rollback。
  # 処理順: ① FOR UPDATE ロック ② §7.4 競合チェック ③ 時刻更新（status 不変）④ §5 再計算 ⑤ 前後値 history。
  class ApplyApproval
    def self.call(clock_change_request:, acting_user:) = new(clock_change_request:, acting_user:).call

    def initialize(clock_change_request:, acting_user:)
      @ccr = clock_change_request
      @acting_user = acting_user
    end

    def call
      ActsAsTenant.with_tenant(@ccr.organization) do
        record = AttendanceRecord.lock.find(@ccr.attendance_record_id)   # FOR UPDATE
        check_conflict!(record)
        before = snapshot(record)
        apply_times!(record)
        record.save!
        Clockings::Recalculate.call(record:) if record.clock_out.present?
        record_history(record, before)
      end
      @ccr
    end

    private

    # §7.4: snapshot（Create 時の original_*）と現記録の厳密照合。DB 由来値同士の == 比較
    def check_conflict!(record)
      return if record.clock_in == @ccr.original_clock_in &&
                record.clock_out == @ccr.original_clock_out

      raise Approvals::ConflictError
    end

    def apply_times!(record)
      record.clock_in  = @ccr.new_clock_in  if @ccr.change_clock_in? || @ccr.change_both?
      record.clock_out = @ccr.new_clock_out if @ccr.change_clock_out? || @ccr.change_both?
    end

    # 前後値の「前」（apply 前に捕捉）。AR#slice は string キーの hash を返す
    def snapshot(record)
      record.slice("clock_in", "clock_out", "status",
                   "is_late", "late_minutes", "is_early_leave", "early_leave_minutes")
    end

    def record_history(record, before)
      record.reload   # recalc 後の確定値（after）
      AttendanceHistory.create!(
        user_id: record.user_id, actor: @acting_user, source: @ccr,
        event_type: :clock_change_approved, event_date: record.work_date,
        previous_clock_in: before["clock_in"], new_clock_in: record.clock_in,
        previous_clock_out: before["clock_out"], new_clock_out: record.clock_out,
        previous_status: before["status"], new_status: record.status,
        previous_is_late: before["is_late"], new_is_late: record.is_late,
        previous_late_minutes: before["late_minutes"], new_late_minutes: record.late_minutes,
        previous_is_early_leave: before["is_early_leave"], new_is_early_leave: record.is_early_leave,
        previous_early_leave_minutes: before["early_leave_minutes"],
        new_early_leave_minutes: record.early_leave_minutes
      )
    end
  end
end
```

- [ ] **Step 5: pass を確認**

Run: `bundle exec rspec spec/services/clock_change_requests/apply_approval_spec.rb`
Expected: PASS

- [ ] **Step 6: ClockChangeRequest に hook 実装を追加 + spec**

`spec/models/clock_change_request_spec.rb` の末尾 `end` 前に:

```ruby
  describe "#apply_approval_effects!（2-3・委譲）" do
    it "ApplyApproval へ委譲する" do
      c = build(:clock_change_request, requester: user, attendance_record: record)
      actor = build(:user, :manager_role)
      expect(ClockChangeRequests::ApplyApproval).to receive(:call).with(clock_change_request: c, acting_user: actor)
      c.apply_approval_effects!(acting_user: actor)
    end
  end
```

`app/models/clock_change_request.rb` の `private` の直前（public メソッドとして）に:

```ruby
  # 承認確定時の副作用（§6.3・§13.6）。Approve エンジンの with_lock 内・同一 tx で呼ばれる。
  def apply_approval_effects!(acting_user:)
    ClockChangeRequests::ApplyApproval.call(clock_change_request: self, acting_user:)
  end
```

- [ ] **Step 7: 全 spec の pass を確認**

Run: `bundle exec rspec spec/services/clock_change_requests/apply_approval_spec.rb spec/models/clock_change_request_spec.rb`
Expected: PASS

- [ ] **Step 8: rubocop + brakeman + コミット**

```bash
bundle exec rubocop --force-exclusion app/services/clock_change_requests/apply_approval.rb app/services/approvals.rb app/models/clock_change_request.rb
bin/brakeman --no-pager
git add app/services/clock_change_requests/apply_approval.rb app/services/approvals.rb app/models/clock_change_request.rb spec/services/clock_change_requests/apply_approval_spec.rb spec/models/clock_change_request_spec.rb
git commit -m "$(cat <<'EOF'
feat: ClockChangeRequests::ApplyApproval — 競合チェック + 時刻更新 + 再計算 + 前後値履歴（2-3）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: ClockChangeRequests::Create

**Files:**
- Create: `app/services/clock_change_requests/create.rb`
- Test: `spec/services/clock_change_requests/create_spec.rb`

**Interfaces:**
- Consumes: `Approvals::Start.call(approvable)`。
- Produces: `ClockChangeRequests::Create.call(requester:, attendance_record:, change_type:, new_clock_in:, new_clock_out:, reason:) → ClockChangeRequest`。`original_clock_in/out` を記録から snapshot。

- [ ] **Step 1: 失敗する spec を作成**

Create `spec/services/clock_change_requests/create_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClockChangeRequests::Create do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:boss) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org, manager: boss) }   # route: [boss]（単段）
  let(:record) do
    create(:attendance_record, :done, user:, work_date: Date.new(2026, 6, 1),
           clock_in: Time.utc(2026, 6, 1, 1), clock_out: Time.utc(2026, 6, 1, 9))
  end

  def call
    described_class.call(requester: user, attendance_record: record, change_type: "clock_in",
                         new_clock_in: Time.utc(2026, 6, 1, 0), new_clock_out: nil, reason: "修正")
  end

  it "original_* を記録から snapshot する（サーバ権威）" do
    ccr = call
    expect(ccr.original_clock_in).to eq(record.clock_in)
    expect(ccr.original_clock_out).to eq(record.clock_out)
  end

  it "Approvals::Start を起動し pending assignment を生成する" do
    ccr = call
    expect(ccr.approval_assignments.where(decision: :pending)).to be_present
  end

  it "RouteError 時は CCR / assignment 双方とも作られない（manager 未設定）" do
    orphan = create(:user, organization: org)   # manager 無し
    orphan_record = create(:attendance_record, :done, user: orphan, work_date: Date.new(2026, 6, 2))
    expect {
      described_class.call(requester: orphan, attendance_record: orphan_record, change_type: "clock_in",
                           new_clock_in: Time.utc(2026, 6, 2, 0), new_clock_out: nil, reason: "x")
    }.to raise_error(Approvals::RouteError)
    expect(ClockChangeRequest.count).to eq(0)
  end
end
```

- [ ] **Step 2: fail を確認**

Run: `bundle exec rspec spec/services/clock_change_requests/create_spec.rb`
Expected: FAIL（`ClockChangeRequests::Create` 未定義）

- [ ] **Step 3: Create を作成**

Create `app/services/clock_change_requests/create.rb`:

```ruby
# frozen_string_literal: true

module ClockChangeRequests
  # 打刻変更申請の作成（2-3 設計 §3.1）。1 tx で CCR 作成 + 承認エンジン起動。
  # original_* は対象記録から snapshot（サーバ権威・§7.4 競合チェック用）。
  # requester は呼び出し側が current_user を渡す（params 由来の id を受けない）。
  class Create
    def self.call(requester:, attendance_record:, change_type:, new_clock_in:, new_clock_out:, reason:)
      new(requester:, attendance_record:, change_type:, new_clock_in:, new_clock_out:, reason:).call
    end

    def initialize(requester:, attendance_record:, change_type:, new_clock_in:, new_clock_out:, reason:)
      @requester = requester
      @attendance_record = attendance_record
      @change_type = change_type
      @new_clock_in = new_clock_in
      @new_clock_out = new_clock_out
      @reason = reason
    end

    def call
      ActiveRecord::Base.transaction do
        ccr = ClockChangeRequest.create!(
          requester: @requester, attendance_record: @attendance_record,
          change_type: @change_type, reason: @reason,
          new_clock_in: @new_clock_in, new_clock_out: @new_clock_out,
          original_clock_in: @attendance_record.clock_in,     # snapshot（サーバ権威）
          original_clock_out: @attendance_record.clock_out
        )
        Approvals::Start.call(ccr)   # ルート解決 + pending assignment（既存エンジン）
        ccr
      end
    end
  end
end
```

- [ ] **Step 4: pass を確認**

Run: `bundle exec rspec spec/services/clock_change_requests/create_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + コミット**

```bash
bundle exec rubocop --force-exclusion app/services/clock_change_requests/create.rb
git add app/services/clock_change_requests/create.rb spec/services/clock_change_requests/create_spec.rb
git commit -m "$(cat <<'EOF'
feat: ClockChangeRequests::Create — original_* snapshot + 承認エンジン起動（2-3）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: ClockChangeRequestPolicy

**Files:**
- Create: `app/policies/clock_change_request_policy.rb`
- Test: `spec/policies/clock_change_request_policy_spec.rb`

**Interfaces:**
- Produces: `ClockChangeRequestPolicy`（`index?`/`new?`/`create?` = `user.present?`・`cancel?` = 本人 + `applying?`・`Scope` = 自分の申請）。

- [ ] **Step 1: 失敗する spec を作成**

Create `spec/policies/clock_change_request_policy_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClockChangeRequestPolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:owner) { create(:user, organization: org) }
  let(:other) { create(:user, organization: org) }
  let(:ar) { create(:attendance_record, :done, user: owner) }
  let(:record) { create(:clock_change_request, requester: owner, attendance_record: ar) }

  context "本人" do
    let(:actor) { owner }
    it { is_expected.to permit_actions(%i[index new create cancel]) }
  end

  context "第三者" do
    let(:actor) { other }
    it { is_expected.to forbid_actions(%i[cancel]) }
  end

  context "terminal（canceled）には cancel 不可" do
    let(:actor) { owner }
    before { record.cancel! }
    it { is_expected.to forbid_actions(%i[cancel]) }
  end

  describe "Scope" do
    it "自分の申請のみ" do
      mine = record
      others_ar = create(:attendance_record, :done, user: other)
      create(:clock_change_request, requester: other, attendance_record: others_ar)
      resolved = ClockChangeRequestPolicy::Scope.new(owner, ClockChangeRequest).resolve
      expect(resolved).to contain_exactly(mine)
    end
  end
end
```

- [ ] **Step 2: fail を確認**

Run: `bundle exec rspec spec/policies/clock_change_request_policy_spec.rb`
Expected: FAIL（`ClockChangeRequestPolicy` 未定義）

- [ ] **Step 3: Policy を作成**

Create `app/policies/clock_change_request_policy.rb`:

```ruby
# frozen_string_literal: true

# 打刻変更申請の認可（2-3 設計 §3.3・LeaveRequestPolicy 同型）。requester=current_user 固定ゆえ本人前提。
class ClockChangeRequestPolicy < ApplicationPolicy
  def index? = user.present?
  def new? = user.present?
  def create? = user.present?

  def cancel? = record.requester_id == user.id && record.applying?

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(requester_id: user.id)
  end
end
```

- [ ] **Step 4: pass を確認**

Run: `bundle exec rspec spec/policies/clock_change_request_policy_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + コミット**

```bash
bundle exec rubocop --force-exclusion app/policies/clock_change_request_policy.rb
git add app/policies/clock_change_request_policy.rb spec/policies/clock_change_request_policy_spec.rb
git commit -m "$(cat <<'EOF'
feat: ClockChangeRequestPolicy（本人 Scope・cancel 本人 applying のみ・2-3）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: 申請 UI（controller + routes + views）

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/clock_change_requests_controller.rb`
- Create: `app/views/clock_change_requests/{new,_form,index}.html.erb`
- Create: `app/javascript/controllers/reason_chips_controller.js`
- Test: `spec/requests/clock_change_requests_spec.rb`

**Interfaces:**
- Consumes: `ClockChangeRequests::Create`、`Approvals::Cancel`、`ClockChangeRequestPolicy`。
- Produces: `GET /clock_change_requests`・`GET /clock_change_requests/new?attendance_record_id=`・`POST /clock_change_requests`・`PATCH /clock_change_requests/:id/cancel`。

- [ ] **Step 1: ルートを追加**

`config/routes.rb` の `resources :leave_requests do ... end` ブロックの直後に:

```ruby
  resources :clock_change_requests, only: %i[index new create] do
    member { patch :cancel }
  end
```

- [ ] **Step 2: 失敗する request spec を作成**

Create `spec/requests/clock_change_requests_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ClockChangeRequests", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:boss) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role) } }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user, manager: boss) } }
  let!(:record) do
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, :done, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 1), clock_out: Time.utc(2026, 6, 1, 9))
    end
  end

  before { sign_in user }

  describe "GET new" do
    it "自分の記録には新規申請フォームを表示" do
      get new_clock_change_request_url(host: tenant_host(org), attendance_record_id: record.id)
      expect(response).to have_http_status(:ok)
    end

    it "他人の記録は 404" do
      other = ActsAsTenant.with_tenant(org) { create(:user) }
      others_record = ActsAsTenant.with_tenant(org) { create(:attendance_record, :done, user: other) }
      get new_clock_change_request_url(host: tenant_host(org), attendance_record_id: others_record.id)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST create" do
    it "申請を作成し original_* をサーバ snapshot（client 値を無視）" do
      expect {
        post clock_change_requests_url(host: tenant_host(org)),
             params: { clock_change_request: { attendance_record_id: record.id, change_type: "clock_in",
                                               new_clock_in: "2026-06-01T09:00", reason: "修正",
                                               original_clock_in: "1999-01-01T00:00" } }
      }.to change { ActsAsTenant.with_tenant(org) { ClockChangeRequest.count } }.by(1)
      ccr = ActsAsTenant.with_tenant(org) { ClockChangeRequest.last }
      expect(ccr.original_clock_in).to eq(record.clock_in)   # client の 1999 を無視
      expect(ccr.new_clock_in.in_time_zone(org.time_zone).strftime("%H:%M")).to eq("09:00")  # 組織 TZ parse
    end
  end

  describe "PATCH cancel" do
    it "本人申請を取り消す" do
      ccr = ActsAsTenant.with_tenant(org) do
        ClockChangeRequests::Create.call(requester: user, attendance_record: record, change_type: "clock_in",
                                         new_clock_in: Time.utc(2026, 6, 1, 0), new_clock_out: nil, reason: "x")
      end
      patch cancel_clock_change_request_url(ccr, host: tenant_host(org))
      ActsAsTenant.with_tenant(org) { expect(ccr.reload.approval_status).to eq("canceled") }
    end
  end
end
```

- [ ] **Step 3: fail を確認**

Run: `bundle exec rspec spec/requests/clock_change_requests_spec.rb`
Expected: FAIL（controller/ビュー未定義）

- [ ] **Step 4: コントローラを作成**

Create `app/controllers/clock_change_requests_controller.rb`:

```ruby
# frozen_string_literal: true

# 社員の打刻変更申請（2-3 設計 §3.2）。requester=current_user 構造固定。
# ★new_clock_* は組織 TZ で parse（config.time_zone 未設定＝UTC ゆえ Time.zone.parse は不可）。
class ClockChangeRequestsController < ApplicationController
  before_action :set_clock_change_request, only: :cancel

  def index
    authorize ClockChangeRequest
    @clock_change_requests = policy_scope(ClockChangeRequest).order(created_at: :desc)
  end

  def new
    authorize ClockChangeRequest
    # 本人の記録に限定（has_many 経由 + acts_as_tenant default_scope ＝テナント+本人。他人は 404）
    @attendance_record = current_user.attendance_records.find(params[:attendance_record_id])
    @clock_change_request = ClockChangeRequest.new(attendance_record: @attendance_record)
  end

  def create
    authorize ClockChangeRequest
    record = current_user.attendance_records.find(create_params[:attendance_record_id])
    @clock_change_request = ClockChangeRequests::Create.call(
      requester: current_user, attendance_record: record,
      change_type: create_params[:change_type],
      new_clock_in: parse_org_time(create_params[:new_clock_in]),
      new_clock_out: parse_org_time(create_params[:new_clock_out]),
      reason: create_params[:reason]
    )
    redirect_to clock_change_requests_path, status: :see_other, notice: "打刻変更を申請しました"
  rescue Approvals::RouteError
    redirect_to clock_change_requests_path, status: :see_other,
                alert: "申請できません。直属上長が未設定です（管理者にご連絡ください）"
  rescue ActiveRecord::RecordInvalid => e
    @clock_change_request = e.record
    @attendance_record = record
    render :new, status: :unprocessable_entity
  end

  def cancel
    authorize @clock_change_request, :cancel?
    Approvals::Cancel.call(approvable: @clock_change_request, by: current_user)
    redirect_to clock_change_requests_path, status: :see_other, notice: "申請を取り消しました"
  rescue AASM::InvalidTransition
    redirect_to clock_change_requests_path, status: :see_other, alert: "この申請は取り消せません"
  end

  private

  def set_clock_change_request
    @clock_change_request = policy_scope(ClockChangeRequest).find(params[:id])
  end

  # attendance_record_id/original_*/approval_status は受けない（サーバ権威）
  def create_params
    params.require(:clock_change_request).permit(:attendance_record_id, :change_type,
                                                 :new_clock_in, :new_clock_out, :reason)
  end

  # ★組織 TZ で parse（UTC 既定の Time.zone.parse は 9h ズレ）
  def parse_org_time(value)
    return nil if value.blank?

    ActiveSupport::TimeZone[current_user.organization.time_zone].parse(value)
  end
end
```

- [ ] **Step 5: ビューを作成**

Create `app/views/clock_change_requests/new.html.erb`:

```erb
<%# app/views/clock_change_requests/new.html.erb %>
<h1 class="text-xl font-bold mb-4">打刻変更を申請</h1>
<% tz = current_user.organization.time_zone %>
<div class="mb-3 text-sm text-gray-600" data-current-times>
  対象 <%= @attendance_record.work_date %>
  ：現在 出勤 <%= @attendance_record.clock_in&.in_time_zone(tz)&.strftime("%H:%M") %>
  / 退勤 <%= @attendance_record.clock_out&.in_time_zone(tz)&.strftime("%H:%M") %>
</div>
<%= render "form", clock_change_request: @clock_change_request, attendance_record: @attendance_record %>
```

Create `app/views/clock_change_requests/_form.html.erb`:

```erb
<%# app/views/clock_change_requests/_form.html.erb %>
<%= form_with model: clock_change_request, url: clock_change_requests_path, method: :post,
              data: { controller: "reason-chips" } do |f| %>
  <% if clock_change_request.errors.any? %>
    <div class="text-red-600 mb-2"><%= clock_change_request.errors.full_messages.join("。") %></div>
  <% end %>
  <%= f.hidden_field :attendance_record_id, value: attendance_record.id %>
  <div class="mb-2">
    <%= f.label :change_type, "変更対象" %>
    <%= f.select :change_type, [["出勤時刻", "clock_in"], ["退勤時刻", "clock_out"], ["両方", "both"]] %>
  </div>
  <div class="mb-2">
    <%= f.label :new_clock_in, "新しい出勤時刻" %>
    <%= f.datetime_field :new_clock_in %>
  </div>
  <div class="mb-2">
    <%= f.label :new_clock_out, "新しい退勤時刻" %>
    <%= f.datetime_field :new_clock_out %>
  </div>
  <div class="mb-2">
    <%= f.label :reason, "理由" %>
    <%= f.text_area :reason, data: { "reason-chips-target": "reason" } %>
    <div class="mt-1 flex gap-1 flex-wrap">
      <% ReasonTemplate.where(active: true, applies_to: [:clock_change, :both]).each do |tpl| %>
        <button type="button" class="text-xs border rounded px-2 py-1"
                data-action="reason-chips#apply"
                data-reason-chips-text-param="<%= tpl.template_text %>"><%= tpl.label %></button>
      <% end %>
    </div>
  </div>
  <%= f.submit "申請する", class: "bg-blue-600 text-white px-4 py-2 rounded" %>
<% end %>
```

Create `app/views/clock_change_requests/index.html.erb`:

```erb
<%# app/views/clock_change_requests/index.html.erb %>
<h1 class="text-xl font-bold mb-4">打刻変更申請</h1>
<% tz = current_user.organization.time_zone %>
<% if @clock_change_requests.empty? %>
  <p class="text-gray-500">申請はありません。</p>
<% else %>
  <% @clock_change_requests.each do |ccr| %>
    <div class="border rounded p-3 mb-2 text-sm">
      <%= ccr.attendance_record&.work_date %> ／ <%= ccr.change_type %> ／ <%= ccr.approval_status %>
      <% if ccr.applying? %>
        <%= button_to "取消", cancel_clock_change_request_path(ccr), method: :patch,
              class: "text-xs underline", form_class: "inline" %>
      <% end %>
    </div>
  <% end %>
<% end %>
```

Create `app/javascript/controllers/reason_chips_controller.js`:

```javascript
import { Controller } from "@hotwired/stimulus"

// 理由テンプレートチップ → textarea に追記（2-3・最小）
export default class extends Controller {
  static targets = ["reason"]

  apply(event) {
    const text = event.params.text
    const ta = this.reasonTarget
    ta.value = ta.value ? `${ta.value}\n${text}` : text
  }
}
```

- [ ] **Step 6: pass を確認**

Run: `bundle exec rspec spec/requests/clock_change_requests_spec.rb`
Expected: PASS

- [ ] **Step 7: rubocop + brakeman + コミット**

```bash
bundle exec rubocop --force-exclusion app/controllers/clock_change_requests_controller.rb
bin/brakeman --no-pager
git add config/routes.rb app/controllers/clock_change_requests_controller.rb app/views/clock_change_requests app/javascript/controllers/reason_chips_controller.js spec/requests/clock_change_requests_spec.rb
git commit -m "$(cat <<'EOF'
feat: 打刻変更申請 UI（controller/routes/form・組織 TZ parse・Cancel 再利用・2-3）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: インボックス CCR 行 + ConflictError rescue

**Files:**
- Create: `app/components/approvals/clock_change_request_row_component.{rb,html.erb}`
- Modify: `app/views/approval_assignments/index.html.erb`（`when ClockChangeRequest`）
- Modify: `app/controllers/approval_assignments_controller.rb`（`ConflictError` rescue）
- Test: `spec/requests/approval_assignments_spec.rb`（追記）

**Interfaces:**
- Consumes: `Approvals::Approve`（CCR・既存呼び出し）、`Approvals::ConflictError`（Task 3）、`Approvable#single_stage?`。
- Produces: `Approvals::ClockChangeRequestRowComponent`。インボックスが CCR を型別描画し、競合承認を flash で握る。

- [ ] **Step 1: 失敗する request spec を追記**

`spec/requests/approval_assignments_spec.rb` の最終 `end` の前に:

```ruby
  describe "CCR（打刻変更）の承認（2-3）" do
    let!(:ccr_record) do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, :done, user: emp, work_date: Date.new(2026, 6, 1),
               clock_in: Time.utc(2026, 6, 1, 1), clock_out: Time.utc(2026, 6, 1, 9),
               work_pattern: create(:work_pattern))
      end
    end
    let!(:ccr) do
      ActsAsTenant.with_tenant(org) do
        ClockChangeRequests::Create.call(requester: emp, attendance_record: ccr_record,
                                         change_type: "clock_in", new_clock_in: Time.utc(2026, 6, 1, 0),
                                         new_clock_out: nil, reason: "修正")
      end
    end
    def ccr_assignment(pos) = ActsAsTenant.with_tenant(org) { ccr.approval_assignments.find_by(position: pos) }

    it "インボックスに CCR 行が型別描画される" do
      sign_in boss
      get approval_assignments_url(host: tenant_host(org))
      expect(response.body).to include("打刻変更")
    end

    it "承認で記録時刻更新 + 履歴記録（一周）" do
      sign_in boss
      patch approve_approval_assignment_url(ccr_assignment(1), host: tenant_host(org))
      sign_in dept
      patch approve_approval_assignment_url(ccr_assignment(2), host: tenant_host(org))
      ActsAsTenant.with_tenant(org) do
        expect(ccr_record.reload.clock_in).to eq(Time.utc(2026, 6, 1, 0))
        expect(AttendanceHistory.where(event_type: :clock_change_approved).count).to eq(1)
      end
    end

    it "競合（申請後に記録変更）承認で alert + DB 無変化" do
      sign_in boss
      patch approve_approval_assignment_url(ccr_assignment(1), host: tenant_host(org))
      ActsAsTenant.with_tenant(org) { ccr_record.update_column(:clock_in, Time.utc(2026, 6, 1, 2)) }
      sign_in dept
      patch approve_approval_assignment_url(ccr_assignment(2), host: tenant_host(org))
      ActsAsTenant.with_tenant(org) do
        expect(ccr.reload.approval_status).to eq("applying")           # rollback
        expect(ccr_record.reload.clock_in).to eq(Time.utc(2026, 6, 1, 2))
        expect(AttendanceHistory.where(event_type: :clock_change_approved).count).to eq(0)
      end
      follow_redirect!
      expect(response.body).to include("一致しません")
    end
  end
```

> 注: `org` / `emp` / `boss` / `dept` は既存 `approval_assignments_spec.rb` 冒頭の let を流用（route: emp→boss→dept）。新規 let は本 describe 内のみ。

- [ ] **Step 2: fail を確認**

Run: `bundle exec rspec spec/requests/approval_assignments_spec.rb -e "CCR（打刻変更）"`
Expected: FAIL（CCR 行未描画 = "打刻変更" 不在／ConflictError 未 rescue で 500）

- [ ] **Step 3: 行コンポーネントを作成**

Create `app/components/approvals/clock_change_request_row_component.rb`:

```ruby
# frozen_string_literal: true

module Approvals
  # 承認インボックスの ClockChangeRequest 行（2-3 設計 §4）。approvable_type 別描画の 2 つ目。
  class ClockChangeRequestRowComponent < ViewComponent::Base
    CHANGE_LABELS = { "clock_in" => "出勤時刻", "clock_out" => "退勤時刻", "both" => "両方" }.freeze

    def initialize(assignment:)
      @assignment = assignment
      @ccr = assignment.approvable
    end

    def stage_label
      @ccr.single_stage? ? "単段（独立性なし）" : "第 #{@assignment.position} 段階"
    end

    def change_type_label = CHANGE_LABELS.fetch(@ccr.change_type, @ccr.change_type)

    def fmt(time) = time&.in_time_zone(@ccr.organization.time_zone)&.strftime("%H:%M")
  end
end
```

Create `app/components/approvals/clock_change_request_row_component.html.erb`:

```erb
<div class="border rounded p-4 mb-3" data-approval-row>
  <div class="font-medium"><%= @ccr.requester.name %> ／ 打刻変更（<%= change_type_label %>）</div>
  <div class="text-sm text-gray-600">
    対象 <%= @ccr.attendance_record.work_date %>：
    出勤 <%= fmt(@ccr.original_clock_in) %> → <%= fmt(@ccr.new_clock_in) || "（変更なし）" %>
    ／ 退勤 <%= fmt(@ccr.original_clock_out) %> → <%= fmt(@ccr.new_clock_out) || "（変更なし）" %>
    <span class="ml-2"><%= stage_label %></span>
  </div>
  <% if @ccr.reason.present? %>
    <div class="text-sm text-gray-500 mt-1"><%= @ccr.reason %></div>
  <% end %>
  <div class="mt-2 flex flex-wrap items-center gap-2">
    <%= button_to "承認", approve_approval_assignment_path(@assignment), method: :patch,
          class: "bg-blue-600 text-white px-3 py-1 rounded text-sm",
          data: { turbo_confirm: "承認しますか？" } %>
    <%= form_with url: reject_approval_assignment_path(@assignment), method: :patch,
          class: "flex items-center gap-1" do |f| %>
      <%= f.text_field :comment, placeholder: "却下理由（必須）", class: "border rounded px-2 py-1 text-sm" %>
      <%= f.submit "却下", class: "bg-gray-200 px-3 py-1 rounded text-sm" %>
    <% end %>
  </div>
</div>
```

- [ ] **Step 4: index ビューに dispatch を追加**

`app/views/approval_assignments/index.html.erb` の `<% when LeaveRequest %>` ブロックの直後（`<% end %>`（case）の前）に:

```erb
      <% when ClockChangeRequest %>
        <%= render Approvals::ClockChangeRequestRowComponent.new(assignment:) %>
```

- [ ] **Step 5: controller に ConflictError rescue を追加**

`app/controllers/approval_assignments_controller.rb` の `approve` アクションの `rescue Approvals::OverBalanceError` ブロックの直後に:

```ruby
  rescue Approvals::ConflictError
    redirect_to approval_assignments_path, status: :see_other,
                alert: "変更前時刻が現在の記録と一致しません（申請者へ再申請をご依頼ください）"
```

- [ ] **Step 6: pass を確認**

Run: `bundle exec rspec spec/requests/approval_assignments_spec.rb`
Expected: PASS（既存 LeaveRequest の example も緑）

- [ ] **Step 7: rubocop + brakeman + コミット**

```bash
bundle exec rubocop --force-exclusion app/components/approvals/clock_change_request_row_component.rb app/controllers/approval_assignments_controller.rb
bin/brakeman --no-pager
git add app/components/approvals/clock_change_request_row_component.rb app/components/approvals/clock_change_request_row_component.html.erb app/views/approval_assignments/index.html.erb app/controllers/approval_assignments_controller.rb spec/requests/approval_assignments_spec.rb
git commit -m "$(cat <<'EOF'
feat: 承認インボックスに CCR 行 + ConflictError rescue（型別描画・2-3）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: ドキュメント更新（ROADMAP）

**Files:**
- Modify: `docs/ROADMAP.md`

**Interfaces:** なし（docs only）。

- [ ] **Step 1: ROADMAP の 2-3 行を完了に更新**

`docs/ROADMAP.md` の 2-3 行（`- [ ] **2-3 ClockChangeRequest**: ...`）を以下に置換（`<PR番号>` は PR 作成後に確定）:

```markdown
- [x] **2-3 ClockChangeRequest**: 打刻変更申請（clock_in/clock_out/both）・`ClockChangeRequests::Create`（original_* snapshot）・`ApplyApproval`（§7.4 競合チェック→時刻更新→§5 再計算→前後値 `AttendanceHistory(clock_change_approved)`）・インボックス CCR 行（型別描画）・組織 TZ 入力 parse。**new_entry は absent 依存ゆえ 4-2 へ後置**（PR #<PR番号>）
```

- [ ] **Step 2: docs のみコミット**

```bash
git add docs/ROADMAP.md
git commit -m "$(cat <<'EOF'
docs: ROADMAP 2-3 完了マーク（new_entry は 4-2 後置）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## 最終検証（PR 前・`/preflight` 相当）

- [ ] **全 spec 緑:** `bin/rails db:test:prepare && bundle exec rspec`
- [ ] **rubocop 全体:** `bundle exec rubocop`
- [ ] **brakeman:** `bin/brakeman --no-pager`
- [ ] **`/preflight`** スキルを実行
- [ ] **レビュー:** `tenant-isolation-reviewer`（migration/model/service）を merge 前に
- [ ] **PR 作成:** ROADMAP の `<PR番号>` を確定値へ。`gh auth switch -u kei1110` を確認
