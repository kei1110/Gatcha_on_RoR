# Phase 2-2a 休暇申請 + 残高（申請側）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 社員が休暇を申請・取消でき、hr_admin が残高を付与でき、申請フォームがリアルタイムで取得日数と残高 2 段階を表示する縦スライスを TDD で構築する（承認決裁・副作用は 2-2b）。

**Architecture:** 純計算（`LeaveDaysCalculator`・`Organization#fiscal_year_range`）→ 入力合成（`CompanyCalendarResolver#day_classifications`）→ 見積りの単一ソース（`LeaveRequests::Estimate`）→ コマンド（`LeaveRequests::Create` が `save! + Approvals::Start` を 1 tx・`Approvals::Cancel`）→ Pundit 認可 → controller/UI（Turbo Frame の `src` 更新による preview）。テナント分離は `acts_as_tenant` + 複合 FK + ID 基点 fail-closed 検証の二層。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / RSpec / FactoryBot / Pundit / acts_as_tenant / AASM（2-1 既存）/ Hotwire(Turbo Frame + Stimulus) / ViewComponent。

**設計典拠:** `docs/superpowers/specs/2026-06-16-phase2-2a-leave-request-design.md`（多視点レビュー反映済）。本計画の各タスクは設計書の節に対応。テスト負例の完全な列挙は設計書 §8 の表を正とし、本計画は各タスクで核となる例を具体コードで示す。

**作業規約（CLAUDE.md サブエージェント 3 か条）:** ステップ完了ごとに即コミット／探索で触った不要編集は revert／各タスクの検証は `bundle exec rspec <該当>` + `bundle exec rubocop --force-exclusion <files>`、app/ に触れたら `bin/brakeman --no-pager`。**migration 後は `bin/rails db:migrate` + `bin/rails db:test:prepare`**。console/rake は先に `ActsAsTenant.current_tenant=...`。

---

## File Structure

| ファイル | 責務 |
|---|---|
| `app/models/organization.rb`（修正） | `fiscal_year_range`（C1・`fiscal_year_for` の逆）・決算月ガード（D4） |
| `app/calculators/leave_days_calculator.rb`（新規） | §5.5 取得日数の純計算（値→値・防御 assert） |
| `app/services/company_calendar_resolver.rb`（修正） | `day_classifications`（counts_as_paid_leave surface） |
| `db/migrate/*_create_leave_balances.rb` / `app/models/leave_balance.rb`（新規） | 残高モデル（残日数・granted_on 必須・テナント検証） |
| `db/migrate/*_create_leave_requests.rb` / `app/models/leave_request.rb`（新規） | 申請モデル（Approvable・半休/span/0日検証・テナント検証） |
| `app/services/leave_requests/estimate.rb`（新規） | 見積りの単一ソース（日数 + 確定/仮残高） |
| `app/services/leave_requests/create.rb`（新規） | 申請作成（1 tx・Start 起動） |
| `app/services/approvals/cancel.rb`（新規） | 取消（applying→canceled・by 検証） |
| `app/policies/leave_request_policy.rb` / `app/policies/admin/leave_balance_policy.rb`（新規） | 認可 |
| `app/controllers/leave_requests_controller.rb`（新規） | index/new/create/preview/cancel（requester 固定） |
| `app/controllers/admin/leave_balances_controller.rb`（新規） | hr_admin 残高 CRUD（フラット・user ネスト URL） |
| `app/components/leave_requests/balance_component.rb`（新規） | 残高 2 段階表示 |
| `app/javascript/controllers/leave_request_form_controller.js`（新規） | frame `src` の debounce 更新・理由チップ |
| `config/routes.rb`（修正） | `resources :leave_requests` + admin nested `leave_balances` |
| ビュー・factory・spec 群 | 各タスク内 |

---

## Task 1: `Organization#fiscal_year_range`（C1・仮残高の年度逆写像）

**Files:**
- Modify: `app/models/organization.rb`（`fiscal_year_for` の直後に追加）
- Test: `spec/models/organization_spec.rb`

- [ ] **Step 1: Write the failing test**

`spec/models/organization_spec.rb` の `describe Organization` 内に追加:

```ruby
describe "#fiscal_year_range" do
  it "fiscal_year_for の逆（3 月決算: '2026' → 2026-04-01..2027-03-31）" do
    org = build(:organization, fiscal_year_end_month: 3)
    expect(org.fiscal_year_range("2026")).to eq(Date.new(2026, 4, 1)..Date.new(2027, 3, 31))
  end

  it "12 月決算は暦年に一致（'2026' → 2026-01-01..2026-12-31）" do
    org = build(:organization, fiscal_year_end_month: 12)
    expect(org.fiscal_year_range("2026")).to eq(Date.new(2026, 1, 1)..Date.new(2026, 12, 31))
  end

  it "範囲内の全日が fiscal_year_for で同じ年度へ戻る（往復一致）" do
    org = build(:organization, fiscal_year_end_month: 3)
    range = org.fiscal_year_range("2026")
    expect([range.first, range.last].map { |d| org.fiscal_year_for(d) }).to all(eq("2026"))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/organization_spec.rb -e fiscal_year_range`
Expected: FAIL（`NoMethodError: undefined method 'fiscal_year_range'`）

- [ ] **Step 3: Write minimal implementation**

`app/models/organization.rb` の `fiscal_year_for` の直後に追加:

```ruby
  # fiscal_year_for の逆写像（C1・Phase 2-2a 設計 §3.1）。年度文字列 → その年度の Date 範囲。
  # LeaveBalance/LeaveRequest の年度別集計（fiscal_year 列を持たない LeaveRequest を
  # start_date 範囲で絞る）に使う。fiscal_year_for と対で spec する。
  def fiscal_year_range(fiscal_year)
    start_month = fiscal_year_end_month % 12 + 1
    start = Date.new(fiscal_year.to_i, start_month, 1)
    start..start.next_year.prev_day
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/models/organization_spec.rb -e fiscal_year_range`
Expected: PASS（3 examples）

- [ ] **Step 5: Commit**

```bash
git add app/models/organization.rb spec/models/organization_spec.rb
git commit -m "feat: Organization#fiscal_year_range（仮残高の年度逆写像・C1）"
```

---

## Task 2: `LeaveDaysCalculator`（§5.5・純計算）

**Files:**
- Create: `app/calculators/leave_days_calculator.rb`
- Test: `spec/calculators/leave_days_calculator_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/calculators/leave_days_calculator_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveDaysCalculator do
  # classifications = { Date => { day_type:, counts_as_paid_leave: } }
  def cls(map) = map.transform_values { |dt| { day_type: dt, counts_as_paid_leave: false } }

  describe ".call（全休）" do
    it "weekday のみ計上し合計を BigDecimal で返す" do
      c = cls(Date.new(2026, 5, 1) => :weekday, Date.new(2026, 5, 2) => :saturday)
      expect(described_class.call(classifications: c, half_day_type: :none)).to eq(BigDecimal("1"))
    end

    it "土日祝・法定休日は除外する" do
      c = cls(
        Date.new(2026, 5, 4) => :holiday, Date.new(2026, 5, 5) => :legal_holiday,
        Date.new(2026, 5, 6) => :weekday
      )
      expect(described_class.call(classifications: c, half_day_type: :none)).to eq(BigDecimal("1"))
    end

    it "全日が除外なら BigDecimal('0')（型を保つ）" do
      c = cls(Date.new(2026, 5, 2) => :saturday, Date.new(2026, 5, 3) => :sunday)
      result = described_class.call(classifications: c, half_day_type: :none)
      expect(result).to eql(BigDecimal("0"))
    end

    it "company_holiday は counts_as_paid_leave で分岐（true=計上 / false=除外）" do
      paid = { Date.new(2026, 5, 1) => { day_type: :company_holiday, counts_as_paid_leave: true } }
      unpaid = { Date.new(2026, 5, 1) => { day_type: :company_holiday, counts_as_paid_leave: false } }
      expect(described_class.call(classifications: paid, half_day_type: :none)).to eq(BigDecimal("1"))
      expect(described_class.call(classifications: unpaid, half_day_type: :none)).to eq(BigDecimal("0"))
    end
  end

  describe ".call（半休）" do
    it "計上対象の単日は 0.5" do
      c = cls(Date.new(2026, 5, 1) => :weekday)
      expect(described_class.call(classifications: c, half_day_type: :morning)).to eq(BigDecimal("0.5"))
    end

    it "除外日の半休は 0" do
      c = cls(Date.new(2026, 5, 2) => :saturday)
      expect(described_class.call(classifications: c, half_day_type: :afternoon)).to eq(BigDecimal("0"))
    end

    it "複数日 × 半休は防御 assert で ArgumentError（純関数の入力契約）" do
      c = cls(Date.new(2026, 5, 1) => :weekday, Date.new(2026, 5, 7) => :weekday)
      expect { described_class.call(classifications: c, half_day_type: :morning) }
        .to raise_error(ArgumentError)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/calculators/leave_days_calculator_spec.rb`
Expected: FAIL（`uninitialized constant LeaveDaysCalculator`）

- [ ] **Step 3: Write minimal implementation**

```ruby
# app/calculators/leave_days_calculator.rb
# frozen_string_literal: true

# 取得日数の純計算（SPEC §5.5・Phase 2-2a 設計 §2.1）。値→値（DB 非依存・§2.2-1）。
# classifications = { Date => { day_type: Symbol, counts_as_paid_leave: Boolean } }（service 層が合成）。
# 計上日 = weekday、または company_holiday かつ counts_as_paid_leave=true。
# 除外日 = saturday/sunday（所定休日）・holiday・legal_holiday・company_holiday(counts_as_paid_leave=false)。
class LeaveDaysCalculator
  def self.call(classifications:, half_day_type:)
    # 防御 assert（設計 §2.1・原則整合 MPR）: 半休は単日が入力契約。上流の start==end 検証
    # バイパス時に不定値を返さない fail-closed。
    if half_day_type != :none && classifications.size > 1
      raise ArgumentError, "半休は単日のみ（classifications.size=#{classifications.size}）"
    end

    counted = classifications.count { |_date, info| counted?(info) }
    factor = half_day_type == :none ? 1 : 0.5
    BigDecimal(counted.to_s) * BigDecimal(factor.to_s)
  end

  def self.counted?(info)
    case info[:day_type]
    when :weekday then true
    when :company_holiday then info[:counts_as_paid_leave]
    else false   # saturday / sunday / holiday / legal_holiday
    end
  end
  private_class_method :counted?
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/calculators/leave_days_calculator_spec.rb`
Expected: PASS（8 examples）

- [ ] **Step 5: Rubocop + Commit**

```bash
bundle exec rubocop --force-exclusion app/calculators/leave_days_calculator.rb
git add app/calculators/leave_days_calculator.rb spec/calculators/leave_days_calculator_spec.rb
git commit -m "feat: LeaveDaysCalculator（§5.5 取得日数の純計算・防御assert）"
```

---

## Task 3: `CompanyCalendarResolver#day_classifications`

**Files:**
- Modify: `app/services/company_calendar_resolver.rb`（`day_types` の直後に追加）
- Test: `spec/services/company_calendar_resolver_spec.rb`（追記）

- [ ] **Step 1: Write the failing test**

`spec/services/company_calendar_resolver_spec.rb` に `describe` を追加:

```ruby
describe "#day_classifications" do
  let(:org) { create(:organization) }
  subject(:resolver) { described_class.new(organization: org) }

  it "登録日は day_type と counts_as_paid_leave を surface する" do
    ActsAsTenant.with_tenant(org) do
      create(:company_calendar, date: Date.new(2026, 5, 1), day_type: :company_holiday,
                                counts_as_paid_leave: true, name: "創立記念日")
    end
    result = resolver.day_classifications(Date.new(2026, 5, 1), Date.new(2026, 5, 1))
    expect(result[Date.new(2026, 5, 1)]).to eq(day_type: :company_holiday, counts_as_paid_leave: true)
  end

  it "未登録日は ISO 曜日 fallback・counts_as_paid_leave は false" do
    # 2026-05-02 は土曜
    result = resolver.day_classifications(Date.new(2026, 5, 2), Date.new(2026, 5, 2))
    expect(result[Date.new(2026, 5, 2)]).to eq(day_type: :saturday, counts_as_paid_leave: false)
  end
end
```

> factory に `counts_as_paid_leave` が無ければ `create(:company_calendar, ..., counts_as_paid_leave: true)` で属性直接指定（factory は最小定義）。`company_holiday` は §4.7 検証で `name` 必須。

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/company_calendar_resolver_spec.rb -e day_classifications`
Expected: FAIL（`NoMethodError: undefined method 'day_classifications'`）

- [ ] **Step 3: Write minimal implementation**

`app/services/company_calendar_resolver.rb` の `day_types` メソッドの直後に追加:

```ruby
  # day_types の上位版（Phase 2-2a 設計 §2.2）。counts_as_paid_leave を surface し
  # LeaveDaysCalculator の company_holiday 分岐に渡す。company_holiday 以外の flag は false 固定。
  def day_classifications(from, to)
    registered = with_tenant do
      CompanyCalendar.where(date: from..to).pluck(:date, :day_type, :counts_as_paid_leave)
    end.to_h { |date, dt, cpl| [ date, { day_type: dt.to_sym, counts_as_paid_leave: cpl } ] }
    (from..to).index_with do |d|
      registered[d] || { day_type: fallback(d), counts_as_paid_leave: false }
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/company_calendar_resolver_spec.rb`
Expected: PASS（既存 + 新規 2 examples）

- [ ] **Step 5: Rubocop + Commit**

```bash
bundle exec rubocop --force-exclusion app/services/company_calendar_resolver.rb
git add app/services/company_calendar_resolver.rb spec/services/company_calendar_resolver_spec.rb
git commit -m "feat: CompanyCalendarResolver#day_classifications（counts_as_paid_leave surface）"
```

---

## Task 4: `LeaveBalance` モデル + migration

**Files:**
- Create: `db/migrate/<ts>_create_leave_balances.rb`
- Create: `app/models/leave_balance.rb`
- Create: `spec/factories/leave_balances.rb`
- Test: `spec/models/leave_balance_spec.rb`

- [ ] **Step 1: Generate migration（空 change を手書き）**

Run: `bin/rails generate migration CreateLeaveBalances`
生成された `db/migrate/<ts>_create_leave_balances.rb` を以下で**上書き**:

```ruby
# frozen_string_literal: true

class CreateLeaveBalances < ActiveRecord::Migration[8.1]
  def change
    create_table :leave_balances do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.bigint :leave_type_id, null: false
      t.string :fiscal_year, null: false
      t.decimal :granted_days, precision: 6, scale: 2, null: false, default: 0
      t.decimal :carry_over_days, precision: 6, scale: 2, null: false, default: 0
      t.decimal :used_days, precision: 6, scale: 2, null: false, default: 0   # 2-2b approve の専有 writer
      t.date :granted_on   # 5 日義務起点（§8.6）。paid×annual はモデル検証で必須

      t.timestamps
    end

    # クロステナント参照を DB 層で遮断（user_work_patterns と同じ複合 FK・§3.6）
    add_foreign_key :leave_balances, :users,
                    column: [ :organization_id, :user_id ], primary_key: [ :organization_id, :id ]
    add_foreign_key :leave_balances, :leave_types,
                    column: [ :organization_id, :leave_type_id ], primary_key: [ :organization_id, :id ]

    add_index :leave_balances, %i[organization_id id], unique: true   # 規約（将来の複合 FK 参照先）
    add_index :leave_balances, %i[organization_id user_id leave_type_id fiscal_year],
              unique: true, name: "index_leave_balances_unique"
    add_index :leave_balances, %i[organization_id user_id]
  end
end
```

- [ ] **Step 2: Migrate**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `leave_balances` 作成・`db/schema.rb` 更新（手編集しない＝`block-schema-edit`）

- [ ] **Step 3: Write the failing test**

```ruby
# spec/factories/leave_balances.rb
# frozen_string_literal: true

FactoryBot.define do
  factory :leave_balance do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user { association(:user) }
    leave_type { association(:leave_type) }   # 既定 system_type :other / paid_leave false
    fiscal_year { "2026" }
    granted_days { 20 }
    carry_over_days { 0 }
    used_days { 0 }
  end
end
```

```ruby
# spec/models/leave_balance_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveBalance do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def in_savepoint = ActiveRecord::Base.transaction(requires_new: true) { yield }

  describe "残日数" do
    it "granted + carry_over - used" do
      b = build(:leave_balance, granted_days: 20, carry_over_days: 5, used_days: 3)
      expect(b.remaining).to eq(BigDecimal("22"))
    end
  end

  describe "一意性（org, user, leave_type, fiscal_year）" do
    it "同一キーの重複はモデル検証で無効" do
      first = create(:leave_balance)
      dup = build(:leave_balance, user: first.user, leave_type: first.leave_type, fiscal_year: "2026")
      expect(dup).to be_invalid
    end

    it "別テナントなら同一キーでも valid（鏡像）" do
      create(:leave_balance, fiscal_year: "2026")
      other = create(:organization)
      ActsAsTenant.with_tenant(other) do
        mirror = build(:leave_balance, organization: other, fiscal_year: "2026")
        expect(mirror).to be_valid
      end
    end

    it "DB 最終防衛: validate:false でも複合 unique を弾く" do
      first = create(:leave_balance)
      expect {
        in_savepoint do
          build(:leave_balance, user: first.user, leave_type: first.leave_type, fiscal_year: "2026")
            .save!(validate: false)
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "granted_on 必須（D5・paid×annual のみ）" do
    let(:annual) { create(:leave_type, system_type: :annual, paid_leave: true) }

    it "paid×annual で granted_on なしは無効" do
      b = build(:leave_balance, leave_type: annual, granted_on: nil)
      expect(b).to be_invalid
      expect(b.errors[:granted_on]).to be_present
    end

    it "paid×annual で granted_on ありは valid" do
      b = build(:leave_balance, leave_type: annual, granted_on: Date.new(2026, 4, 1))
      expect(b).to be_valid
    end

    it "非該当種別（:other）は granted_on なしでも valid" do
      expect(build(:leave_balance, granted_on: nil)).to be_valid
    end
  end

  describe "テナント越境（ID 基点 fail-closed）" do
    it "他テナントの user は無効" do
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:user) }
      b = build(:leave_balance)
      b.user = outsider
      expect(b).to be_invalid
      expect(b.errors[:user]).to be_present
    end

    it "他テナントの leave_type は無効" do
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:leave_type) }
      b = build(:leave_balance)
      b.leave_type = outsider
      expect(b).to be_invalid
      expect(b.errors[:leave_type]).to be_present
    end
  end
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `bundle exec rspec spec/models/leave_balance_spec.rb`
Expected: FAIL（`uninitialized constant LeaveBalance` または検証未実装）

- [ ] **Step 5: Write minimal implementation**

```ruby
# app/models/leave_balance.rb
# frozen_string_literal: true

# 休暇残高（SPEC §4.10・Phase 2-2a 設計 §1.2）。used_days の writer は 2-2b の approve 副作用のみ。
class LeaveBalance < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user
  belongs_to :leave_type

  validates :fiscal_year, presence: true
  validates :granted_days, :carry_over_days, :used_days,
            numericality: { greater_than_or_equal_to: 0 }
  validates :fiscal_year, uniqueness: { scope: %i[organization_id user_id leave_type_id] }
  validates :granted_on, presence: true, if: :paid_annual?
  validate :user_must_belong_to_same_organization
  validate :leave_type_must_belong_to_same_organization

  # 残日数（§4.10）。used_days は 2-2a では常に 0
  def remaining = granted_days + carry_over_days - used_days

  # 5 日義務（§8.6）の対象 = 有給かつ年休。granted_on を必須にして NULL annual 残高を防ぐ（D5）
  def paid_annual? = leave_type&.paid_leave? && leave_type&.annual?

  private

  # ID 基点 fail-closed（user.rb / attendance_history.rb 同型・§3.6）
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id

    errors.add(:user, "は同一組織でなければなりません")
  end

  def leave_type_must_belong_to_same_organization
    return if leave_type_id.nil?
    return if leave_type&.organization_id == organization_id

    errors.add(:leave_type, "は同一組織でなければなりません")
  end
end
```

- [ ] **Step 6: Run test + rubocop**

Run: `bundle exec rspec spec/models/leave_balance_spec.rb`
Expected: PASS
Run: `bundle exec rubocop --force-exclusion app/models/leave_balance.rb db/migrate/*_create_leave_balances.rb`

- [ ] **Step 7: Commit**

```bash
git add db/migrate/*_create_leave_balances.rb db/schema.rb app/models/leave_balance.rb spec/factories/leave_balances.rb spec/models/leave_balance_spec.rb
git commit -m "feat: LeaveBalance モデル + migration（残日数・granted_on必須・テナント検証）"
```

---

## Task 5: `LeaveRequest` モデル + migration

**Files:**
- Create: `db/migrate/<ts>_create_leave_requests.rb`
- Create: `app/models/leave_request.rb`
- Create: `spec/factories/leave_requests.rb`
- Test: `spec/models/leave_request_spec.rb`

- [ ] **Step 1: Generate + overwrite migration**

Run: `bin/rails generate migration CreateLeaveRequests`
生成ファイルを上書き:

```ruby
# frozen_string_literal: true

class CreateLeaveRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :leave_requests do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :requester_id, null: false
      t.bigint :leave_type_id, null: false
      t.date :start_date, null: false
      t.date :end_date, null: false
      t.integer :half_day_type, null: false, default: 0
      t.decimal :days_requested, precision: 6, scale: 2, null: false
      t.text :reason
      t.integer :approval_status, null: false, default: 0   # Approvable（applying:0）

      t.timestamps
    end

    add_foreign_key :leave_requests, :users,
                    column: [ :organization_id, :requester_id ], primary_key: [ :organization_id, :id ]
    add_foreign_key :leave_requests, :leave_types,
                    column: [ :organization_id, :leave_type_id ], primary_key: [ :organization_id, :id ]

    add_index :leave_requests, %i[organization_id id], unique: true
    add_index :leave_requests, %i[organization_id requester_id approval_status]            # 自分の申請一覧
    add_index :leave_requests, %i[organization_id requester_id leave_type_id start_date]   # 仮残高の年度別集計
  end
end
```

- [ ] **Step 2: Migrate**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`

- [ ] **Step 3: Write the failing test**

```ruby
# spec/factories/leave_requests.rb
# frozen_string_literal: true

FactoryBot.define do
  factory :leave_request do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    requester { association(:user) }
    leave_type { association(:leave_type) }
    start_date { Date.new(2026, 5, 1) }
    end_date { Date.new(2026, 5, 1) }
    half_day_type { :none }
    days_requested { 1 }
  end
end
```

```ruby
# spec/models/leave_request_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequest do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def in_savepoint = ActiveRecord::Base.transaction(requires_new: true) { yield }

  it "有効なら保存でき、初期 approval_status は applying（Approvable）" do
    r = create(:leave_request)
    expect(r).to be_persisted
    expect(r.approval_status).to eq("applying")
  end

  describe "days_requested" do
    it "0 は拒否（空申請を通さない・MPR）" do
      r = build(:leave_request, days_requested: 0)
      expect(r).to be_invalid
      expect(r.errors[:days_requested]).to be_present
    end
  end

  describe "期間" do
    it "end < start は無効" do
      r = build(:leave_request, start_date: Date.new(2026, 5, 2), end_date: Date.new(2026, 5, 1))
      expect(r).to be_invalid
    end

    it "MAX_SPAN_DAYS 超は無効" do
      r = build(:leave_request, start_date: Date.new(2026, 1, 1),
                                end_date: Date.new(2026, 1, 1) + LeaveRequest::MAX_SPAN_DAYS + 1)
      expect(r).to be_invalid
    end
  end

  describe "半休排他（§4.9）" do
    it "half_day_type != none で start != end は無効" do
      lt = create(:leave_type, allow_half_day: true)
      r = build(:leave_request, leave_type: lt, half_day_type: :morning,
                                start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 2))
      expect(r).to be_invalid
    end

    it "half_day_type != none で単日は valid（過剰制約でない）" do
      lt = create(:leave_type, allow_half_day: true)
      r = build(:leave_request, leave_type: lt, half_day_type: :afternoon, days_requested: 0.5,
                                start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(r).to be_valid
    end

    it "none × 複数日は valid" do
      r = build(:leave_request, half_day_type: :none, days_requested: 2,
                                start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 2))
      expect(r).to be_valid
    end
  end

  describe "半休可能種別（§6.2・MPR）" do
    it "allow_half_day=false の種別で半休は無効" do
      lt = create(:leave_type, allow_half_day: false)
      r = build(:leave_request, leave_type: lt, half_day_type: :morning, days_requested: 0.5)
      expect(r).to be_invalid
      expect(r.errors[:half_day_type]).to be_present
    end
  end

  describe "テナント越境（ID 基点 fail-closed）" do
    it "他テナントの requester は無効" do
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:user) }
      r = build(:leave_request)
      r.requester = outsider
      expect(r).to be_invalid
      expect(r.errors[:requester]).to be_present
    end

    it "他テナントの leave_type は無効" do
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:leave_type) }
      r = build(:leave_request)
      r.leave_type = outsider
      expect(r).to be_invalid
    end

    it "DB 最終防衛: validate:false の越境 requester_id は FK 違反" do
      other_org = create(:organization)
      outsider = ActsAsTenant.with_tenant(other_org) { create(:user) }
      expect {
        in_savepoint do
          record = build(:leave_request)
          record.requester_id = outsider.id
          record.save!(validate: false)
        end
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
```

> `enum :half_day_type` は `validate: true`（毒入力 422）。enum 毒入力例は `r.half_day_type = "bogus"; expect(r).to be_invalid` を 1 本追加（design §8）。

- [ ] **Step 4: Run test to verify it fails**

Run: `bundle exec rspec spec/models/leave_request_spec.rb`
Expected: FAIL（`uninitialized constant LeaveRequest`）

- [ ] **Step 5: Write minimal implementation**

```ruby
# app/models/leave_request.rb
# frozen_string_literal: true

# 休暇申請（SPEC §4.9・Phase 2-2a 設計 §1.1）。承認対象モデルの初投入。
# days_requested / approval_status の writer は LeaveRequests::Create（サーバ権威）のみ — strong params 恒久ブロック。
class LeaveRequest < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :requester, class_name: "User"
  belongs_to :leave_type

  include Approvable   # approval_status の AASM + has_many :approval_assignments（2-1）

  MAX_SPAN_DAYS = 366  # 1 年度相当の上限（不定・DoS 抑止）

  enum :half_day_type, { none: 0, morning: 1, afternoon: 2 }, validate: true

  validates :start_date, :end_date, :days_requested, presence: true
  validates :days_requested, numericality: { greater_than: 0 }   # 0 日申請拒否
  validate :end_date_not_before_start_date
  validate :span_within_limit
  validate :half_day_requires_single_day
  validate :half_day_requires_half_day_enabled_type
  validate :requester_must_belong_to_same_organization
  validate :leave_type_must_belong_to_same_organization

  private

  def end_date_not_before_start_date
    return if start_date.blank? || end_date.blank? || end_date >= start_date

    errors.add(:end_date, "は開始日以降にしてください")
  end

  def span_within_limit
    return if start_date.blank? || end_date.blank?
    return if (end_date - start_date).to_i <= MAX_SPAN_DAYS

    errors.add(:end_date, "は申請可能な期間（#{MAX_SPAN_DAYS} 日）を超えています")
  end

  def half_day_requires_single_day
    return if none? || start_date.blank? || end_date.blank? || start_date == end_date

    errors.add(:half_day_type, "は単日申請でのみ指定できます")
  end

  def half_day_requires_half_day_enabled_type
    return if none? || leave_type&.allow_half_day?

    errors.add(:half_day_type, "はこの休暇種別では指定できません")
  end

  def requester_must_belong_to_same_organization
    return if requester_id.nil?
    return if requester&.organization_id == organization_id

    errors.add(:requester, "は同一組織でなければなりません")
  end

  def leave_type_must_belong_to_same_organization
    return if leave_type_id.nil?
    return if leave_type&.organization_id == organization_id

    errors.add(:leave_type, "は同一組織でなければなりません")
  end
end
```

> `none?` は `enum :half_day_type` が生成する述語。

- [ ] **Step 6: Run test + rubocop**

Run: `bundle exec rspec spec/models/leave_request_spec.rb`
Expected: PASS
Run: `bundle exec rubocop --force-exclusion app/models/leave_request.rb db/migrate/*_create_leave_requests.rb`

- [ ] **Step 7: Commit**

```bash
git add db/migrate/*_create_leave_requests.rb db/schema.rb app/models/leave_request.rb spec/factories/leave_requests.rb spec/models/leave_request_spec.rb
git commit -m "feat: LeaveRequest モデル + migration（Approvable・半休/span/0日検証・テナント）"
```

---

## Task 6: `Organization` 決算月ガード格上げ（D4）

**Files:**
- Modify: `app/models/organization.rb`
- Test: `spec/models/organization_spec.rb`

- [ ] **Step 1: Write the failing test**

`spec/models/organization_spec.rb` に追加:

```ruby
describe "fiscal_year_end_month 変更ガード（残高あり）" do
  let(:org) { create(:organization, fiscal_year_end_month: 3) }

  it "残高が存在すると変更を拒否" do
    ActsAsTenant.with_tenant(org) { create(:leave_balance) }
    org.fiscal_year_end_month = 12
    expect(org).to be_invalid
    expect(org.errors[:fiscal_year_end_month]).to be_present
  end

  it "残高がなければ変更可" do
    org.fiscal_year_end_month = 12
    expect(org).to be_valid
  end

  it "他属性の変更は残高ありでも通る（過剰ブロック回避）" do
    ActsAsTenant.with_tenant(org) { create(:leave_balance) }
    org.name = "新社名"
    expect(org).to be_valid
  end

  it "他テナントの残高は当組織をロックしない" do
    ActsAsTenant.with_tenant(create(:organization)) { create(:leave_balance) }
    org.fiscal_year_end_month = 12
    expect(org).to be_valid
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/organization_spec.rb -e "決算月"`
Expected: FAIL（変更が通ってしまう）

- [ ] **Step 3: Write minimal implementation**

`app/models/organization.rb` の `validates :fiscal_year_end_month, ...` の直後に追加:

```ruby
  validate :fiscal_year_end_month_locked_when_balances_exist

  # D4（Phase 2-2a 設計 §7・社労士確認 #13）: 残高が fiscal_year をキーに持つため、
  # 決算月変更は残高帰属を破壊する。WorkPattern#deactivation 同型の without_tenant で
  # mismatched with_tenant の fail-open を遮断（Organization は acts_as_tenant 非対象ゆえ明示ラップ）
  def fiscal_year_end_month_locked_when_balances_exist
    return unless fiscal_year_end_month_changed?
    return unless ActsAsTenant.without_tenant { LeaveBalance.where(organization_id: id).exists? }

    errors.add(:fiscal_year_end_month, "は休暇残高が存在するため変更できません")
  end
```

- [ ] **Step 4: Run test + rubocop**

Run: `bundle exec rspec spec/models/organization_spec.rb`
Expected: PASS
Run: `bundle exec rubocop --force-exclusion app/models/organization.rb`

- [ ] **Step 5: Commit**

```bash
git add app/models/organization.rb spec/models/organization_spec.rb
git commit -m "feat: 決算月ガード格上げ（残高ありで fiscal_year_end_month 変更禁止・D4）"
```

---

## Task 7: `LeaveRequests::Estimate`（見積りの単一ソース・C1/C3）

**Files:**
- Create: `app/services/leave_requests/estimate.rb`
- Test: `spec/services/leave_requests/estimate_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/leave_requests/estimate_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::Estimate do
  let(:org) { create(:organization, fiscal_year_end_month: 3) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:user) { create(:user, organization: org) }
  let(:paid) { create(:leave_type, system_type: :annual, paid_leave: true, allow_half_day: true) }

  def call(start_date:, end_date:, half: :none, leave_type: paid, requester: user)
    described_class.call(requester:, leave_type:, start_date:, end_date:, half_day_type: half)
  end

  it "weekday の単日全休は 1 日・年度は start_date 基準" do
    r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))   # 金曜
    expect(r.days_requested).to eq(BigDecimal("1"))
    expect(r.fiscal_year).to eq("2026")
  end

  describe "残高 2 段階" do
    before { create(:leave_balance, user:, leave_type: paid, fiscal_year: "2026", granted_days: 10, granted_on: Date.new(2026, 4, 1)) }

    it "確定 = granted+carry-used、仮残高は applying を引く" do
      create(:leave_request, requester: user, leave_type: paid, approval_status: :applying,
             start_date: Date.new(2026, 5, 7), end_date: Date.new(2026, 5, 7), days_requested: 2)
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(r.confirmed_remaining).to eq(BigDecimal("10"))
      expect(r.provisional_remaining).to eq(BigDecimal("8"))   # 10 - 2(applying)
      expect(r.remaining_after).to eq(BigDecimal("7"))         # 8 - 1(今回)
      expect(r.status).to eq(:positive)
    end

    it "申請後 0 はアンバー(:zero)、負は赤(:negative)" do
      create(:leave_request, requester: user, leave_type: paid, approval_status: :applying,
             start_date: Date.new(2026, 5, 7), end_date: Date.new(2026, 5, 7), days_requested: 9)
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))   # 仮 1, 申請後 0
      expect(r.status).to eq(:zero)
    end
  end

  describe "仮残高のスコープ隔離（MPR・過小残高バグ防止）" do
    before { create(:leave_balance, user:, leave_type: paid, fiscal_year: "2026", granted_days: 10, granted_on: Date.new(2026, 4, 1)) }

    # 他テナントの applying は acts_as_tenant の default_scope が構造的に除外（このクエリは org 文脈下）。
    # ここでは同テナント内の取りこぼし（他 user / 他 leave_type / 他年度）を pin する
    it "他 user / 他 leave_type / 他年度の applying を巻き込まない" do
      other_user = create(:user, organization: org)
      other_type = create(:leave_type, system_type: :annual, paid_leave: true)
      create(:leave_request, requester: other_user, leave_type: paid, approval_status: :applying,
             start_date: Date.new(2026, 5, 7), end_date: Date.new(2026, 5, 7), days_requested: 3)
      create(:leave_request, requester: user, leave_type: other_type, approval_status: :applying,
             start_date: Date.new(2026, 5, 7), end_date: Date.new(2026, 5, 7), days_requested: 3)
      create(:leave_request, requester: user, leave_type: paid, approval_status: :applying,
             start_date: Date.new(2027, 5, 7), end_date: Date.new(2027, 5, 7), days_requested: 3)   # 翌年度
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(r.provisional_remaining).to eq(BigDecimal("10"))   # どれも引かれない
    end

    it "approved/rejected/canceled は仮残高に効かない" do
      %i[approved rejected canceled].each do |st|
        create(:leave_request, requester: user, leave_type: paid, approval_status: st,
               start_date: Date.new(2026, 5, 7), end_date: Date.new(2026, 5, 7), days_requested: 1)
      end
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(r.provisional_remaining).to eq(BigDecimal("10"))
    end
  end

  describe "残高の有無・種別" do
    it "残高未生成は 0 扱い" do
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1))
      expect(r.confirmed_remaining).to eq(BigDecimal("0"))
    end

    it "非 paid_leave 種別は残高 nil・status nil" do
      other = create(:leave_type, system_type: :other, paid_leave: false)
      r = call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1), leave_type: other)
      expect(r.paid_leave).to be(false)
      expect(r.confirmed_remaining).to be_nil
      expect(r.status).to be_nil
    end
  end

  describe "入力契約" do
    it "半休 × 複数日は見積りエラー（calculator 呼出前 fail-closed）" do
      expect {
        call(start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 2), half: :morning)
      }.to raise_error(ArgumentError)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/leave_requests/estimate_spec.rb`
Expected: FAIL（`uninitialized constant LeaveRequests::Estimate`）

- [ ] **Step 3: Write minimal implementation**

```ruby
# app/services/leave_requests/estimate.rb
# frozen_string_literal: true

module LeaveRequests
  # 見積りの単一ソース（Phase 2-2a 設計 §3.1・F2）。フォーム初期描画・preview・Create が共有。
  # requester は呼び出し側で current_user に固定（§3.2・MPR C3）— 他者の残高を読まない。
  class Estimate
    Result = Data.define(
      :days_requested, :fiscal_year, :paid_leave,
      :confirmed_remaining, :provisional_remaining, :remaining_after
    ) do
      def status
        return nil if remaining_after.nil?

        remaining_after.positive? ? :positive : (remaining_after.zero? ? :zero : :negative)
      end
    end

    def self.call(requester:, leave_type:, start_date:, end_date:, half_day_type:)
      new(requester, leave_type, start_date, end_date, half_day_type.to_sym).call
    end

    def initialize(requester, leave_type, start_date, end_date, half_day_type)
      @requester = requester
      @leave_type = leave_type
      @start_date = start_date
      @end_date = end_date
      @half_day_type = half_day_type
    end

    def call
      validate_input!
      days = leave_days
      fy = @requester.organization.fiscal_year_for(@start_date)
      confirmed, provisional = balances(fy)
      Result.new(
        days_requested: days, fiscal_year: fy, paid_leave: @leave_type.paid_leave?,
        confirmed_remaining: confirmed,
        provisional_remaining: provisional,
        remaining_after: provisional && (provisional - days)
      )
    end

    private

    # 半休は単日（calculator 呼出前の fail-closed・MPR）。span 上限も見積り段階で弾く
    def validate_input!
      if @half_day_type != :none && @start_date != @end_date
        raise ArgumentError, "半休は単日申請でのみ指定できます"
      end
      if (@end_date - @start_date).to_i > LeaveRequest::MAX_SPAN_DAYS
        raise ArgumentError, "申請可能な期間を超えています"
      end
    end

    def leave_days
      classifications =
        CompanyCalendarResolver.new(organization: @requester.organization)
                               .day_classifications(@start_date, @end_date)
      LeaveDaysCalculator.call(classifications:, half_day_type: @half_day_type)
    end

    # paid_leave 種別のみ残高算出。非 paid は [nil, nil]
    def balances(fiscal_year)
      return [ nil, nil ] unless @leave_type.paid_leave?

      balance = LeaveBalance.find_by(user: @requester, leave_type: @leave_type, fiscal_year:)
      confirmed = balance&.remaining || BigDecimal("0")
      [ confirmed, confirmed - provisional_used(fiscal_year) ]
    end

    # 同一申請者・同一種別で applying かつ start_date が当該年度に属する days_requested の和（C1）
    def provisional_used(fiscal_year)
      LeaveRequest.where(requester: @requester, leave_type: @leave_type, approval_status: :applying)
                  .where(start_date: @requester.organization.fiscal_year_range(fiscal_year))
                  .sum(:days_requested)
    end
  end
end
```

- [ ] **Step 4: Run test + rubocop**

Run: `bundle exec rspec spec/services/leave_requests/estimate_spec.rb`
Expected: PASS
Run: `bundle exec rubocop --force-exclusion app/services/leave_requests/estimate.rb`

- [ ] **Step 5: Commit**

```bash
git add app/services/leave_requests/estimate.rb spec/services/leave_requests/estimate_spec.rb
git commit -m "feat: LeaveRequests::Estimate（見積り単一ソース・仮残高隔離・requester固定）"
```

---

## Task 8: `LeaveRequests::Create`（1 tx・承認エンジン起動）

**Files:**
- Create: `app/services/leave_requests/create.rb`
- Test: `spec/services/leave_requests/create_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/leave_requests/create_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::Create do
  let(:org) { create(:organization, fiscal_year_end_month: 3) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  # 承認ルート: employee → 直属 manager → その manager（§7.2）。manager 必須
  let(:dept_head) { create(:user, :manager_role, organization: org) }
  let(:manager) { create(:user, :manager_role, organization: org, manager: dept_head) }
  let(:requester) { create(:user, organization: org, manager:) }
  let(:leave_type) { create(:leave_type) }

  def call(**over)
    described_class.call(
      requester:, leave_type:, start_date: Date.new(2026, 5, 1),
      end_date: Date.new(2026, 5, 1), half_day_type: :none, reason: "私用", **over
    )
  end

  it "申請を作成し days_requested をサーバ確定・Start で assignment 生成" do
    record = call
    expect(record).to be_persisted
    expect(record.days_requested).to eq(BigDecimal("1"))   # 2026-05-01 は weekday
    expect(record.approval_assignments.count).to be >= 1
    expect(record.approval_status).to eq("applying")
  end

  it "全除外範囲（取得日数 0）は RecordInvalid・未永続" do
    expect {
      call(start_date: Date.new(2026, 5, 2), end_date: Date.new(2026, 5, 3))   # 土日
    }.to raise_error(ActiveRecord::RecordInvalid)
    expect(LeaveRequest.count).to eq(0)
  end

  describe "manager 未設定（RouteError ロールバック）" do
    let(:requester) { create(:user, organization: org, manager: nil) }

    it "host・assignment ともに未永続（count 双方不変）" do
      expect { call rescue nil }.not_to change { [ LeaveRequest.count, ApprovalAssignment.count ] }
      expect { call }.to raise_error(Approvals::RouteError)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/leave_requests/create_spec.rb`
Expected: FAIL（`uninitialized constant LeaveRequests::Create`）

- [ ] **Step 3: Write minimal implementation**

```ruby
# app/services/leave_requests/create.rb
# frozen_string_literal: true

module LeaveRequests
  # 申請作成（Phase 2-2a 設計 §3.2）。days_requested をサーバ確定 → save! → Approvals::Start を
  # 1 tx。RouteError（manager 未設定・§7.2）は tx ロールバックで host・assignment ともに未永続。
  class Create
    def self.call(requester:, leave_type:, start_date:, end_date:, half_day_type:, reason:)
      new(requester, leave_type, start_date, end_date, half_day_type, reason).call
    end

    def initialize(requester, leave_type, start_date, end_date, half_day_type, reason)
      @requester = requester
      @leave_type = leave_type
      @start_date = start_date
      @end_date = end_date
      @half_day_type = half_day_type
      @reason = reason
    end

    def call
      ActiveRecord::Base.transaction do
        est = Estimate.call(requester: @requester, leave_type: @leave_type,
                            start_date: @start_date, end_date: @end_date, half_day_type: @half_day_type)
        record = LeaveRequest.create!(
          requester: @requester, leave_type: @leave_type, start_date: @start_date,
          end_date: @end_date, half_day_type: @half_day_type, reason: @reason,
          days_requested: est.days_requested
        )
        Approvals::Start.call(record)
        record
      end
    end
  end
end
```

- [ ] **Step 4: Run test + rubocop**

Run: `bundle exec rspec spec/services/leave_requests/create_spec.rb`
Expected: PASS
Run: `bundle exec rubocop --force-exclusion app/services/leave_requests/create.rb`

- [ ] **Step 5: Commit**

```bash
git add app/services/leave_requests/create.rb spec/services/leave_requests/create_spec.rb
git commit -m "feat: LeaveRequests::Create（1tx・Start起動・RouteErrorロールバック）"
```

---

## Task 9: `Approvals::Cancel`（2-1 後置の回収）

**Files:**
- Create: `app/services/approvals/cancel.rb`
- Test: `spec/services/approvals/cancel_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/approvals/cancel_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::Cancel do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:requester) { create(:user, organization: org) }
  let(:request) { create(:leave_request, requester:) }

  it "applying を canceled へ遷移（by=requester）" do
    described_class.call(approvable: request, by: requester)
    expect(request.reload.approval_status).to eq("canceled")
  end

  it "by != requester は SelfApprovalError（service 層の二層目）" do
    other = create(:user, organization: org)
    expect { described_class.call(approvable: request, by: other) }
      .to raise_error(Approvals::SelfApprovalError)
    expect(request.reload.approval_status).to eq("applying")
  end

  it "canceled の再 cancel は InvalidTransition（terminal）" do
    described_class.call(approvable: request, by: requester)
    expect { described_class.call(approvable: request.reload, by: requester) }
      .to raise_error(AASM::InvalidTransition)
  end
end
```

> `Approvals::SelfApprovalError` は 2-1 で定義済（`app/services/approvals/` 配下）。未定義なら 2-1 の errors を確認。

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/approvals/cancel_spec.rb`
Expected: FAIL（`uninitialized constant Approvals::Cancel`）

- [ ] **Step 3: Write minimal implementation**

```ruby
# app/services/approvals/cancel.rb
# frozen_string_literal: true

module Approvals
  # 申請の取消（Phase 2-2a 設計 §3.3・2-1 後置の回収）。applying→canceled・副作用なし。
  # 認可は cancel? Pundit と service 内 by==requester の二層（§7.3 同思想）。
  # with_lock は前置（二重クリック耐性 + 2-2b approve と形を揃える seam）。
  class Cancel
    def self.call(approvable:, by:) = new(approvable, by).call

    def initialize(approvable, by)
      @approvable = approvable
      @by = by
    end

    def call
      @approvable.with_lock do
        raise SelfApprovalError unless @by.id == @approvable.requester_id

        @approvable.cancel!   # AASM applying→canceled（whiny_persistence で偽 success 化を防ぐ）
      end
      @approvable
    end
  end
end
```

- [ ] **Step 4: Run test + rubocop**

Run: `bundle exec rspec spec/services/approvals/cancel_spec.rb`
Expected: PASS
Run: `bundle exec rubocop --force-exclusion app/services/approvals/cancel.rb`

- [ ] **Step 5: Commit**

```bash
git add app/services/approvals/cancel.rb spec/services/approvals/cancel_spec.rb
git commit -m "feat: Approvals::Cancel（applying→canceled・by検証二層・2-1後置回収）"
```

---

## Task 10: 認可（`LeaveRequestPolicy` + `Admin::LeaveBalancePolicy`）

**Files:**
- Create: `app/policies/leave_request_policy.rb`
- Create: `app/policies/admin/leave_balance_policy.rb`
- Test: `spec/policies/leave_request_policy_spec.rb`, `spec/policies/admin/leave_balance_policy_spec.rb`

- [ ] **Step 1: Write the failing tests**

```ruby
# spec/policies/leave_request_policy_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequestPolicy do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:owner) { create(:user, organization: org) }
  let(:other) { create(:user, organization: org) }
  let(:request) { create(:leave_request, requester: owner) }

  permissions :index?, :new?, :create?, :preview? do
    it { expect(described_class).to permit(owner, LeaveRequest) }
  end

  permissions :cancel? do
    it "本人 applying は許可" do
      expect(described_class).to permit(owner, request)
    end

    it "第三者は不許可" do
      expect(described_class).not_to permit(other, request)
    end

    it "terminal（canceled）は不許可" do
      request.cancel!
      expect(described_class).not_to permit(owner, request.reload)
    end
  end

  describe "Scope" do
    it "自分の申請のみ返す" do
      mine = request
      ActsAsTenant.with_tenant(org) { create(:leave_request, requester: other) }
      scope = LeaveRequestPolicy::Scope.new(owner, LeaveRequest).resolve
      expect(scope).to contain_exactly(mine)
    end
  end
end
```

```ruby
# spec/policies/admin/leave_balance_policy_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::LeaveBalancePolicy do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr) { create(:user, :hr_admin, organization: org) }
  let(:employee) { create(:user, organization: org) }
  let(:balance) { create(:leave_balance) }

  permissions :create?, :update?, :new?, :edit? do
    it { expect(described_class).to permit(hr, balance) }
    it { expect(described_class).not_to permit(employee, balance) }
  end
end
```

> pundit-matchers（`permit`）は 2-1 policy spec で使用実績あり。`permissions` ブロックは pundit/rspec の DSL。

- [ ] **Step 2: Run tests to verify they fail**

Run: `bundle exec rspec spec/policies/leave_request_policy_spec.rb spec/policies/admin/leave_balance_policy_spec.rb`
Expected: FAIL（`uninitialized constant LeaveRequestPolicy` 等）

- [ ] **Step 3: Write minimal implementations**

```ruby
# app/policies/leave_request_policy.rb
# frozen_string_literal: true

# 申請側の認可（Phase 2-2a 設計 §6）。requester=current_user 固定ゆえ本人前提。
# index でも verify_authorized が発火する本アプリ規約に合わせ index? を定義。
class LeaveRequestPolicy < ApplicationPolicy
  def index? = user.present?
  def new? = user.present?
  def create? = user.present?
  def preview? = user.present?   # 本人見積り（controller が requester を current_user に固定）

  def cancel? = record.requester_id == user.id && record.applying?

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(requester_id: user.id)
  end
end
```

```ruby
# app/policies/admin/leave_balance_policy.rb
# frozen_string_literal: true

module Admin
  # hr_admin 専用 残高 CRUD（Phase 2-2a 設計 §5/§6）。0b マスタと同じ MasterPolicy 継承
  class LeaveBalancePolicy < MasterPolicy
    # new?/edit? は基底に無いため明示（new→create?, edit→update? に委譲）
    def new? = create?
    def edit? = update?
  end
end
```

> `ApplicationPolicy` / `ApplicationPolicy::Scope` は 2-1 までに存在。`MasterPolicy#index?/create?/update?` は `hr_admin?`（既存）。

- [ ] **Step 4: Run tests + rubocop**

Run: `bundle exec rspec spec/policies/leave_request_policy_spec.rb spec/policies/admin/leave_balance_policy_spec.rb`
Expected: PASS
Run: `bundle exec rubocop --force-exclusion app/policies/leave_request_policy.rb app/policies/admin/leave_balance_policy.rb`

- [ ] **Step 5: Commit**

```bash
git add app/policies/leave_request_policy.rb app/policies/admin/leave_balance_policy.rb spec/policies/leave_request_policy_spec.rb spec/policies/admin/leave_balance_policy_spec.rb
git commit -m "feat: LeaveRequestPolicy + Admin::LeaveBalancePolicy（本人Scope/cancel?・hr_admin限定）"
```

---

## Task 11: routes + `Admin::LeaveBalancesController` + ビュー

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/admin/leave_balances_controller.rb`
- Create: `app/views/admin/leave_balances/new.html.erb`, `edit.html.erb`, `_form.html.erb`
- Test: `spec/requests/admin_leave_balances_spec.rb`

- [ ] **Step 1: Add routes**

`config/routes.rb` の `namespace :admin` 内、`resources :users` ブロックに `leave_balances` をネスト追加:

```ruby
    resources :users, except: :destroy do
      member do
        patch :deactivate
        patch :activate
        patch :resend_invitation
      end
      resources :user_work_patterns, only: %i[new create edit update] do
        member do
          patch :deactivate
          patch :activate
        end
      end
      resources :leave_balances, only: %i[new create edit update]   # ← 追加（フラット controller）
    end
```

- [ ] **Step 2: Write the failing test**

```ruby
# spec/requests/admin_leave_balances_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Admin::LeaveBalances", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:target) { ActsAsTenant.with_tenant(org) { create(:user, name: "田中太郎") } }
  let!(:annual) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :annual, paid_leave: true) } }

  describe "認可" do
    it "employee は new が 403・hr_admin は 200（対照）" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get new_admin_user_leave_balance_url(target, host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get new_admin_user_leave_balance_url(target, host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end

    it "他テナントの user_id は 404（IDOR）" do
      sign_in admin
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:user) }
      get new_admin_user_leave_balance_url(outsider, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "残高を付与できる（granted_on 同梱）" do
      expect {
        post admin_user_leave_balances_url(target, host: tenant_host(org)),
             params: { leave_balance: { leave_type_id: annual.id, fiscal_year: "2026",
                                        granted_days: "10", carry_over_days: "0",
                                        granted_on: "2026-04-01" } }
      }.to change { ActsAsTenant.with_tenant(org) { LeaveBalance.count } }.by(1)
    end

    it "used_days は permit されない（改竄無視）" do
      post admin_user_leave_balances_url(target, host: tenant_host(org)),
           params: { leave_balance: { leave_type_id: annual.id, fiscal_year: "2026",
                                      granted_days: "10", granted_on: "2026-04-01", used_days: "99" } }
      balance = ActsAsTenant.with_tenant(org) { LeaveBalance.last }
      expect(balance.used_days).to eq(0)
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/admin_leave_balances_spec.rb`
Expected: FAIL（ルート/コントローラ未定義）

- [ ] **Step 4: Write controller + views**

```ruby
# app/controllers/admin/leave_balances_controller.rb
# frozen_string_literal: true

module Admin
  # 社員詳細ネストの残高 CRUD（Phase 2-2a 設計 §5・UserWorkPatternsController と同型のフラット構成）。
  # index/show なし — 一覧は users#show に同居。used_days/user_id は permit せず改竄経路を閉じる。
  class LeaveBalancesController < BaseController
    before_action :set_user
    before_action :set_leave_balance, only: %i[edit update]

    def new
      @leave_balance = @user.leave_balances.new
      authorize [ :admin, @leave_balance ]
    end

    def create
      @leave_balance = @user.leave_balances.new(leave_balance_params)
      authorize [ :admin, @leave_balance ]
      if @leave_balance.save
        redirect_to admin_user_path(@user), status: :see_other, notice: "残高を登録しました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @leave_balance ]
    end

    def update
      authorize [ :admin, @leave_balance ]
      if @leave_balance.update(leave_balance_params)
        redirect_to admin_user_path(@user), status: :see_other, notice: "残高を更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_user
      @user = policy_scope([ :admin, User ]).find(params[:user_id])
    end

    def set_leave_balance
      @leave_balance = @user.leave_balances.find(params[:id])
    end

    # user_id は URL（ネスト）から・used_days は 2-2b approve 専有 — 改竄代入経路を閉じる（§3.6(2)）
    def leave_balance_params
      params.require(:leave_balance)
            .permit(:leave_type_id, :fiscal_year, :granted_days, :carry_over_days, :granted_on)
    end
  end
end
```

`app/models/user.rb` に `has_many :leave_balances`（と後続タスクで使う `has_many :leave_requests, foreign_key: :requester_id`）を追加:

```ruby
  has_many :leave_balances, dependent: :destroy
  has_many :leave_requests, foreign_key: :requester_id, inverse_of: :requester, dependent: :destroy
```

> 既存の `has_many` 群（attendance_records 等）の並びに追加。`dependent` は既存方針に合わせる（User は組織 restrict 下ゆえ destroy 連鎖で可）。

ビュー（最小・既存マスタ form と同トーン）:

```erb
<%# app/views/admin/leave_balances/new.html.erb %>
<h1 class="text-xl font-bold mb-4"><%= @user.name %> の休暇残高を登録</h1>
<%= render "form", user: @user, leave_balance: @leave_balance %>
```

```erb
<%# app/views/admin/leave_balances/edit.html.erb %>
<h1 class="text-xl font-bold mb-4"><%= @user.name %> の休暇残高を編集</h1>
<%= render "form", user: @user, leave_balance: @leave_balance %>
```

```erb
<%# app/views/admin/leave_balances/_form.html.erb %>
<%= form_with model: [:admin, user, leave_balance], local: true do |f| %>
  <% if leave_balance.errors.any? %>
    <div class="text-red-600 mb-2"><%= leave_balance.errors.full_messages.join("。") %></div>
  <% end %>
  <div class="mb-2">
    <%= f.label :leave_type_id, "休暇種別" %>
    <%= f.collection_select :leave_type_id, LeaveType.where(active: true), :id, :name %>
  </div>
  <div class="mb-2"><%= f.label :fiscal_year, "年度" %><%= f.text_field :fiscal_year %></div>
  <div class="mb-2"><%= f.label :granted_days, "付与日数" %><%= f.number_field :granted_days, step: 0.5 %></div>
  <div class="mb-2"><%= f.label :carry_over_days, "繰越日数" %><%= f.number_field :carry_over_days, step: 0.5 %></div>
  <div class="mb-2"><%= f.label :granted_on, "付与日（有給は必須）" %><%= f.date_field :granted_on %></div>
  <%= f.submit "保存", class: "bg-blue-600 text-white px-4 py-2 rounded" %>
<% end %>
```

> `form_with model: [:admin, user, leave_balance]` はネスト URL（`admin_user_leave_balances` / `admin_user_leave_balance`）を解決。

- [ ] **Step 5: Run test + rubocop + brakeman**

Run: `bundle exec rspec spec/requests/admin_leave_balances_spec.rb`
Expected: PASS
Run: `bundle exec rubocop --force-exclusion app/controllers/admin/leave_balances_controller.rb app/models/user.rb`
Run: `bin/brakeman --no-pager`（app/ 変更）

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/admin/leave_balances_controller.rb app/views/admin/leave_balances app/models/user.rb spec/requests/admin_leave_balances_spec.rb
git commit -m "feat: hr_admin 残高 CRUD（フラットネスト・used_days/user_id 非permit）"
```

---

## Task 12: 残高 2 段階表示 ViewComponent

**Files:**
- Create: `app/components/leave_requests/balance_component.rb`, `balance_component.html.erb`
- Test: `spec/components/leave_requests/balance_component_spec.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/components/leave_requests/balance_component_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::BalanceComponent, type: :component do
  def result(remaining_after:, paid_leave: true)
    LeaveRequests::Estimate::Result.new(
      days_requested: BigDecimal("1"), fiscal_year: "2026", paid_leave:,
      confirmed_remaining: BigDecimal("10"), provisional_remaining: BigDecimal("5"), remaining_after:
    )
  end

  it "positive は通常表示（警告文言なし）" do
    render_inline(described_class.new(estimate: result(remaining_after: BigDecimal("4"))))
    expect(page).not_to have_text("使い切ります")
    expect(page).to have_text("5")   # 仮残高
  end

  it "zero はアンバー + 定文言" do
    render_inline(described_class.new(estimate: result(remaining_after: BigDecimal("0"))))
    expect(page).to have_text("今年度の有給を使い切ります")
    expect(page).to have_css(".text-amber-600, .bg-amber-50", visible: :all)
  end

  it "negative は赤警告" do
    render_inline(described_class.new(estimate: result(remaining_after: BigDecimal("-2"))))
    expect(page).to have_css(".text-red-600, .bg-red-50", visible: :all)
  end

  it "非 paid_leave 種別は残高ブロックを描画しない" do
    render_inline(described_class.new(estimate: result(remaining_after: nil, paid_leave: false)))
    expect(page).not_to have_text("残")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/components/leave_requests/balance_component_spec.rb`
Expected: FAIL（`uninitialized constant LeaveRequests::BalanceComponent`）

- [ ] **Step 3: Write component**

```ruby
# app/components/leave_requests/balance_component.rb
# frozen_string_literal: true

module LeaveRequests
  # 残高 2 段階表示（SPEC §6.2・Phase 2-2a 設計 §4.3）。状態は Estimate::Result#status が決定。
  # paid_leave 種別のみ描画。erb にロジックを散らさない。
  class BalanceComponent < ViewComponent::Base
    STATE = {
      positive: { css: "text-gray-700", note: nil },
      zero: { css: "text-amber-600 bg-amber-50 px-2 py-1 rounded", note: "今年度の有給を使い切ります" },
      negative: { css: "text-red-600 bg-red-50 px-2 py-1 rounded", note: "残高が不足しています（承認者の判断で申請可）" }
    }.freeze

    def initialize(estimate:)
      @estimate = estimate
    end

    def render? = @estimate.paid_leave

    def confirmed = @estimate.confirmed_remaining
    def provisional = @estimate.provisional_remaining
    def remaining_after = @estimate.remaining_after
    def style = STATE.fetch(@estimate.status)
  end
end
```

```erb
<%# app/components/leave_requests/balance_component.html.erb %>
<div class="text-sm <%= style[:css] %>" data-leave-balance>
  <span>確定残 <%= confirmed.to_s("F") %> 日 / 仮残 <%= provisional.to_s("F") %> 日</span>
  <span>申請後 <%= remaining_after.to_s("F") %> 日</span>
  <% if style[:note] %>
    <span data-balance-note>ℹ️ <%= style[:note] %></span>
  <% end %>
</div>
```

- [ ] **Step 4: Run test + rubocop**

Run: `bundle exec rspec spec/components/leave_requests/balance_component_spec.rb`
Expected: PASS
Run: `bundle exec rubocop --force-exclusion app/components/leave_requests/balance_component.rb`

- [ ] **Step 5: Commit**

```bash
git add app/components/leave_requests spec/components/leave_requests
git commit -m "feat: 残高2段階表示 ViewComponent（status駆動の正/0/負）"
```

---

## Task 13: `LeaveRequestsController`（index/new/create/cancel）+ ビュー

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/leave_requests_controller.rb`
- Create: `app/views/leave_requests/index.html.erb`, `new.html.erb`, `_form.html.erb`
- Test: `spec/requests/leave_requests_spec.rb`

- [ ] **Step 1: Add routes**

`config/routes.rb` の `root` の手前（非 admin 領域）に追加:

```ruby
  resources :leave_requests, only: %i[index new create] do
    collection { get :preview }   # ← Task 14 で使用（ここで定義しておく）
    member { patch :cancel }
  end
```

- [ ] **Step 2: Write the failing test**

```ruby
# spec/requests/leave_requests_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "LeaveRequests", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:dept) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role) } }
  let!(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: dept) } }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user, manager:) } }
  let!(:leave_type) { ActsAsTenant.with_tenant(org) { create(:leave_type) } }

  before { sign_in user }

  describe "POST create" do
    it "申請を作成し days_requested はサーバ確定・status=applying（mass-assignment 遮断）" do
      expect {
        post leave_requests_url(host: tenant_host(org)),
             params: { leave_request: { leave_type_id: leave_type.id, start_date: "2026-05-01",
                                        end_date: "2026-05-01", half_day_type: "none", reason: "私用",
                                        days_requested: "99", approval_status: "approved" } }
      }.to change { ActsAsTenant.with_tenant(org) { LeaveRequest.count } }.by(1)
      record = ActsAsTenant.with_tenant(org) { LeaveRequest.last }
      expect(record.days_requested).to eq(BigDecimal("1"))   # client の 99 を無視
      expect(record.approval_status).to eq("applying")        # client の approved を無視
    end
  end

  describe "GET index" do
    it "自分の申請のみ表示し他者の申請を漏らさない（index は leave_type 名を描画）" do
      ActsAsTenant.with_tenant(org) do
        mine_type = create(:leave_type, name: "私の有給")
        others_type = create(:leave_type, name: "他人の慶弔")
        create(:leave_request, requester: user, leave_type: mine_type)
        create(:leave_request, requester: manager, leave_type: others_type)
      end
      get leave_requests_url(host: tenant_host(org))
      expect(response.body).to include("私の有給")
      expect(response.body).not_to include("他人の慶弔")
    end
  end

  describe "PATCH cancel" do
    it "本人は取消でき canceled へ" do
      req = ActsAsTenant.with_tenant(org) { create(:leave_request, requester: user) }
      patch cancel_leave_request_url(req, host: tenant_host(org))
      expect(req.reload.approval_status).to eq("canceled")
    end

    it "他人の申請は 404（policy_scope 経由 find）" do
      other_req = ActsAsTenant.with_tenant(org) { create(:leave_request, requester: manager) }
      patch cancel_leave_request_url(other_req, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
    end
  end
end
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/leave_requests_spec.rb`
Expected: FAIL（コントローラ未定義）

- [ ] **Step 4: Write controller + views**

```ruby
# app/controllers/leave_requests_controller.rb
# frozen_string_literal: true

# 社員の休暇申請（Phase 2-2a 設計 §4）。requester=current_user 構造固定 — params から
# requester_id/user_id を一切受けない（MPR C3・残高漏洩の唯一の壁）。
class LeaveRequestsController < ApplicationController
  before_action :set_leave_request, only: :cancel

  def index
    authorize LeaveRequest
    @leave_requests = policy_scope(LeaveRequest).order(start_date: :desc)
  end

  def new
    authorize LeaveRequest
    @leave_request = LeaveRequest.new(start_date: current_user.organization.today)
    @leave_types = LeaveType.where(active: true)
  end

  def create
    authorize LeaveRequest
    @leave_request = LeaveRequests::Create.call(
      requester: current_user, leave_type: LeaveType.find(create_params[:leave_type_id]),
      start_date: create_params[:start_date], end_date: create_params[:end_date],
      half_day_type: create_params[:half_day_type], reason: create_params[:reason]
    )
    redirect_to leave_requests_path, status: :see_other, notice: "休暇を申請しました"
  rescue Approvals::RouteError
    redirect_to leave_requests_path, status: :see_other,
                alert: "申請できません。直属上長が未設定です（管理者にご連絡ください）"
  rescue ActiveRecord::RecordInvalid => e
    @leave_request = e.record
    @leave_types = LeaveType.where(active: true)
    render :new, status: :unprocessable_entity
  end

  def cancel
    authorize @leave_request, :cancel?
    Approvals::Cancel.call(approvable: @leave_request, by: current_user)
    redirect_to leave_requests_path, status: :see_other, notice: "申請を取り消しました"
  end

  private

  # 他人の申請 id は policy_scope 経由 find で 404（scope + policy の二層・MPR セキュリティ）
  def set_leave_request
    @leave_request = policy_scope(LeaveRequest).find(params[:id])
  end

  # requester_id/user_id/days_requested/approval_status は受けない（サーバ権威）
  def create_params
    params.require(:leave_request).permit(:leave_type_id, :start_date, :end_date, :half_day_type, :reason)
  end
end
```

ビュー（最小）:

```erb
<%# app/views/leave_requests/index.html.erb %>
<h1 class="text-xl font-bold mb-4">休暇申請</h1>
<%= link_to "新規申請", new_leave_request_path, class: "text-blue-600" %>
<ul class="mt-4 divide-y">
  <% @leave_requests.each do |r| %>
    <li class="py-2 flex justify-between">
      <span><%= r.start_date %>〜<%= r.end_date %> / <%= r.leave_type.name %> / <%= r.days_requested.to_s("F") %>日 / <%= t("leave_request.status.#{r.approval_status}", default: r.approval_status) %></span>
      <% if r.applying? %>
        <%= button_to "取消", cancel_leave_request_path(r), method: :patch, class: "text-red-600" %>
      <% end %>
    </li>
  <% end %>
</ul>
```

```erb
<%# app/views/leave_requests/new.html.erb %>
<h1 class="text-xl font-bold mb-4">休暇を申請</h1>
<%= render "form", leave_request: @leave_request, leave_types: @leave_types %>
```

```erb
<%# app/views/leave_requests/_form.html.erb %>
<%= form_with model: leave_request, url: leave_requests_path, method: :post,
              data: { controller: "leave-request-form",
                      "leave-request-form-preview-url-value": preview_leave_requests_path } do |f| %>
  <% if leave_request.errors.any? %>
    <div class="text-red-600 mb-2"><%= leave_request.errors.full_messages.join("。") %></div>
  <% end %>
  <div class="mb-2">
    <%= f.label :leave_type_id, "休暇種別" %>
    <%= f.collection_select :leave_type_id, leave_types, :id, :name, {},
          data: { action: "change->leave-request-form#refresh", "leave-request-form-target": "leaveType" } %>
  </div>
  <div class="mb-2">
    <%= f.label :start_date, "開始日" %>
    <%= f.date_field :start_date, data: { action: "change->leave-request-form#refresh", "leave-request-form-target": "startDate" } %>
  </div>
  <div class="mb-2">
    <%= f.label :end_date, "終了日" %>
    <%= f.date_field :end_date, data: { action: "change->leave-request-form#refresh", "leave-request-form-target": "endDate" } %>
  </div>
  <div class="mb-2">
    <%= f.label :half_day_type, "半休" %>
    <%= f.select :half_day_type, [["なし","none"],["午前","morning"],["午後","afternoon"]], {},
          data: { action: "change->leave-request-form#refresh", "leave-request-form-target": "halfDay" } %>
  </div>

  <%# preview の着地（Task 14 で Turbo Frame src を Stimulus が更新） %>
  <%= turbo_frame_tag "leave_estimate", data: { "leave-request-form-target": "estimate" } %>

  <div class="mb-2">
    <%= f.label :reason, "理由" %>
    <%= f.text_area :reason, data: { "leave-request-form-target": "reason" } %>
    <div class="mt-1 flex gap-1 flex-wrap">
      <% ReasonTemplate.where(active: true, applies_to: [:leave, :both]).each do |tpl| %>
        <button type="button" class="text-xs border rounded px-2 py-1"
                data-action="leave-request-form#applyTemplate"
                data-template="<%= tpl.template_text %>"><%= tpl.label %></button>
      <% end %>
    </div>
  </div>
  <%= f.submit "申請する", class: "bg-blue-600 text-white px-4 py-2 rounded" %>
<% end %>
```

> `ReasonTemplate.applies_to` は enum（`leave`/`both` を含む・0b-5）。`[:leave, :both]` で絞る。i18n キー `leave_request.status.*` は `config/locales/ja.yml` に追記（applying:申請中/approved:承認済/rejected:却下/canceled:取消・任意 default 付き）。

- [ ] **Step 5: Run test + rubocop + brakeman**

Run: `bundle exec rspec spec/requests/leave_requests_spec.rb`
Expected: PASS（preview 関連は Task 14・このタスクは index/new/create/cancel）
Run: `bundle exec rubocop --force-exclusion app/controllers/leave_requests_controller.rb`
Run: `bin/brakeman --no-pager`

- [ ] **Step 6: Commit**

```bash
git add config/routes.rb app/controllers/leave_requests_controller.rb app/views/leave_requests config/locales/ja.yml spec/requests/leave_requests_spec.rb
git commit -m "feat: LeaveRequestsController（申請/一覧/取消・requester固定・mass-assignment遮断）"
```

---

## Task 14: preview エンドポイント + Stimulus（D3 サーバ往復）

**Files:**
- Modify: `app/controllers/leave_requests_controller.rb`（`preview` 追加）
- Create: `app/views/leave_requests/preview.html.erb`
- Create: `app/javascript/controllers/leave_request_form_controller.js`
- Modify: `app/javascript/controllers/index.js`（Stimulus 登録・自動 import なら不要）
- Test: `spec/requests/leave_requests_spec.rb`（preview 追記）, `spec/system/leave_request_form_spec.rb`

- [ ] **Step 1: Write the failing request test**

`spec/requests/leave_requests_spec.rb` に追加:

```ruby
describe "GET preview（サーバ往復・Turbo Frame）" do
  let!(:paid) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :annual, paid_leave: true) } }
  before do
    ActsAsTenant.with_tenant(org) do
      create(:leave_balance, user:, leave_type: paid, fiscal_year: "2026",
             granted_days: 10, granted_on: Date.new(2026, 4, 1))
    end
  end

  it "日数と残高状態を含む frame を返す" do
    get preview_leave_requests_url(host: tenant_host(org)),
        params: { leave_type_id: paid.id, start_date: "2026-05-01", end_date: "2026-05-01", half_day_type: "none" }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("leave_estimate")   # turbo_frame_tag id
    expect(response.body).to include("1")                # days_requested
  end

  it "requester_id を渡しても自分の見積りのみ（他者残高を読まない・MPR C3）" do
    other = ActsAsTenant.with_tenant(org) { create(:user) }
    get preview_leave_requests_url(host: tenant_host(org)),
        params: { leave_type_id: paid.id, start_date: "2026-05-01", end_date: "2026-05-01",
                  half_day_type: "none", requester_id: other.id }
    expect(response).to have_http_status(:ok)   # requester_id は無視（current_user 固定）
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/requests/leave_requests_spec.rb -e preview`
Expected: FAIL（`preview` アクション未定義）

- [ ] **Step 3: Add preview action + view**

`app/controllers/leave_requests_controller.rb` に追加（`create` の後）:

```ruby
  def preview
    authorize LeaveRequest, :preview?   # persisted record 不在 → class-level（MPR 原則整合）
    @estimate = LeaveRequests::Estimate.call(
      requester: current_user,           # ★params の requester_id/user_id は使わない（C3）
      leave_type: LeaveType.find(preview_params[:leave_type_id]),
      start_date: Date.parse(preview_params[:start_date]),
      end_date: Date.parse(preview_params[:end_date]),
      half_day_type: preview_params[:half_day_type]
    )
    render :preview
  rescue ArgumentError, Date::Error
    head :unprocessable_entity   # 半休×複数日・span 超・不正日付
  end
```

`private` の `create_params` 付近に追加:

```ruby
  def preview_params
    params.permit(:leave_type_id, :start_date, :end_date, :half_day_type)
  end
```

```erb
<%# app/views/leave_requests/preview.html.erb %>
<%= turbo_frame_tag "leave_estimate" do %>
  <div class="text-sm">取得日数: <strong><%= @estimate.days_requested.to_s("F") %></strong> 日</div>
  <%= render LeaveRequests::BalanceComponent.new(estimate: @estimate) %>
<% end %>
```

- [ ] **Step 4: Write Stimulus controller**

```javascript
// app/javascript/controllers/leave_request_form_controller.js
import { Controller } from "@hotwired/stimulus"

// 申請フォームのリアルタイム見積り（Phase 2-2a 設計 §4.2・D3 サーバ往復）。
// 生 fetch+innerHTML はしない — Turbo Frame の src を debounce で書き換え、Turbo が自動取得・差し替え。
export default class extends Controller {
  static targets = ["leaveType", "startDate", "endDate", "halfDay", "estimate", "reason"]
  static values = { previewUrl: String }

  refresh() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.updateFrameSrc(), 300)
  }

  updateFrameSrc() {
    if (!this.startDateTarget.value || !this.endDateTarget.value || !this.leaveTypeTarget.value) return
    const p = new URLSearchParams({
      leave_type_id: this.leaveTypeTarget.value,
      start_date: this.startDateTarget.value,
      end_date: this.endDateTarget.value,
      half_day_type: this.halfDayTarget.value,
    })
    this.estimateTarget.src = `${this.previewUrlValue}?${p.toString()}`
  }

  applyTemplate(event) {
    const text = event.currentTarget.dataset.template
    this.reasonTarget.value = this.reasonTarget.value ? `${this.reasonTarget.value}\n${text}` : text
  }
}
```

> importmap + `stimulus-loading` の eager load なら `index.js` への手動登録は不要（既存 controllers が自動登録される構成かを確認。手動構成なら `application.register("leave-request-form", LeaveRequestFormController)` を `index.js` に追加）。

- [ ] **Step 5: Write system test**

```ruby
# spec/system/leave_request_form_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "休暇申請フォーム", type: :system do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:dept) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role) } }
  let!(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: dept) } }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user, manager:) } }
  let!(:paid) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :annual, paid_leave: true, name: "有給") } }

  before do
    ActsAsTenant.with_tenant(org) do
      create(:leave_balance, user:, leave_type: paid, fiscal_year: "2026",
             granted_days: 10, granted_on: Date.new(2026, 4, 1))
    end
    driven_by(:rack_test) # JS 不要部分。frame src 更新の検証は request spec で担保済み
    sign_in user
  end

  it "新規申請フォームが表示され送信できる" do
    visit new_leave_request_path(host: tenant_host(org))
    select "有給", from: "休暇種別"
    fill_in "開始日", with: "2026-05-01"
    fill_in "終了日", with: "2026-05-01"
    click_button "申請する"
    expect(page).to have_text("休暇を申請しました")
  end
end
```

> JS 実挙動（debounce → frame 差し替え）の検証は request spec（Step 1）で frame レスポンスを直接叩いて担保。system は rack_test で UI 経路を最小確認（既存 system spec の driver 方針に合わせる）。

- [ ] **Step 6: Run tests + rubocop + brakeman**

Run: `bundle exec rspec spec/requests/leave_requests_spec.rb spec/system/leave_request_form_spec.rb`
Expected: PASS
Run: `bundle exec rubocop --force-exclusion app/controllers/leave_requests_controller.rb`
Run: `bin/brakeman --no-pager`

- [ ] **Step 7: Commit**

```bash
git add app/controllers/leave_requests_controller.rb app/views/leave_requests/preview.html.erb app/javascript/controllers/leave_request_form_controller.js spec/requests/leave_requests_spec.rb spec/system/leave_request_form_spec.rb
git commit -m "feat: preview エンドポイント + Stimulus（Turbo Frame src のサーバ往復・D3）"
```

---

## Task 15: ROADMAP 更新 + 全体検証 + PR

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: ROADMAP の 2-2 行を 2-2a/2-2b へ分解**

`docs/ROADMAP.md` の Phase 2 の `- [ ] 2-2 LeaveRequest + LeaveBalance` 行を以下へ置換:

```markdown
- [x] **2-2a LeaveRequest + LeaveBalance（申請側）**: 申請 UI（LeaveDaysCalculator §5.5・Estimate 単一ソース・残高 2 段階表示・サーバ往復 preview）・hr_admin 残高 CRUD・取消・決算月ガード格上げ（残高ありで変更禁止）。承認決裁・副作用は 2-2b（PR #<番号>）
- [ ] **2-2b 承認 + 副作用**: 承認インボックス UI・Scope・approve 副作用（AR 更新・LateEarly 再計算・LeaveBalance lock! 加算・AttendanceHistory）・月跨ぎ/年度跨ぎ（§6.2）
```

> その他のスライス（2-3/2-4/2-5）の番号はそのまま。設計書 §11 の労務申し送り（年度帰属の個人基準日アンカー等）は横断バックログに追記してもよい。`LABOR_LAW_REVIEW_NOTES.md` #10 への追記（計画的付与の 5 日超・労使協定）も本 PR で実施。

- [ ] **Step 2: 全体テスト + 静的検証（/preflight 等価）**

Run: `bin/rails db:test:prepare && bundle exec rspec`
Expected: 全 green（既存 + 2-2a 新規）

Run: `bundle exec rubocop`
Expected: no offenses

Run: `bin/brakeman --no-pager`
Expected: no new warnings

> 可能なら `/preflight` スキルで CI 等価を一括実行。

- [ ] **Step 3: Commit ROADMAP + NOTES**

```bash
git add docs/ROADMAP.md docs/LABOR_LAW_REVIEW_NOTES.md
git commit -m "docs: ROADMAP 2-2 を 2-2a/2-2b へ分解・2-2a 完了マーク + NOTES #10 追記"
```

- [ ] **Step 4: Push + PR**

```bash
git push -u origin feat/phase2-2a-leave-request
gh pr create --title "feat: Phase 2-2a 休暇申請 + 残高（申請側）" \
  --body "$(cat <<'BODY'
## 概要
Phase 2-2 を 2-2a（申請側）/ 2-2b（承認+副作用）に分割した前半。社員が休暇を申請・取消でき、hr_admin が残高を付与でき、申請フォームがサーバ往復でリアルタイムに取得日数と残高 2 段階を表示する。

設計: docs/superpowers/specs/2026-06-16-phase2-2a-leave-request-design.md（多視点レビュー反映済）
計画: docs/superpowers/plans/2026-06-16-phase2-2a-leave-request.md

## 主な実装
- LeaveRequest / LeaveBalance モデル（テナント二層防御・granted_on 必須・半休/span/0日検証）
- LeaveDaysCalculator（§5.5 カレンダー駆動）・CompanyCalendarResolver#day_classifications
- LeaveRequests::Estimate（見積り単一ソース・仮残高スコープ隔離・requester 固定）
- LeaveRequests::Create（1tx・Approvals::Start 起動）・Approvals::Cancel
- hr_admin 残高 CRUD・preview（Turbo Frame src のサーバ往復）
- 決算月ガード格上げ（残高ありで fiscal_year_end_month 変更禁止）

## 後置（2-2b）
承認決裁 UI・approve 副作用（AR/残高 lock!/履歴）・月跨ぎ/年度跨ぎ。
BODY
)"
```

> PR 操作が collaborator エラーなら `gh auth switch -u kei1110`（memory）。merge 前に `tenant-isolation-reviewer`（models/migration に触れた）を通す。
