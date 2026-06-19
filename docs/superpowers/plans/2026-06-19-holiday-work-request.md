# Phase 2-4 HolidayWorkRequest（休日出勤申請）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 社員が休日出勤を申請 → 2 段承認 → 代休残高 +1 ＋ is_holiday_work 連動まで一周させる（三つ目の承認対象 HolidayWorkRequest を投入）。

**Architecture:** 2-3 ClockChangeRequest の骨格（model + `Approvable` hook + Create + ApplyApproval + Controller + Policy + 申請 UI + 型別インボックス行）を流用。固有ロジックは ① is_holiday_work の双方向連動（承認＝予約／打刻＝付与）② 代休残高 +1 と消費側の `balance_tracked?` 対称化 ③ 代休限定（振替は後置）。承認エンジン（Start/Approve/Reject/Cancel）は対象非依存ゆえ無改修で再利用。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / acts_as_tenant（行レベルテナント）/ Pundit / AASM（Approvable concern）/ ViewComponent / RSpec + FactoryBot。

設計典拠: `docs/superpowers/specs/2026-06-19-holiday-work-request-design.md`（brainstorm + 6 視点 + Codex 敵対レビュー反映済）。

## Global Constraints

- **テナント安全（SPEC §3.6）**: models は `acts_as_tenant(:organization)`。サービス/ジョブ経路は `ActsAsTenant.with_tenant(org)` で自己完結。複合 FK は `[organization_id, id]` 標的。組織スコープ検証は ID 基点 fail-closed（`return if xxx_id.nil?` → `return if assoc&.organization_id == organization_id` → `errors.add`）
- **migration 経由のみ**: `db/schema.rb` の手編集は hook で禁止。スキーマ変更は必ず migration。`bin/rails db:migrate` 後に schema.rb が自動更新される
- **commit identity**: kei1110 `<eoh2145@gmail.com>`・remote `github-kei1110`（local config 済）。commit message 末尾に `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **rubocop**: ファイル明示渡しは `bundle exec rubocop --force-exclusion <files>`（`--force-exclusion` 必須・db/schema.rb 偽 FAIL 回避）
- **enum 整数凍結**: `approval_status`（applying:0/approved:1/rejected:2/canceled:3）は append-only。partial index の `where: "approval_status IN (0, 1)"` はこの整数に依存
- **RecordNotUnique は PG tx 全体を aborted 化**: 外側 `with_lock`（`Approvals::Approve`）内の create は `transaction(requires_new: true)` savepoint で隔離する（隔離しないと後続 `update!` が `PG::InFailedSqlTransaction` で落ちる）
- **各ステップ完了ごとに即コミット**（サブエージェント中断対策）。探索で触った不要編集は revert してから報告
- **完了条件の検証コマンド**: `bundle exec rspec`・`bundle exec rubocop --force-exclusion <files>`、app/ に触れたら `bin/brakeman --no-pager`

---

## File Structure

**新規作成:**
- `db/migrate/<ts>_create_holiday_work_requests.rb` — HWR テーブル（複合 FK・partial unique）
- `db/migrate/<ts>_add_is_holiday_work_to_attendance_records.rb` — is_holiday_work カラム
- `app/models/holiday_work_request.rb` — HWR モデル（Approvable・検証・hook）
- `app/services/holiday_work_requests/create.rb` — 作成 + 承認エンジン起動
- `app/services/holiday_work_requests/apply_approval.rb` — 承認副作用（再検証 + balance +1 + flag）
- `app/policies/holiday_work_request_policy.rb` — 認可（本人 Scope・cancel）
- `app/controllers/holiday_work_requests_controller.rb` — index/new/create/cancel
- `app/views/holiday_work_requests/{_form,index,new}.html.erb` — 申請 UI
- `app/components/approvals/holiday_work_request_row_component.rb` + `.html.erb` — インボックス行
- `spec/factories/holiday_work_requests.rb` — factory
- `spec/models/holiday_work_request_spec.rb` / `spec/services/holiday_work_requests/{create,apply_approval}_spec.rb` / `spec/policies/holiday_work_request_policy_spec.rb` / `spec/requests/holiday_work_requests_spec.rb`

**修正:**
- `app/models/leave_type.rb` — `balance_tracked?` 述語
- `app/models/user.rb` — `has_many :holiday_work_requests` + `holiday_work_reserved_on?`
- `app/services/leave_requests/apply_approval.rb` — `paid_leave?` → `balance_tracked?`
- `app/services/clockings/{clock_in,proxy_clock_in}.rb` — is_holiday_work 連動
- `app/views/approval_assignments/index.html.erb` — HWR 分岐
- `config/routes.rb` — `resources :holiday_work_requests`
- `config/locales/ja.yml` — HWR i18n
- `docs/ROADMAP.md` — 2-4 完了マーク + backlog

依存順: Task 1（balance_tracked?）→ 2（model）→ 3（カラム+述語）→ 4（ApplyApproval）→ 5（消費側回帰）→ 6（Create）→ 7（打刻連動）→ 8（Policy）→ 9（Controller+UI）→ 10（インボックス）→ 11（docs）。

---

## Task 1: `LeaveType#balance_tracked?` 述語

**Files:**
- Modify: `app/models/leave_type.rb`
- Test: `spec/models/leave_type_spec.rb`

**Interfaces:**
- Produces: `LeaveType#balance_tracked? -> Boolean`（`paid_leave? || compensatory_leave?`）。Task 4（HWR ApplyApproval）と Task 5（LeaveRequests ApplyApproval）が消費

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/leave_type_spec.rb` に追記（無ければ新規。冒頭は `require "rails_helper"` + `RSpec.describe LeaveType do` + テナント around）:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveType do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  describe "#balance_tracked?" do
    def lt(system_type:, paid_leave:)
      build(:leave_type, organization: org, system_type:, paid_leave:)
    end

    it "paid_leave=true は system_type 不問で true" do
      expect(lt(system_type: :annual, paid_leave: true)).to be_balance_tracked
      expect(lt(system_type: :other,  paid_leave: true)).to be_balance_tracked
    end

    it "compensatory_leave は paid_leave=false でも true（D2 新挙動）" do
      expect(lt(system_type: :compensatory_leave, paid_leave: false)).to be_balance_tracked
    end

    it "substitute_holiday かつ paid_leave=false は false（v1 デッド項除外）" do
      expect(lt(system_type: :substitute_holiday, paid_leave: false)).not_to be_balance_tracked
    end

    it "substitute_holiday かつ paid_leave=true は true（Codex C3・述語列挙では閉じない）" do
      expect(lt(system_type: :substitute_holiday, paid_leave: true)).to be_balance_tracked
    end

    it "annual/child_care/paternity_leave/other は paid_leave=false なら false" do
      %i[annual child_care paternity_leave other].each do |st|
        expect(lt(system_type: st, paid_leave: false)).not_to be_balance_tracked
      end
    end
  end
end
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `bundle exec rspec spec/models/leave_type_spec.rb -e balance_tracked`
Expected: FAIL（`undefined method 'balance_tracked?'`）

- [ ] **Step 3: 最小実装**

`app/models/leave_type.rb` の `validates :system_type, presence: true` の後（`end` の前）に追記:

```ruby
  # 残高で管理する種別の述語。付与（HWR 承認）・消費（LeaveRequest 承認）の両方がこれで分岐。
  # paid_leave は admin 設定の boolean 列（有給消化系）、compensatory_leave は system_type enum（代償休暇）。
  # v1 は振替（substitute_holiday）を述語に列挙しない＝HWR が代休限定で真を返す経路が無いデッド項を作らない。
  # 注意: paid_leave? 単独でも true ゆえ、admin が振替種別に paid_leave を立てれば列挙の有無に関わらず true。
  def balance_tracked? = paid_leave? || compensatory_leave?
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/models/leave_type_spec.rb -e balance_tracked`
Expected: PASS（5 examples）

- [ ] **Step 5: コミット**

```bash
bundle exec rubocop --force-exclusion app/models/leave_type.rb spec/models/leave_type_spec.rb
git add app/models/leave_type.rb spec/models/leave_type_spec.rb
git commit -m "feat: LeaveType#balance_tracked?（代休付与=消費の対称化述語・2-4 D2）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

> **注**: `:leave_type` factory に `paid_leave` 属性が無い場合は `spec/factories/leave_types.rb` を確認し、`paid_leave { false }` を default に追加（既存テスト不変を確認）。`build(:leave_type, paid_leave: true)` が通ることを担保。

---

## Task 2: `HolidayWorkRequest` モデル + migration + factory

**Files:**
- Create: `db/migrate/<ts>_create_holiday_work_requests.rb`
- Create: `app/models/holiday_work_request.rb`
- Create: `spec/factories/holiday_work_requests.rb`
- Test: `spec/models/holiday_work_request_spec.rb`

**Interfaces:**
- Consumes: `Approvable`（approval_status enum + AASM）・`CompanyCalendarResolver#day_type(date) -> Symbol`
- Produces: `HolidayWorkRequest`（`requester`/`compensation_leave_type`/`work_date`/`reason`/`approval_status`・`apply_approval_effects!` は Task 4 で実装）

- [ ] **Step 1: migration を生成**

Run: `bin/rails generate migration CreateHolidayWorkRequests`
生成された `db/migrate/<ts>_create_holiday_work_requests.rb` を以下で**全置換**:

```ruby
# frozen_string_literal: true

class CreateHolidayWorkRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :holiday_work_requests do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :requester_id, null: false
      t.date :work_date, null: false
      t.bigint :compensation_leave_type_id, null: false
      t.text :reason
      t.integer :approval_status, null: false, default: 0
      t.timestamps
    end

    add_index :holiday_work_requests, %i[organization_id id], unique: true
    add_index :holiday_work_requests, %i[organization_id requester_id approval_status],
              name: "idx_hwr_requester_status"
    # 同一日重複禁止（applying:0 / approved:1 のみ・canceled/rejected 後の再申請は許可）
    add_index :holiday_work_requests, %i[organization_id requester_id work_date],
              unique: true, where: "approval_status IN (0, 1)", name: "idx_hwr_active_unique"

    add_foreign_key :holiday_work_requests, :users,
                    column: %i[organization_id requester_id], primary_key: %i[organization_id id]
    add_foreign_key :holiday_work_requests, :leave_types,
                    column: %i[organization_id compensation_leave_type_id],
                    primary_key: %i[organization_id id]
  end
end
```

- [ ] **Step 2: migrate して schema 反映**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `holiday_work_requests` テーブル作成・`db/schema.rb` 自動更新（手編集しない）

- [ ] **Step 3: factory を作成**

`spec/factories/holiday_work_requests.rb`:

```ruby
# frozen_string_literal: true

FactoryBot.define do
  factory :holiday_work_request do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    requester { association(:user) }
    compensation_leave_type do
      association(:leave_type, system_type: :compensatory_leave, organization:)
    end
    work_date { Date.new(2026, 6, 7) } # 日曜（ISO フォールバックで :sunday＝平日以外）
    reason { "休日対応のため" }
  end
end
```

- [ ] **Step 4: 失敗するテストを書く**

`spec/models/holiday_work_request_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe HolidayWorkRequest do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:requester) { create(:user, organization: org) }
  let(:comp) { create(:leave_type, system_type: :compensatory_leave, organization: org) }

  def build_hwr(**attrs)
    build(:holiday_work_request, organization: org, requester:, compensation_leave_type: comp, **attrs)
  end

  def in_savepoint
    ActiveRecord::Base.transaction(requires_new: true) { yield }
  end

  describe "work_date は平日以外のみ" do
    it "日曜（未登録・ISO フォールバック）は valid" do
      expect(build_hwr(work_date: Date.new(2026, 6, 7))).to be_valid
    end

    it "登録済 legal_holiday は valid" do
      create(:company_calendar, organization: org, date: Date.new(2026, 5, 4),
                                day_type: :legal_holiday, name: "みどりの日")
      expect(build_hwr(work_date: Date.new(2026, 5, 4))).to be_valid
    end

    it "平日（月曜）は invalid" do
      hwr = build_hwr(work_date: Date.new(2026, 6, 8)) # 月曜
      expect(hwr).to be_invalid
      expect(hwr.errors[:work_date]).to be_present
    end

    it "work_date 未入力は presence エラー（resolver を呼ばない）" do
      hwr = build_hwr(work_date: nil)
      expect(hwr).to be_invalid
      expect(hwr.errors[:work_date]).to include("を入力してください")
    end
  end

  describe "compensation_leave_type は代休限定（D3）" do
    it "compensatory_leave は valid" do
      expect(build_hwr(compensation_leave_type: comp)).to be_valid
    end

    it "substitute_holiday は invalid（振替退行防止）" do
      sub = create(:leave_type, system_type: :substitute_holiday, organization: org)
      hwr = build_hwr(compensation_leave_type: sub)
      expect(hwr).to be_invalid
      expect(hwr.errors[:compensation_leave_type]).to be_present
    end

    it "annual は invalid" do
      annual = create(:leave_type, system_type: :annual, organization: org)
      expect(build_hwr(compensation_leave_type: annual)).to be_invalid
    end
  end

  describe "同一日重複禁止" do
    it "applying の重複は invalid" do
      create(:holiday_work_request, organization: org, requester:, work_date: Date.new(2026, 6, 7))
      expect(build_hwr(work_date: Date.new(2026, 6, 7))).to be_invalid
    end

    it "canceled 後の同日再申請は valid" do
      create(:holiday_work_request, organization: org, requester:,
                                    work_date: Date.new(2026, 6, 7), approval_status: :canceled)
      expect(build_hwr(work_date: Date.new(2026, 6, 7))).to be_valid
    end

    it "rejected 後の同日再申請は valid" do
      create(:holiday_work_request, organization: org, requester:,
                                    work_date: Date.new(2026, 6, 7), approval_status: :rejected)
      expect(build_hwr(work_date: Date.new(2026, 6, 7))).to be_valid
    end

    it "DB partial unique が二層目（applying 2 件目を弾く）" do
      create(:holiday_work_request, organization: org, requester:, work_date: Date.new(2026, 6, 7))
      dup = build_hwr(work_date: Date.new(2026, 6, 7))
      expect { in_savepoint { dup.save!(validate: false) } }
        .to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "テナント越境 FK（二層）" do
    let(:other_org) { create(:organization) }

    it "他テナント requester は model 検証で invalid" do
      other_user = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      hwr = build_hwr(requester: other_user)
      expect(hwr).to be_invalid
      expect(hwr.errors[:requester]).to include("は同一組織でなければなりません")
    end

    it "他テナント requester は DB FK で弾く" do
      other_user = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      hwr = build_hwr(requester: other_user)
      hwr.requester_id = other_user.id
      expect { in_savepoint { hwr.save!(validate: false) } }
        .to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "他テナント compensation_leave_type は model 検証で invalid" do
      other_comp = ActsAsTenant.with_tenant(other_org) do
        create(:leave_type, system_type: :compensatory_leave, organization: other_org)
      end
      hwr = build_hwr(compensation_leave_type: other_comp)
      expect(hwr).to be_invalid
      expect(hwr.errors[:compensation_leave_type]).to include("は同一組織でなければなりません")
    end
  end

  describe "Approvable lifecycle" do
    it "初期は applying" do
      expect(build_hwr.approval_status).to eq("applying")
    end

    it "reject! で rejected へ" do
      hwr = create(:holiday_work_request, organization: org, requester:)
      hwr.reject!
      expect(hwr).to be_rejected
    end

    it "cancel! で canceled へ" do
      hwr = create(:holiday_work_request, organization: org, requester:)
      hwr.cancel!
      expect(hwr).to be_canceled
    end
  end
end
```

- [ ] **Step 5: テストが失敗することを確認**

Run: `bundle exec rspec spec/models/holiday_work_request_spec.rb`
Expected: FAIL（`uninitialized constant HolidayWorkRequest`）

- [ ] **Step 6: モデルを実装**

`app/models/holiday_work_request.rb`:

```ruby
# frozen_string_literal: true

# 休日出勤申請（SPEC §4.12・Phase 2-4 設計 §1.1）。承認対象の 3 つ目。
# approval_status の writer は承認エンジンのみ。compensation_leave_type は v1 代休限定（振替は後置）。
class HolidayWorkRequest < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :requester, class_name: "User"
  belongs_to :compensation_leave_type, class_name: "LeaveType"

  include Approvable   # approval_status の AASM + has_many :approval_assignments

  validates :work_date, presence: true
  validates :reason, presence: true
  validate :work_date_is_non_weekday
  validate :compensation_type_is_compensatory
  validate :no_duplicate_active_request
  validate :requester_must_belong_to_same_organization
  validate :compensation_leave_type_must_belong_to_same_organization

  # 承認確定時の副作用（§6.11・§13.6）。Approve エンジンの with_lock 内・同一 tx で呼ばれる。
  # 実装は Task 4。
  def apply_approval_effects!(acting_user:)
    HolidayWorkRequests::ApplyApproval.call(holiday_work_request: self, acting_user:)
  end

  private

  # 平日以外のみ許可（§6.11 step1）。未登録日は CompanyCalendarResolver が ISO 曜日でフォールバック。
  def work_date_is_non_weekday
    return if work_date.nil?   # presence に委ねる（resolver を nil で呼ばない）
    return if CompanyCalendarResolver.new(organization:).day_type(work_date) != :weekday

    errors.add(:work_date, "は休日（平日以外）のみ申請できます")
  end

  # v1 は振替（substitute_holiday）を選べない＝割増免除運用を作らない（SPEC §6.11 事前特定ノート・D3）。
  def compensation_type_is_compensatory
    return if compensation_leave_type_id.nil?
    return if compensation_leave_type&.compensatory_leave?

    errors.add(:compensation_leave_type, "は代休のみ指定できます")
  end

  # 同一 (requester, work_date) で applying/approved の他レコードを拒否（DB partial unique と二層）。
  def no_duplicate_active_request
    return if requester_id.nil? || work_date.nil?

    dup = HolidayWorkRequest.where(requester_id:, work_date:, approval_status: %i[applying approved])
                            .where.not(id:)
    errors.add(:work_date, "は既に申請済みです") if dup.exists?
  end

  # ID 基点 fail-closed（clock_change_request.rb / leave_balance.rb 同型）
  def requester_must_belong_to_same_organization
    return if requester_id.nil?
    return if requester&.organization_id == organization_id

    errors.add(:requester, "は同一組織でなければなりません")
  end

  def compensation_leave_type_must_belong_to_same_organization
    return if compensation_leave_type_id.nil?
    return if compensation_leave_type&.organization_id == organization_id

    errors.add(:compensation_leave_type, "は同一組織でなければなりません")
  end
end
```

> **注**: `validates :work_date, presence: true` のメッセージは ja.yml の `errors.messages.blank`（既定「を入力してください」）に依存。テストの `include("を入力してください")` が通らなければ ja locale 既定を確認。

- [ ] **Step 7: テストが通ることを確認**

Run: `bundle exec rspec spec/models/holiday_work_request_spec.rb`
Expected: PASS（全 example）

- [ ] **Step 8: コミット**

```bash
bundle exec rubocop --force-exclusion app/models/holiday_work_request.rb spec/models/holiday_work_request_spec.rb spec/factories/holiday_work_requests.rb db/migrate/*create_holiday_work_requests.rb
git add app/models/holiday_work_request.rb spec/ db/migrate/*create_holiday_work_requests.rb db/schema.rb
git commit -m "feat: HolidayWorkRequest モデル + migration（平日拒否/代休限定/重複/テナント・2-4）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `attendance_records.is_holiday_work` カラム + `User#holiday_work_reserved_on?`

**Files:**
- Create: `db/migrate/<ts>_add_is_holiday_work_to_attendance_records.rb`
- Modify: `app/models/user.rb`
- Test: `spec/models/user_spec.rb`

**Interfaces:**
- Produces: `attendance_records.is_holiday_work`（boolean default false）・`User#holiday_work_reserved_on?(date) -> Boolean`。Task 4（ApplyApproval ③）・Task 7（ClockIn/ProxyClockIn）が消費

- [ ] **Step 1: migration 生成・編集**

Run: `bin/rails generate migration AddIsHolidayWorkToAttendanceRecords`
生成ファイルを全置換:

```ruby
# frozen_string_literal: true

class AddIsHolidayWorkToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    # index は張らない（Phase 3-1 が実集計クエリの形状に合わせて張る・設計 R3）
    add_column :attendance_records, :is_holiday_work, :boolean, null: false, default: false
  end
end
```

- [ ] **Step 2: migrate**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: カラム追加・schema 自動更新

- [ ] **Step 3: 失敗するテストを書く**

`spec/models/user_spec.rb` に追記（既存ファイルに describe を足す）:

```ruby
  describe "#holiday_work_reserved_on?" do
    let(:org) { create(:organization) }
    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
    let(:user) { create(:user, organization: org) }
    let(:date) { Date.new(2026, 6, 7) }

    it "承認済 HWR が同日にあれば true" do
      create(:holiday_work_request, organization: org, requester: user,
                                    work_date: date, approval_status: :approved)
      expect(user.holiday_work_reserved_on?(date)).to be(true)
    end

    it "applying（未承認）は false" do
      create(:holiday_work_request, organization: org, requester: user,
                                    work_date: date, approval_status: :applying)
      expect(user.holiday_work_reserved_on?(date)).to be(false)
    end

    it "別日の承認済は false" do
      create(:holiday_work_request, organization: org, requester: user,
                                    work_date: Date.new(2026, 6, 14), approval_status: :approved)
      expect(user.holiday_work_reserved_on?(date)).to be(false)
    end

    it "別 user の承認済は false" do
      other = create(:user, organization: org)
      create(:holiday_work_request, organization: org, requester: other,
                                    work_date: date, approval_status: :approved)
      expect(user.holiday_work_reserved_on?(date)).to be(false)
    end

    it "他テナントの承認済は false" do
      other_org = create(:organization)
      ActsAsTenant.with_tenant(other_org) do
        other_user = create(:user, organization: other_org)
        create(:holiday_work_request, organization: other_org, requester: other_user,
                                      work_date: date, approval_status: :approved)
      end
      expect(user.holiday_work_reserved_on?(date)).to be(false)
    end
  end
```

- [ ] **Step 4: テストが失敗することを確認**

Run: `bundle exec rspec spec/models/user_spec.rb -e holiday_work_reserved_on`
Expected: FAIL（`undefined method 'holiday_work_reserved_on?'`）

- [ ] **Step 5: User に has_many + 述語を実装**

`app/models/user.rb` の既存 `has_many :leave_requests, ...` 付近に追記（無ければ associations ブロックに）:

```ruby
  has_many :holiday_work_requests, foreign_key: :requester_id, inverse_of: :requester, dependent: :restrict_with_error
```

`app/models/user.rb` の public メソッド領域（例: `paid_annual?` 等の述語と同じ層）に追記:

```ruby
  # 承認済 HWR が当日にあるか（ClockIn/ProxyClockIn が打刻 AR の is_holiday_work 初期値に使う・§2.3）。
  # acts_as_tenant default_scope + association 起点ゆえ他人/他テナントの HWR を拾わない。
  def holiday_work_reserved_on?(date) = holiday_work_requests.approved.exists?(work_date: date)
```

> **注**: `dependent: :restrict_with_error` は user 削除時に申請が残っていれば止める（既存 leave_requests と方針を揃える。既存が `:destroy` 等なら合わせる）。`inverse_of: :requester` は HWR の `belongs_to :requester` と対。

- [ ] **Step 6: テストが通ることを確認**

Run: `bundle exec rspec spec/models/user_spec.rb -e holiday_work_reserved_on`
Expected: PASS（5 examples）

- [ ] **Step 7: コミット**

```bash
bundle exec rubocop --force-exclusion app/models/user.rb spec/models/user_spec.rb db/migrate/*add_is_holiday_work*.rb
git add app/models/user.rb spec/models/user_spec.rb db/migrate/*add_is_holiday_work*.rb db/schema.rb
git commit -m "feat: is_holiday_work カラム + User#holiday_work_reserved_on?（双方向連動の基盤・2-4 D1）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `HolidayWorkRequests::ApplyApproval` + model hook

**Files:**
- Create: `app/services/holiday_work_requests/apply_approval.rb`
- Test: `spec/services/holiday_work_requests/apply_approval_spec.rb`

**Interfaces:**
- Consumes: `CompanyCalendarResolver#day_type`・`Organization#fiscal_year_for(date)`・`LeaveBalance`・`Approvals::ConflictError`・`User#attendance_records`
- Produces: `HolidayWorkRequests::ApplyApproval.call(holiday_work_request:, acting_user:)`。`HolidayWorkRequest#apply_approval_effects!`（Task 2 で hook 済）から呼ばれる

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/holiday_work_requests/apply_approval_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe HolidayWorkRequests::ApplyApproval do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:requester) { create(:user, organization: org) }
  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:comp) { create(:leave_type, system_type: :compensatory_leave, organization: org) }
  let(:work_date) { Date.new(2026, 6, 7) } # 日曜

  def hwr(**attrs)
    create(:holiday_work_request, organization: org, requester:, compensation_leave_type: comp,
                                  work_date:, approval_status: :approved, **attrs)
  end

  def apply(req) = described_class.call(holiday_work_request: req, acting_user: approver)

  describe "② 代休残高 +1" do
    it "残高行が無ければ作成して granted_days=1（requester 名義・full 属性）" do
      apply(hwr)
      balance = LeaveBalance.find_by(user: requester, leave_type: comp,
                                     fiscal_year: org.fiscal_year_for(work_date))
      expect(balance).to have_attributes(granted_days: 1, used_days: 0, carry_over_days: 0, granted_on: nil)
    end

    it "既存残高に +1" do
      fy = org.fiscal_year_for(work_date)
      create(:leave_balance, organization: org, user: requester, leave_type: comp,
                             fiscal_year: fy, granted_days: 2)
      apply(hwr)
      expect(LeaveBalance.find_by(user: requester, leave_type: comp, fiscal_year: fy).granted_days).to eq(2 + 1)
    end

    it "並行 create の RecordNotUnique を savepoint 隔離し granted_days はちょうど +1" do
      req = hwr
      call_count = 0
      allow(LeaveBalance).to receive(:create!).and_wrap_original do |orig, *args, **kw|
        call_count += 1
        if call_count == 1
          # 並行 create の敗者を模す（別経路が先に行を作った）
          ActsAsTenant.with_tenant(org) do
            LeaveBalance.where(user_id: requester.id, leave_type_id: comp.id,
                               fiscal_year: org.fiscal_year_for(work_date)).first_or_create! do |b|
              b.granted_days = 0; b.carry_over_days = 0; b.used_days = 0
            end
          end
          raise ActiveRecord::RecordNotUnique, "duplicate"
        end
        orig.call(*args, **kw)
      end
      apply(req)
      expect(LeaveBalance.where(user: requester, leave_type: comp).sum(:granted_days)).to eq(1)
    end
  end

  describe "③ is_holiday_work（双方向・既存 AR のみ）" do
    it "既存 clocked AR があれば is_holiday_work=true" do
      ar = create(:attendance_record, :done, organization: org, user: requester, work_date:)
      apply(hwr)
      expect(ar.reload.is_holiday_work).to be(true)
    end

    it "AR が無ければ新規作成しない（予約は AR を作らない）" do
      expect { apply(hwr) }.not_to change(AttendanceRecord, :count)
    end

    it "計算済 AR を再計算しない・AttendanceHistory を増やさない" do
      ar = create(:attendance_record, :done, organization: org, user: requester, work_date:)
      expect(Clockings::Recalculate).not_to receive(:call)
      expect { apply(hwr) }.not_to change(AttendanceHistory, :count)
      expect { ar.reload }.not_to(change { ar.attributes.slice("actual_work_hours", "is_late") })
    end
  end

  describe "① 承認時の平日性再検証（D4）" do
    it "承認時に平日化していたら ConflictError で balance も AR も巻き戻る" do
      req = hwr
      ar = create(:attendance_record, :done, organization: org, user: requester, work_date:)
      # work_date を平日扱いにするカレンダー登録（承認後の編集を模す）
      create(:company_calendar, organization: org, date: work_date, day_type: :weekday)
      expect { apply(req) }.to raise_error(Approvals::ConflictError)
      expect(LeaveBalance.where(user: requester, leave_type: comp)).to be_empty
      expect(ar.reload.is_holiday_work).to be(false)
    end
  end
end
```

> **注**: `① 平日性` の rollback テストは、`ApplyApproval` を直接呼ぶと外側 tx が無いので savepoint で包む必要がある。`apply` を `ActiveRecord::Base.transaction { apply(req) }` で囲み、`raise_error` 後の `LeaveBalance`/`ar` 状態を別 tx で確認する形に調整してよい（実装後に緑化を確認しながら微修正可）。`:attendance_record` factory に `:done` trait（clocked_out + 計算列充填）が無ければ既存の trait 名に合わせる。

- [ ] **Step 2: テストが失敗することを確認**

Run: `bundle exec rspec spec/services/holiday_work_requests/apply_approval_spec.rb`
Expected: FAIL（`uninitialized constant HolidayWorkRequests::ApplyApproval`）

- [ ] **Step 3: サービスを実装**

`app/services/holiday_work_requests/apply_approval.rb`:

```ruby
# frozen_string_literal: true

module HolidayWorkRequests
  # 休日出勤承認の副作用本体（SPEC §6.11・2-4 設計 §2.2）。
  # 呼び出し元: HolidayWorkRequest#apply_approval_effects!（Approvals::Approve の with_lock 内・同一 tx）。
  # 内側で rescue しない — ConflictError は raise 伝播し承認ごと atomic rollback。
  # 処理順: ① work_date 平日性 re-validate ② 代休残高 +1（lock or savepoint create）③ 既存 AR に flag。
  class ApplyApproval
    def self.call(holiday_work_request:, acting_user:)
      new(holiday_work_request:, acting_user:).call
    end

    def initialize(holiday_work_request:, acting_user:)
      @hwr = holiday_work_request
      @acting_user = acting_user
    end

    def call
      ActsAsTenant.with_tenant(@hwr.organization) do
        revalidate_holiday!          # ①
        grant_compensation_balance   # ②
        flag_existing_record         # ③
      end
      @hwr
    end

    private

    # ① 承認時にカレンダー編集で平日化していたら弾く（§7.4 哲学・D4）
    def revalidate_holiday!
      resolver = CompanyCalendarResolver.new(organization: @hwr.organization)
      raise Approvals::ConflictError if resolver.day_type(@hwr.work_date) == :weekday
    end

    # ② 代休残高 +1（付与ゆえ over-balance チェック無し）
    def grant_compensation_balance
      fiscal_year = @hwr.organization.fiscal_year_for(@hwr.work_date)   # §6.2 年度跨ぎ統一
      balance = lock_or_create_balance(@hwr.requester_id, @hwr.compensation_leave_type_id, fiscal_year)
      balance.update!(granted_days: balance.granted_days + 1)
    end

    # FOR UPDATE で取得（2-2b add_to_balance 同型）。無ければ savepoint で create し RecordNotUnique を隔離
    # （外側 with_lock の同一 tx を RecordNotUnique で毒さない・設計 R2）。
    def lock_or_create_balance(user_id, leave_type_id, fiscal_year)
      scope = LeaveBalance.where(user_id:, leave_type_id:, fiscal_year:)
      balance = scope.lock.first
      return balance if balance

      begin
        ActiveRecord::Base.transaction(requires_new: true) do
          LeaveBalance.create!(user_id:, leave_type_id:, fiscal_year:,
                               granted_days: 0, carry_over_days: 0, used_days: 0)
        end
      rescue ActiveRecord::RecordNotUnique
        # 並行 create の敗者 — 行は既に存在。savepoint のみ rollback、親 tx は健全
      end
      scope.lock.first
    end

    # ③ 既存 AR にのみ flag（予約は AR を新規作成しない）。再計算しない（§5 は is_holiday_work 非依存・D6）
    def flag_existing_record
      record = @hwr.requester.attendance_records.find_by(work_date: @hwr.work_date)
      record&.update!(is_holiday_work: true)
    end
  end
end
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/services/holiday_work_requests/apply_approval_spec.rb`
Expected: PASS（必要なら Step 1 の注に従い rollback テストを tx 包みに微修正）

- [ ] **Step 5: コミット**

```bash
bundle exec rubocop --force-exclusion app/services/holiday_work_requests/apply_approval.rb spec/services/holiday_work_requests/apply_approval_spec.rb
git add app/services/holiday_work_requests/apply_approval.rb spec/services/holiday_work_requests/apply_approval_spec.rb
git commit -m "feat: HolidayWorkRequests::ApplyApproval（平日再検証+代休+1+flag・savepoint隔離・2-4）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `LeaveRequests::ApplyApproval#add_to_balance` 一般化（消費側回帰）

**Files:**
- Modify: `app/services/leave_requests/apply_approval.rb:30`
- Test: `spec/services/leave_requests/apply_approval_spec.rb`

**Interfaces:**
- Consumes: `LeaveType#balance_tracked?`（Task 1）
- Produces: 代休 LeaveRequest 承認で `LeaveBalance.used_days` が減算され over-balance が効く（挙動変更）

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/leave_requests/apply_approval_spec.rb` に describe を追記:

```ruby
  describe "代休 LeaveRequest 消費（D2 一般化）" do
    let(:org) { create(:organization) }
    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
    let(:user) { create(:user, organization: org) }
    let(:approver) { create(:user, :manager_role, organization: org) }
    let(:comp) { create(:leave_type, system_type: :compensatory_leave, paid_leave: false, organization: org) }
    let(:fy) { org.fiscal_year_for(Date.new(2026, 6, 7)) }

    def consume(days:, start_date: Date.new(2026, 6, 7))
      lr = create(:leave_request, organization: org, requester: user, leave_type: comp,
                                  start_date:, end_date: start_date, days_requested: days,
                                  approval_status: :approved)
      described_class.call(leave_request: lr, acting_user: approver)
    end

    it "残高ありで取得すると used_days が減算される" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 2)
      consume(days: 1)
      expect(LeaveBalance.find_by(user:, leave_type: comp, fiscal_year: fy).used_days).to eq(1)
    end

    it "残高超過は OverBalanceError + used_days 不変 + AR/history 未作成" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 1)
      expect { consume(days: 2) }.to raise_error(Approvals::OverBalanceError)
      bal = LeaveBalance.find_by(user:, leave_type: comp, fiscal_year: fy)
      expect(bal.used_days).to eq(0)
      expect(AttendanceRecord.where(user:, work_date: Date.new(2026, 6, 7))).to be_empty
    end

    it "境界（消費 == 残高）は成功" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 1)
      expect { consume(days: 1) }.not_to raise_error
    end

    it "代休 LeaveBalance は carry_over_days=0 を維持（繰越対象外・R8）" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 2)
      consume(days: 1)
      expect(LeaveBalance.find_by(user:, leave_type: comp, fiscal_year: fy).carry_over_days).to eq(0)
    end
  end
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb -e "代休 LeaveRequest 消費"`
Expected: FAIL（`balance_tracked?` 未適用ゆえ `paid_leave: false` の代休が `add_to_balance` を素通り → used_days=0 のまま・最初の example で不一致）

- [ ] **Step 3: ガードを一般化**

`app/services/leave_requests/apply_approval.rb` の `add_to_balance` 冒頭を変更:

```ruby
    def add_to_balance
      return unless @leave_request.leave_type.balance_tracked?   # was: paid_leave?
      # 以降は不変
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb`
Expected: PASS（新規 + 既存 paid_leave 経路の回帰も緑）

- [ ] **Step 5: コミット**

```bash
bundle exec rubocop --force-exclusion app/services/leave_requests/apply_approval.rb spec/services/leave_requests/apply_approval_spec.rb
git add app/services/leave_requests/apply_approval.rb spec/services/leave_requests/apply_approval_spec.rb
git commit -m "feat: add_to_balance を balance_tracked? に一般化（代休消費の減算・2-4 D2）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `HolidayWorkRequests::Create`

**Files:**
- Create: `app/services/holiday_work_requests/create.rb`
- Test: `spec/services/holiday_work_requests/create_spec.rb`

**Interfaces:**
- Consumes: `Approvals::Start.call(approvable)`・`Approvals::RouteError`
- Produces: `HolidayWorkRequests::Create.call(requester:, work_date:, compensation_leave_type:, reason:) -> HolidayWorkRequest`

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/holiday_work_requests/create_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe HolidayWorkRequests::Create do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:manager) { create(:user, :manager_role, organization: org) }
  let(:requester) { create(:user, organization: org, manager:) }
  let(:comp) { create(:leave_type, system_type: :compensatory_leave, organization: org) }

  def call(**attrs)
    described_class.call(requester:, work_date: Date.new(2026, 6, 7),
                         compensation_leave_type: comp, reason: "休日対応", **attrs)
  end

  it "HWR を作成し承認エンジンを起動する" do
    hwr = call
    expect(hwr).to be_persisted
    expect(hwr.approval_assignments).to be_present
  end

  it "manager 未設定なら RouteError で HWR を残さない（atomic）" do
    requester.update!(manager: nil)
    expect { call }.to raise_error(Approvals::RouteError)
    expect(HolidayWorkRequest.count).to eq(0)
    expect(ApprovalAssignment.count).to eq(0)
  end
end
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `bundle exec rspec spec/services/holiday_work_requests/create_spec.rb`
Expected: FAIL（`uninitialized constant HolidayWorkRequests::Create`）

- [ ] **Step 3: サービスを実装**

`app/services/holiday_work_requests/create.rb`:

```ruby
# frozen_string_literal: true

module HolidayWorkRequests
  # 休日出勤申請の作成（2-4 設計 §2.1）。1 tx で HWR 作成 + 承認エンジン起動。
  # requester は呼び出し側が current_user を渡す（params 由来の id を受けない）。
  class Create
    def self.call(requester:, work_date:, compensation_leave_type:, reason:)
      new(requester:, work_date:, compensation_leave_type:, reason:).call
    end

    def initialize(requester:, work_date:, compensation_leave_type:, reason:)
      @requester = requester
      @work_date = work_date
      @compensation_leave_type = compensation_leave_type
      @reason = reason
    end

    def call
      ActiveRecord::Base.transaction do
        hwr = HolidayWorkRequest.create!(
          requester: @requester, work_date: @work_date,
          compensation_leave_type: @compensation_leave_type, reason: @reason
        )
        Approvals::Start.call(hwr)   # ルート解決 + pending assignment（既存エンジン）
        hwr
      end
    end
  end
end
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/services/holiday_work_requests/create_spec.rb`
Expected: PASS（2 examples）

- [ ] **Step 5: コミット**

```bash
bundle exec rubocop --force-exclusion app/services/holiday_work_requests/create.rb spec/services/holiday_work_requests/create_spec.rb
git add app/services/holiday_work_requests/create.rb spec/services/holiday_work_requests/create_spec.rb
git commit -m "feat: HolidayWorkRequests::Create（1tx・Start起動・RouteError rollback・2-4）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `Clockings::ClockIn` / `ProxyClockIn` の is_holiday_work 連動

**Files:**
- Modify: `app/services/clockings/clock_in.rb:23-31`
- Modify: `app/services/clockings/proxy_clock_in.rb:34-41`
- Test: `spec/services/clockings/clock_in_spec.rb`, `spec/services/clockings/proxy_clock_in_spec.rb`

**Interfaces:**
- Consumes: `User#holiday_work_reserved_on?(date)`（Task 3）
- Produces: 打刻作成 AR の `is_holiday_work` が承認済 HWR の有無で決まる

- [ ] **Step 1: 失敗するテストを書く（ClockIn）**

`spec/services/clockings/clock_in_spec.rb` に describe を追記:

```ruby
  describe "is_holiday_work 連動（2-4）" do
    it "承認済 HWR がある日の出勤打刻で is_holiday_work=true" do
      create(:holiday_work_request, organization: user.organization, requester: user,
                                    work_date: user.organization.today, approval_status: :approved)
      result = described_class.call(user:)
      expect(result.record.is_holiday_work).to be(true)
    end

    it "承認済 HWR が無ければ false" do
      result = described_class.call(user:)
      expect(result.record.is_holiday_work).to be(false)
    end
  end
```

> **注**: 既存 `clock_in_spec.rb` の `user`/テナント設定（`let`/`around`）に合わせる。`user.organization.today` が平日だと別の打刻ガードに掛からないか確認（HWR factory の work_date と打刻日を `today` で揃える）。

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/clockings/clock_in_spec.rb -e is_holiday_work`
Expected: FAIL（`is_holiday_work` が常に false）

- [ ] **Step 3: ClockIn を改修**

`app/services/clockings/clock_in.rb` の `create!(...)` に一行追加:

```ruby
        record = @user.attendance_records.create!(
          work_date: today,
          clock_in: Time.current.change(usec: 0),
          work_pattern_id: Clockings.snapshot_pattern_id(@user, today),
          status: :working,
          is_holiday_work: @user.holiday_work_reserved_on?(today)   # 承認済 HWR があれば true（2-4 D1）
        )
```

- [ ] **Step 4: 失敗するテストを書く（ProxyClockIn・主体取り違え pin）**

`spec/services/clockings/proxy_clock_in_spec.rb` に追記:

```ruby
  describe "is_holiday_work 連動（2-4）" do
    it "target_user に承認済 HWR があれば is_holiday_work=true" do
      create(:holiday_work_request, organization: org, requester: target_user,
                                    work_date: org.today, approval_status: :approved)
      result = described_class.call(operator:, target_user:, reason: "システム障害")
      expect(result.record.is_holiday_work).to be(true)
    end

    it "operator が HWR を持ち target が持たない場合は false（target を見る・operator ではない）" do
      create(:holiday_work_request, organization: org, requester: operator,
                                    work_date: org.today, approval_status: :approved)
      result = described_class.call(operator:, target_user:, reason: "システム障害")
      expect(result.record.is_holiday_work).to be(false)
    end
  end
```

> **注**: 既存 `proxy_clock_in_spec.rb` の `org`/`operator`/`target_user` の名前に合わせる。

- [ ] **Step 5: 失敗を確認**

Run: `bundle exec rspec spec/services/clockings/proxy_clock_in_spec.rb -e is_holiday_work`
Expected: FAIL

- [ ] **Step 6: ProxyClockIn を改修**

`app/services/clockings/proxy_clock_in.rb` の `create!(...)` に一行追加:

```ruby
          record = @target_user.attendance_records.create!(
            work_date: today,
            clock_in: Time.current.change(usec: 0),
            work_pattern_id: Clockings.snapshot_pattern_id(@target_user, today),
            status: :working,
            proxy_clock_reason: @reason,
            note: fragment,
            is_holiday_work: @target_user.holiday_work_reserved_on?(today)   # target を見る（2-4 D1）
          )
```

- [ ] **Step 7: テストが通ることを確認**

Run: `bundle exec rspec spec/services/clockings/clock_in_spec.rb spec/services/clockings/proxy_clock_in_spec.rb`
Expected: PASS（既存 example も緑）

- [ ] **Step 8: コミット**

```bash
bundle exec rubocop --force-exclusion app/services/clockings/clock_in.rb app/services/clockings/proxy_clock_in.rb spec/services/clockings/clock_in_spec.rb spec/services/clockings/proxy_clock_in_spec.rb
git add app/services/clockings/clock_in.rb app/services/clockings/proxy_clock_in.rb spec/services/clockings/
git commit -m "feat: ClockIn/ProxyClockIn が承認済 HWR で is_holiday_work を立てる（事前付与・2-4 D1）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `HolidayWorkRequestPolicy`

**Files:**
- Create: `app/policies/holiday_work_request_policy.rb`
- Test: `spec/policies/holiday_work_request_policy_spec.rb`

**Interfaces:**
- Produces: `HolidayWorkRequestPolicy`（index?/new?/create?/cancel? + Scope）

- [ ] **Step 1: 失敗するテストを書く**

`spec/policies/holiday_work_request_policy_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe HolidayWorkRequestPolicy do
  subject { described_class }

  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:user) { create(:user, organization: org) }
  let(:other) { create(:user, organization: org) }

  permissions :cancel? do
    it "本人かつ applying なら許可" do
      hwr = create(:holiday_work_request, organization: org, requester: user, approval_status: :applying)
      expect(subject).to permit(user, hwr)
    end

    it "applying でなければ拒否" do
      hwr = create(:holiday_work_request, organization: org, requester: user, approval_status: :approved)
      expect(subject).not_to permit(user, hwr)
    end

    it "他人は拒否" do
      hwr = create(:holiday_work_request, organization: org, requester: user, approval_status: :applying)
      expect(subject).not_to permit(other, hwr)
    end
  end

  describe "Scope" do
    it "本人の申請のみ返す" do
      mine = create(:holiday_work_request, organization: org, requester: user)
      create(:holiday_work_request, organization: org, requester: other)
      resolved = described_class::Scope.new(user, HolidayWorkRequest).resolve
      expect(resolved).to contain_exactly(mine)
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/policies/holiday_work_request_policy_spec.rb`
Expected: FAIL（`uninitialized constant HolidayWorkRequestPolicy`）

- [ ] **Step 3: Policy を実装**

`app/policies/holiday_work_request_policy.rb`:

```ruby
# frozen_string_literal: true

# 休日出勤申請の認可（2-4 設計 §3.2・ClockChangeRequestPolicy 同型）。requester=current_user 固定。
class HolidayWorkRequestPolicy < ApplicationPolicy
  def index? = user.present?
  def new? = user.present?
  def create? = user.present?

  def cancel? = record.requester_id == user.id && record.applying?

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(requester_id: user.id)
  end
end
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/policies/holiday_work_request_policy_spec.rb`
Expected: PASS（4 examples）

- [ ] **Step 5: コミット**

```bash
bundle exec rubocop --force-exclusion app/policies/holiday_work_request_policy.rb spec/policies/holiday_work_request_policy_spec.rb
git add app/policies/holiday_work_request_policy.rb spec/policies/holiday_work_request_policy_spec.rb
git commit -m "feat: HolidayWorkRequestPolicy（本人 Scope・cancel 本人 applying のみ・2-4）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Controller + routes + 申請 UI

**Files:**
- Create: `app/controllers/holiday_work_requests_controller.rb`
- Create: `app/views/holiday_work_requests/{_form,index,new}.html.erb`
- Modify: `config/routes.rb`
- Test: `spec/requests/holiday_work_requests_spec.rb`

**Interfaces:**
- Consumes: `HolidayWorkRequests::Create`・`Approvals::Cancel`・`HolidayWorkRequestPolicy`
- Produces: `/holiday_work_requests`（index/new/create）・`/holiday_work_requests/:id/cancel`

- [ ] **Step 1: routes を追加**

`config/routes.rb` の `resources :clock_change_requests ...` ブロックの後に追記:

```ruby
  resources :holiday_work_requests, only: %i[index new create] do
    member { patch :cancel }
  end
```

- [ ] **Step 2: 失敗するテストを書く**

`spec/requests/holiday_work_requests_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "HolidayWorkRequests" do
  let(:org) { create(:organization) }
  let(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, organization: org) } }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user, organization: org, manager:) } }
  let(:comp) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :compensatory_leave, organization: org) } }

  before do
    host! "#{org.subdomain}.example.com"
    sign_in user
  end

  def valid_params(**overrides)
    { holiday_work_request: { work_date: "2026-06-07", compensation_leave_type_id: comp.id,
                              reason: "休日対応", **overrides } }
  end

  describe "POST /holiday_work_requests" do
    it "成功すると申請が作られインボックスへ承認待ちが積まれる" do
      expect { post holiday_work_requests_path, params: valid_params }
        .to change(HolidayWorkRequest, :count).by(1)
      expect(response).to redirect_to(holiday_work_requests_path)
    end

    it "平日は 422" do
      post holiday_work_requests_path, params: valid_params(work_date: "2026-06-08") # 月曜
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "代休以外の種別は 422" do
      annual = ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :annual, organization: org) }
      post holiday_work_requests_path, params: valid_params(compensation_leave_type_id: annual.id)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "manager 未設定なら alert で一覧へ" do
      ActsAsTenant.with_tenant(org) { user.update!(manager: nil) }
      post holiday_work_requests_path, params: valid_params
      expect(response).to redirect_to(holiday_work_requests_path)
      follow_redirect!
      expect(response.body).to include("直属上長")
    end
  end

  describe "PATCH /holiday_work_requests/:id/cancel" do
    it "本人の applying を取消" do
      hwr = ActsAsTenant.with_tenant(org) do
        HolidayWorkRequests::Create.call(requester: user, work_date: Date.new(2026, 6, 7),
                                         compensation_leave_type: comp, reason: "x")
      end
      patch cancel_holiday_work_request_path(hwr)
      expect(hwr.reload).to be_canceled
    end
  end
end
```

> **注**: ログイン/ホスト設定（`sign_in`・`host!`）は既存 `spec/requests/clock_change_requests_spec.rb` の作法に合わせる。subdomain テナント解決の設定が異なる場合はそれに倣う。

- [ ] **Step 3: 失敗を確認**

Run: `bundle exec rspec spec/requests/holiday_work_requests_spec.rb`
Expected: FAIL（routing/controller 未定義）

- [ ] **Step 4: Controller を実装**

`app/controllers/holiday_work_requests_controller.rb`:

```ruby
# frozen_string_literal: true

# 社員の休日出勤申請（2-4 設計 §3.1・ClockChangeRequestsController 同型）。requester=current_user 構造固定。
class HolidayWorkRequestsController < ApplicationController
  before_action :set_holiday_work_request, only: :cancel

  def index
    authorize HolidayWorkRequest
    @holiday_work_requests = policy_scope(HolidayWorkRequest).order(work_date: :desc)
  end

  def new
    authorize HolidayWorkRequest
    @holiday_work_request = HolidayWorkRequest.new
    @compensation_leave_types = LeaveType.where(system_type: :compensatory_leave)
  end

  def create
    authorize HolidayWorkRequest
    @holiday_work_request = HolidayWorkRequests::Create.call(
      requester: current_user,
      work_date: create_params[:work_date],
      compensation_leave_type: LeaveType.find(create_params[:compensation_leave_type_id]),
      reason: create_params[:reason]
    )
    redirect_to holiday_work_requests_path, status: :see_other, notice: "休日出勤を申請しました"
  rescue Approvals::RouteError
    redirect_to holiday_work_requests_path, status: :see_other,
                alert: "申請できません。直属上長が未設定です（管理者にご連絡ください）"
  rescue ActiveRecord::RecordInvalid => e
    @holiday_work_request = e.record
    @compensation_leave_types = LeaveType.where(system_type: :compensatory_leave)
    render :new, status: :unprocessable_entity
  end

  def cancel
    authorize @holiday_work_request, :cancel?
    Approvals::Cancel.call(approvable: @holiday_work_request, by: current_user)
    redirect_to holiday_work_requests_path, status: :see_other, notice: "申請を取り消しました"
  rescue AASM::InvalidTransition
    redirect_to holiday_work_requests_path, status: :see_other, alert: "この申請は取り消せません"
  end

  private

  def set_holiday_work_request
    @holiday_work_request = policy_scope(HolidayWorkRequest).find(params[:id])
  end

  # requester_id/approval_status は受けない（サーバ権威）
  def create_params
    params.require(:holiday_work_request).permit(:work_date, :compensation_leave_type_id, :reason)
  end
end
```

- [ ] **Step 5: Views を実装**

`app/views/holiday_work_requests/_form.html.erb`:

```erb
<%= form_with model: @holiday_work_request, url: holiday_work_requests_path do |f| %>
  <% if @holiday_work_request.errors.any? %>
    <div class="bg-red-50 border border-red-200 text-red-700 rounded p-3 mb-4">
      <ul class="list-disc list-inside text-sm">
        <% @holiday_work_request.errors.full_messages.each do |msg| %>
          <li><%= msg %></li>
        <% end %>
      </ul>
    </div>
  <% end %>

  <div class="mb-4">
    <%= f.label :work_date, "出勤予定日（休日のみ）", class: "block text-sm font-medium mb-1" %>
    <%= f.date_field :work_date, class: "border rounded px-2 py-1" %>
  </div>

  <div class="mb-4">
    <%= f.label :compensation_leave_type_id, "代償休暇種別（代休）", class: "block text-sm font-medium mb-1" %>
    <%= f.collection_select :compensation_leave_type_id, @compensation_leave_types, :id, :name,
          { prompt: "選択してください" }, class: "border rounded px-2 py-1" %>
  </div>

  <div class="mb-4">
    <%= f.label :reason, "出勤理由", class: "block text-sm font-medium mb-1" %>
    <%= f.text_area :reason, rows: 3, class: "border rounded px-2 py-1 w-full" %>
  </div>

  <%= f.submit "申請する", class: "bg-blue-600 text-white px-4 py-2 rounded" %>
<% end %>
```

`app/views/holiday_work_requests/new.html.erb`:

```erb
<% content_for :title, "休日出勤申請" %>
<div class="max-w-xl mx-auto p-4">
  <h1 class="text-xl font-bold mb-4">休日出勤申請</h1>
  <%= render "form" %>
</div>
```

`app/views/holiday_work_requests/index.html.erb`:

```erb
<% content_for :title, "休日出勤申請" %>
<div class="max-w-3xl mx-auto p-4">
  <div class="flex items-center justify-between mb-4">
    <h1 class="text-xl font-bold">休日出勤申請</h1>
    <%= link_to "新規申請", new_holiday_work_request_path, class: "bg-blue-600 text-white px-3 py-1 rounded text-sm" %>
  </div>

  <% if @holiday_work_requests.empty? %>
    <p class="text-gray-500">申請はありません。</p>
  <% else %>
    <table class="w-full text-sm">
      <thead><tr class="text-left text-gray-500">
        <th class="py-1">出勤日</th><th>代償種別</th><th>状態</th><th></th>
      </tr></thead>
      <tbody>
        <% @holiday_work_requests.each do |hwr| %>
          <tr class="border-t">
            <td class="py-1"><%= hwr.work_date %></td>
            <td><%= hwr.compensation_leave_type.name %></td>
            <td><%= t("holiday_work_request.status.#{hwr.approval_status}") %></td>
            <td class="text-right">
              <% if hwr.applying? %>
                <%= button_to "取消", cancel_holiday_work_request_path(hwr), method: :patch,
                      class: "text-red-600", data: { turbo_confirm: "取り消しますか？" } %>
              <% end %>
            </td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% end %>
</div>
```

- [ ] **Step 6: テストが通ることを確認**

Run: `bundle exec rspec spec/requests/holiday_work_requests_spec.rb`
Expected: PASS

> **注**: index view が `t("holiday_work_request.status...")` を引くため、この Task の緑化には Task 10 の i18n が必要になることがある。順序を入れ替えるか、本 Task で先に ja.yml の `holiday_work_request.status` だけ追加してよい（Task 10 で重複追加しないこと）。

- [ ] **Step 7: コミット**

```bash
bundle exec rubocop --force-exclusion app/controllers/holiday_work_requests_controller.rb config/routes.rb spec/requests/holiday_work_requests_spec.rb
git add app/controllers/holiday_work_requests_controller.rb app/views/holiday_work_requests/ config/routes.rb spec/requests/holiday_work_requests_spec.rb
git commit -m "feat: 休日出勤申請 UI（controller/routes/views・本人固定・Cancel 再利用・2-4）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: インボックス HWR 行 Component + i18n + 結合テスト

**Files:**
- Create: `app/components/approvals/holiday_work_request_row_component.rb` + `.html.erb`
- Modify: `app/views/approval_assignments/index.html.erb`
- Modify: `config/locales/ja.yml`
- Test: `spec/requests/approval_assignments_spec.rb`

**Interfaces:**
- Consumes: `ApprovalAssignment#approvable`（HolidayWorkRequest）・`HolidayWorkRequest#single_stage?`
- Produces: インボックスで HWR 行が描画され、承認で副作用が走る

- [ ] **Step 1: i18n を追加**

`config/locales/ja.yml` の `leave_request:` ブロックの後（同インデント）に追記:

```yaml
  holiday_work_request:
    status:
      applying: 申請中
      approved: 承認済
      rejected: 却下
      canceled: 取消
```

`config/locales/ja.yml` の `activerecord:` → `models:` / `attributes:` がある箇所に追記（無ければ該当ブロックを作る）:

```yaml
      holiday_work_request: 休日出勤申請
```
```yaml
      holiday_work_request:
        work_date: 出勤予定日
        compensation_leave_type: 代償休暇種別
        reason: 出勤理由
```

- [ ] **Step 2: 失敗するテストを書く（結合）**

`spec/requests/approval_assignments_spec.rb` に describe を追記:

```ruby
  describe "HolidayWorkRequest の承認（2-4）" do
    let(:org) { create(:organization) }
    let(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, organization: org) } }
    let(:requester) { ActsAsTenant.with_tenant(org) { create(:user, organization: org, manager:) } }
    let(:comp) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :compensatory_leave, organization: org) } }
    let(:hwr) do
      ActsAsTenant.with_tenant(org) do
        HolidayWorkRequests::Create.call(requester:, work_date: Date.new(2026, 6, 7),
                                         compensation_leave_type: comp, reason: "x")
      end
    end

    before do
      host! "#{org.subdomain}.example.com"
      sign_in manager
    end

    it "インボックスに HWR 行が出る" do
      hwr
      get approval_assignments_path
      expect(response.body).to include("休日出勤").and include(requester.name)
    end

    it "承認すると代休残高が +1 される" do
      assignment = hwr.approval_assignments.find_by(position: hwr.current_approval_position)
      patch approve_approval_assignment_path(assignment)
      balance = ActsAsTenant.with_tenant(org) do
        LeaveBalance.find_by(user: requester, leave_type: comp, fiscal_year: org.fiscal_year_for(Date.new(2026, 6, 7)))
      end
      expect(balance.granted_days).to eq(1)
    end
  end
```

> **注**: 単段縮約（manager の上長が無い → 1 段）になる構成なら `manager` が承認者。2 段なら `requester.manager.manager` を承認者にする。既存 `approval_assignments_spec.rb` の承認構成に倣う。承認時に work_date が平日だと D4 ConflictError になるため `2026-06-07`（日曜）を使う。

- [ ] **Step 3: 失敗を確認**

Run: `bundle exec rspec spec/requests/approval_assignments_spec.rb -e HolidayWorkRequest`
Expected: FAIL（HWR 行が描画されない）

- [ ] **Step 4: Component を実装**

`app/components/approvals/holiday_work_request_row_component.rb`:

```ruby
# frozen_string_literal: true

module Approvals
  # 承認インボックスの HolidayWorkRequest 行（2-4 設計 §3.4）。approvable_type 別描画の 3 つ目。
  class HolidayWorkRequestRowComponent < ViewComponent::Base
    def initialize(assignment:)
      @assignment = assignment
      @hwr = assignment.approvable
    end

    def stage_label
      @hwr.single_stage? ? "単段（独立性なし）" : "第 #{@assignment.position} 段階"
    end
  end
end
```

`app/components/approvals/holiday_work_request_row_component.html.erb`:

```erb
<div class="border rounded p-4 mb-3" data-approval-row>
  <div class="font-medium"><%= @hwr.requester.name %> ／ 休日出勤</div>
  <div class="text-sm text-gray-600">
    出勤予定日 <%= @hwr.work_date %>／代償 <%= @hwr.compensation_leave_type.name %>
    <span class="ml-2"><%= stage_label %></span>
  </div>
  <% if @hwr.reason.present? %>
    <div class="text-sm text-gray-500 mt-1"><%= @hwr.reason %></div>
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

- [ ] **Step 5: インボックス index に分岐を追加**

`app/views/approval_assignments/index.html.erb` の `when ClockChangeRequest` の後に追記:

```erb
      <% when HolidayWorkRequest %>
        <%= render Approvals::HolidayWorkRequestRowComponent.new(assignment:) %>
```

- [ ] **Step 6: テストが通ることを確認**

Run: `bundle exec rspec spec/requests/approval_assignments_spec.rb`
Expected: PASS（既存 LeaveRequest/CCR 行も緑）

- [ ] **Step 7: コミット**

```bash
bundle exec rubocop --force-exclusion app/components/approvals/holiday_work_request_row_component.rb spec/requests/approval_assignments_spec.rb
git add app/components/approvals/holiday_work_request_row_component.* app/views/approval_assignments/index.html.erb config/locales/ja.yml spec/requests/approval_assignments_spec.rb
git commit -m "feat: 承認インボックスに HWR 行 + i18n（型別描画の3つ目・2-4）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: スイート全体 + ROADMAP 完了マーク + backlog

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: 全スイート + 静的解析**

Run:
```bash
bundle exec rspec
bundle exec rubocop
bin/brakeman --no-pager
```
Expected: rspec 全緑・rubocop 0 offenses・brakeman 0 warnings。落ちたら該当 Task に戻って修正（緑になるまで完了報告しない）

- [ ] **Step 2: ROADMAP 2-4 を完了マーク**

`docs/ROADMAP.md` の 2-4 行を更新（PR 番号は作成後に追記）:

```markdown
- [x] **2-4 HolidayWorkRequest**: 4 値ステータス・代休残高 +1（balance_tracked? で消費と対称化）・is_holiday_work 双方向連動（承認=予約＋既存AR付与 / ClockIn・ProxyClockIn=事前付与）・承認時平日性再検証（ConflictError）・代休限定（振替後置）（PR #XX）
```

- [ ] **Step 3: backlog を追記**

`docs/ROADMAP.md` の「横断バックログ」に以下を追記:

```markdown
- [ ] **振替休日（substitute_holiday）の実装**: 振替元休日・振替先労働日の事前特定モデリング + 35% 抑制根拠 + balance_tracked? への substitute_holiday 追加可否再判断（2-4 で代休限定・SPEC §6.11 事前特定ノート）
- [ ] **HWR 承認↔打刻 write-skew の整合バッチ**: 承認 tx と ClockIn tx の競合で is_holiday_work が false 確定し得る。Phase 4-2 で「approved HWR × 当日 AR あり × is_holiday_work=false」を未打刻検出と同じ走査で補正（2-4 Codex C1・finalize 前ゲート）
- [ ] **代休の事前消費ハザード**: 実勤務前/未打刻で代休消費→取消で負残高。Phase 4-2 の取消フローで負残高/差戻し処理 + 社労士確認（2-4 Codex C4・finalize 前ゲート）
- [ ] **Phase 3-1 の 35% 母数**: holiday_work_hours は is_holiday_work AND day_type==legal_holiday で確定（所定休日労働は対象外）。未登録日曜フォールバックの漏れは §4.7「要確認」と整合（2-4 R4/Codex C5）
- [ ] **代休 LeaveBalance の繰越除外**: 年度繰越ジョブ（Phase 4-4）のフィルタを paid_annual? に限定し代休を含めない（2-4 R8）
```

- [ ] **Step 4: コミット**

```bash
git add docs/ROADMAP.md
git commit -m "docs: ROADMAP 2-4 完了マーク + HWR 後続 backlog（write-skew/事前消費/35%母数/繰越除外）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 5: レビュー（merge 前）**

- `tenant-isolation-reviewer`（HWR model/migration・ClockIn/ProxyClockIn 改修・複合 FK・partial unique）
- `labor-law-compliance-reviewer` + `/legal-citation-audit`（代休残高・35% 前提・振替後置・事前消費ハザード）
- `/preflight`（CI 等価チェック）→ PR 作成（squash）→ ROADMAP に PR 番号追記

---

## Self-Review（計画 vs spec）

**1. Spec coverage:**
- §1.1 HWR モデル+migration → Task 2 ✅／§1.2 is_holiday_work カラム → Task 3 ✅／§1.3 balance_tracked? → Task 1 ✅
- §2.1 Create → Task 6 ✅／§2.2 ApplyApproval（①再検証②balance③flag・savepoint）→ Task 4 ✅／§2.3 User 述語 → Task 3 ✅／§2.4 ClockIn/ProxyClockIn → Task 7 ✅／§2.5 add_to_balance 一般化 → Task 5 ✅
- §3.1 Controller（strong params・cancel authorize）→ Task 9 ✅／§3.2 Policy → Task 8 ✅／§3.3 Views（chips 無し）→ Task 9 ✅／§3.4 Component+分岐 → Task 10 ✅／§3.5 routes → Task 9 ✅／§3.6 i18n → Task 10 ✅
- §4 テスト（孤児AR非作成・並行二重付与stub・代休over-balance境界・no-recalc計算済AR・FK二層・ProxyClockIn主体・#3単段縮約）→ Task 2/4/5/7/10 に分散 ✅（#3 単段縮約は Task 10 の結合 or Task 8 policy で固定。Task 10 の注に従い構成を合わせる）
- §5 handoff backlog → Task 11 ✅

**2. Placeholder scan:** 各 Step に完全コード・実コマンド・期待出力を記載。`<ts>` は migration 生成で確定する実タイムスタンプの意（generate コマンドで解決）。PR #XX は作成後に確定。

**3. Type consistency:** `balance_tracked?`（Task 1 → Task 4/5 で消費）・`holiday_work_reserved_on?(date)`（Task 3 → Task 7）・`HolidayWorkRequests::ApplyApproval.call(holiday_work_request:, acting_user:)`（Task 4 ← Task 2 hook）・`HolidayWorkRequests::Create.call(requester:, work_date:, compensation_leave_type:, reason:)`（Task 6 ← Task 9 controller）— シグネチャ一貫。

**4. 既知の調整点（実装中に緑化しながら微修正）:** Task 4 の ① rollback テストの tx 包み／Task 9 index view の i18n 依存（Task 10 と順序）／各 spec の既存 `let`/`sign_in`/`host!` 作法への整合。いずれも構造でなく記述レベル。
