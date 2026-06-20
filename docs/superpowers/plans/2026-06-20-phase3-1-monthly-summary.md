# Phase 3-1 MonthlyAttendanceSummary + 集計 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 締め期間（`closing_day` 基準）単位で `AttendanceRecord` 群を横断集計し、確定スナップショットを `MonthlyAttendanceSummary`（永久保持）へ per-user・冪等に upsert する集計エンジンを実装する。

**Architecture:** `AttendancePeriod` 値オブジェクトを背骨に、`WeeklyOvertimeCalculator`（純粋・週 40h 超）と `MonthlySummaries::Aggregate`（DB・テナント・resolver）を組む。状態機械・UI・CSV・コンプラ判定は範囲外（3-2/3-3/4-x）。素材保存のみで判定はしない。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / RSpec / FactoryBot / acts_as_tenant / BigDecimal。設計の正本は `docs/superpowers/specs/2026-06-20-phase3-1-monthly-summary-design.md`（D1–D10・§1〜§6）。

## Global Constraints

- 全 `.rb` 先頭に `# frozen_string_literal: true`（リポ全域・hard-freeze）。
- マルチテナント（§3.6）: user 帰属モデルは `acts_as_tenant(:organization)` + 複合 FK `[organization_id, user_id] → users[organization_id, id]` + `[organization_id, id]` unique index + `user_must_belong_to_same_organization` 検証。
- 週 40h 計算は **時間（BigDecimal）単位で統一（D6）**。`MinuteConversion`（分単位規約）は使わない。法定値 `WEEKLY_LEGAL_HOURS = BigDecimal("40")` は calculator 内定数（テナント改変不可）。
- 集計の期間は**締め期間**（`AttendancePeriod`・`closing_day` 基準）。暦月でハードコードしない（D9）。
- AR 由来集計は**出勤系 status（`working`/`clocked_out`/`morning_half`/`afternoon_half`）でゲート**（D10・`on_leave` の #104 stale 行を除外）。
- `db/schema.rb` は手編集禁止（migration 経由）。`Gemfile.lock` 手編集禁止。
- commit は kei1110 identity（local config 済）。`rubocop` は必ず `bundle exec rubocop --force-exclusion <files>`。app/ を触ったら `bin/brakeman --no-pager`。
- 設計の後置（実装しない）: 状態機械/`status` 列・提出 UI・CSV・`paid_leave_days_used`/`total_leave_hours`/`absent_days`・コンプラフラグ列・`fiscal_year` 列（各消費 Phase で同梱）。

---

### Task 1: `AttendancePeriod` 値オブジェクト（集計の背骨・設計 §1.2・D9）

**Files:**
- Create: `app/models/attendance_period.rb`
- Test: `spec/models/attendance_period_spec.rb`

**Interfaces:**
- Consumes: `Organization#setting.closing_day`（0b-5 既存）・`Organization#fiscal_year_for(date)`（0b-3 既存）。
- Produces:
  - `AttendancePeriod.new(organization:, year_month:)` — `year_month` = 締め日が属する暦月ラベル `"YYYY-MM"`。不正は `ArgumentError`。
  - `#range → Range<Date>`（締め期間 [start, last]・`closing_day` 尊重）
  - `#week_window → Range<Date>`（`range.first` を含む週の日曜 .. `range.last`）
  - `#prev / #next → AttendancePeriod`
  - `#fiscal_year → String`（`fiscal_year_for(range.last)`）
  - `#label / #year_month → String`

- [ ] **Step 1: Write the failing test**

```ruby
# spec/models/attendance_period_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe AttendancePeriod do
  let(:org) { create(:organization) } # fiscal_year_end_month は既定 3

  def period(year_month) = described_class.new(organization: org, year_month:)

  describe "#range（closing_day 尊重）" do
    it "closing_day=31（月末）は暦月に一致" do
      org.setting.update!(closing_day: 31)
      expect(period("2026-03").range).to eq(Date.new(2026, 3, 1)..Date.new(2026, 3, 31))
    end

    it "closing_day=31 は短い月で末日にクランプ（2 月・非うるう/うるう）" do
      org.setting.update!(closing_day: 31)
      expect(period("2026-02").range).to eq(Date.new(2026, 2, 1)..Date.new(2026, 2, 28))
      expect(period("2024-02").range).to eq(Date.new(2024, 2, 1)..Date.new(2024, 2, 29))
    end

    it "closing_day=25 は前月26日〜当月25日" do
      org.setting.update!(closing_day: 25)
      expect(period("2026-03").range).to eq(Date.new(2026, 2, 26)..Date.new(2026, 3, 25))
    end

    it "closing_day=30 は前月末がクランプされても start は連続する" do
      org.setting.update!(closing_day: 30)
      # 前ラベル月 Feb の period_end=2/28(クランプ) → start=3/1、当月 period_end=3/30
      expect(period("2026-03").range).to eq(Date.new(2026, 3, 1)..Date.new(2026, 3, 30))
    end
  end

  describe "#week_window" do
    it "range.first を含む週の日曜から range.last まで" do
      org.setting.update!(closing_day: 31)
      # 2026-03-01 は日曜ゆえ window_start == range.first
      expect(period("2026-03").week_window).to eq(Date.new(2026, 3, 1)..Date.new(2026, 3, 31))
    end

    it "range.first が週中なら前へ遡る（closing_day=25・2/26=木）" do
      org.setting.update!(closing_day: 25)
      # 2026-02-26 は木曜 → 直前日曜 2/22
      expect(period("2026-03").week_window).to eq(Date.new(2026, 2, 22)..Date.new(2026, 3, 25))
    end
  end

  describe "#prev / #next（連続性＝全日が一意に 1 期間へ）" do
    it "prev.range.last + 1 == range.first・range.last + 1 == next.range.first" do
      org.setting.update!(closing_day: 25)
      p = period("2026-03")
      expect(p.prev.range.last + 1).to eq(p.range.first)
      expect(p.range.last + 1).to eq(p.next.range.first)
    end
  end

  describe "#fiscal_year（締め日基準・末日アンカー）" do
    it "fiscal_year_end_month=3 で 3 月締めは前年度、4 月締めは当年度" do
      org.setting.update!(closing_day: 31)
      expect(period("2026-03").fiscal_year).to eq("2025")
      expect(period("2026-04").fiscal_year).to eq("2026")
    end
  end

  describe "不正 year_month" do
    it "月が範囲外なら ArgumentError" do
      expect { period("2026-13") }.to raise_error(ArgumentError)
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/models/attendance_period_spec.rb`
Expected: FAIL（`uninitialized constant AttendancePeriod`）

- [ ] **Step 3: Write minimal implementation**

```ruby
# app/models/attendance_period.rb
# frozen_string_literal: true

# 締め期間（closing_day 基準）の不変な値オブジェクト（3-1 設計 §1.2・D9）。
# (organization, year_month) から締め期間の全属性を導出し、3-1/3-2/3-3/4-x が共有する背骨。
# 週は暦週（日〜土・労基法）のまま歪めず、本オブジェクトは「どの週・どの日が当期か」の帰属だけを担う。
class AttendancePeriod
  # year_month = 締め日が属する暦月のラベル "YYYY-MM"。不正値は ArgumentError で早期に弾く。
  def initialize(organization:, year_month:)
    @organization = organization
    @year_month   = year_month
    @label_first  = Date.strptime(year_month, "%Y-%m") # "2026-13" 等は ArgumentError
  end

  attr_reader :year_month
  alias_method :label, :year_month

  # 締め期間 [start, last]（closing_day 尊重）
  def range
    @range ||= (period_start..period_end)
  end

  # 週次 OT 用 fetch 窓 = 期初日を含む週の日曜 .. 期末日
  def week_window
    @week_window ||= (range.first.beginning_of_week(:sunday)..range.last)
  end

  def prev
    self.class.new(organization: @organization, year_month: @label_first.prev_month.strftime("%Y-%m"))
  end

  def next
    self.class.new(organization: @organization, year_month: @label_first.next_month.strftime("%Y-%m"))
  end

  # 締め日(期末)の暦年度ラベル。年度境界をまたぐ期は前年度日も closing FY へ寄る近似（設計 §5 限界12）。
  def fiscal_year = @organization.fiscal_year_for(range.last)

  private

  def closing_day = @organization.setting.closing_day

  # ラベル月 first_of_month の締め日（31=月末・各月末日でクランプ）
  def closing_date_for(first_of_month)
    last = first_of_month.end_of_month
    Date.new(first_of_month.year, first_of_month.month, [ closing_day, last.day ].min)
  end

  def period_end   = closing_date_for(@label_first)
  def period_start = closing_date_for(@label_first.prev_month) + 1
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/models/attendance_period_spec.rb`
Expected: PASS（全 example green）

- [ ] **Step 5: Lint & commit**

```bash
bundle exec rubocop --force-exclusion app/models/attendance_period.rb spec/models/attendance_period_spec.rb
git add app/models/attendance_period.rb spec/models/attendance_period_spec.rb
git commit -m "feat: AttendancePeriod 値オブジェクト（締め期間の背骨・3-1 D9）"
```

---

### Task 2: `WeeklyOvertimeCalculator`（週 40h 超・純粋・設計 §2・D8）

**Files:**
- Create: `app/calculators/weekly_overtime_calculator.rb`
- Test: `spec/calculators/weekly_overtime_calculator_spec.rb`

**Interfaces:**
- Consumes: なし（純粋関数・DB なし）。`period_range` は `AttendancePeriod#range` を受ける想定。
- Produces:
  - `WeeklyOvertimeCalculator.call(period_range:, days:) → BigDecimal`
  - `days` = `[{ date: Date, actual_hours: BigDecimal, daily_legal_overtime_hours: BigDecimal, legal_holiday_work: Boolean, flextime: Boolean }, ...]`
  - 返り値 = 週末土曜が `period_range` 内の週について `max(0, Σactual − 40 − Σdaily_legal_OT)`（法定休日労働日・flextime 日は母数から除外）の合計。

- [ ] **Step 1: Write the failing test**

```ruby
# spec/calculators/weekly_overtime_calculator_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe WeeklyOvertimeCalculator do
  # 2026-03-01(日)〜03-07(土) を 1 週として使う。period_range は 3 月（土 3/7 を含む）。
  let(:march) { Date.new(2026, 3, 1)..Date.new(2026, 3, 31) }

  # Mon..Sat（3/2〜3/7）に同一属性の日を hours で並べる helper
  def week_days(hours, daily_ot: 0, legal_holiday_work: false, flextime: false)
    (2..7).map do |d|
      { date: Date.new(2026, 3, d), actual_hours: BigDecimal(hours.to_s),
        daily_legal_overtime_hours: BigDecimal(daily_ot.to_s),
        legal_holiday_work:, flextime: }
    end
  end

  def call(days, period_range: march) = described_class.call(period_range:, days:)

  it "40h 境界 3 点（日次 OT 0）: 6.665h/6.6667h/6.67h×6 ≒ 39.99/40.00/40.01 → 0/0/0.01" do
    expect(call([{ date: Date.new(2026, 3, 7), actual_hours: BigDecimal("39.99"),
                   daily_legal_overtime_hours: BigDecimal("0"), legal_holiday_work: false, flextime: false }]))
      .to eq(BigDecimal("0"))
    expect(call([{ date: Date.new(2026, 3, 7), actual_hours: BigDecimal("40.00"),
                   daily_legal_overtime_hours: BigDecimal("0"), legal_holiday_work: false, flextime: false }]))
      .to eq(BigDecimal("0"))
    expect(call([{ date: Date.new(2026, 3, 7), actual_hours: BigDecimal("40.01"),
                   daily_legal_overtime_hours: BigDecimal("0"), legal_holiday_work: false, flextime: false }]))
      .to eq(BigDecimal("0.01"))
  end

  it "所定 7h×6 日=42h・日次 OT 0 → extra 2.00" do
    expect(call(week_days(7))).to eq(BigDecimal("2"))
  end

  it "重複控除: 週実労働 50h・日次 OT 合計 6h → max(0, 50−40−6)=4.00" do
    # 6 日 × actual ~8.333 で 50h、日次 OT 合計 6（1 日 1h）
    days = (2..7).map do |d|
      { date: Date.new(2026, 3, d), actual_hours: BigDecimal("50") / 6,
        daily_legal_overtime_hours: BigDecimal("1"), legal_holiday_work: false, flextime: false }
    end
    expect(call(days)).to eq(BigDecimal("4"))
  end

  it "負クランプ: 週 50h・日次 OT 15h → max(0, 50−40−15)=0" do
    days = (2..7).map do |d|
      { date: Date.new(2026, 3, d), actual_hours: BigDecimal("50") / 6,
        daily_legal_overtime_hours: BigDecimal("2.5"), legal_holiday_work: false, flextime: false }
    end
    expect(call(days)).to eq(BigDecimal("0"))
  end

  it "空配列 → 0（nil/ゼロ除算なし）" do
    expect(call([])).to eq(BigDecimal("0"))
  end

  it "期間帰属: 同一 days でも period_range が土曜を含まなければ 0 寄与" do
    feb = Date.new(2026, 2, 1)..Date.new(2026, 2, 28) # 3/7 を含まない
    expect(call(week_days(7), period_range: feb)).to eq(BigDecimal("0"))
  end

  it "法定休日労働日は母数から除外（35% 側へ）" do
    # 5 日は 7h、1 日は法定休日 20h → countable は 35h で 40h 未満 → 0
    days = week_days(7)
    days[0] = days[0].merge(actual_hours: BigDecimal("20"), legal_holiday_work: true)
    expect(call(days)).to eq(BigDecimal("0"))
  end

  it "flextime 日は週 40h 母数から除外（清算期間ベース・D7）" do
    days = week_days(7)
    days[0] = days[0].merge(actual_hours: BigDecimal("20"), flextime: true)
    expect(call(days)).to eq(BigDecimal("0"))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/calculators/weekly_overtime_calculator_spec.rb`
Expected: FAIL（`uninitialized constant WeeklyOvertimeCalculator`）

- [ ] **Step 3: Write minimal implementation**

```ruby
# app/calculators/weekly_overtime_calculator.rb
# frozen_string_literal: true

require "bigdecimal"

# 週 40h 超の法定時間外（SPEC §5.2・3-1 設計 §2・D8）。当該締め期間に帰属する週次法定時間外の合計を返す純粋関数。
# 【単位は時間(BigDecimal)で統一・D6】入力は AR の確定済み 2dp 時間値（分を保持しない）ゆえ MinuteConversion は使わない
#   ＝§2.2-1 の分単位中間計算規約からの明示的逸脱。将来「分へ揃える」手戻りを防ぐため本コメントを残す。
# 週は暦週（日曜起算・労基法 32 条 1 項／昭 63.1.1 基発 1 号）。期間帰属・法定休日/flextime 除外・重複控除を内包。
class WeeklyOvertimeCalculator
  WEEKLY_LEGAL_HOURS = BigDecimal("40") # 労基法 32 条 1 項・法定値固定（テナント改変不可）

  # period_range : Range<Date>（= AttendancePeriod#range）。土曜の帰属判定に使う。
  # days : [{ date:, actual_hours:, daily_legal_overtime_hours:, legal_holiday_work:, flextime: }, ...]
  def self.call(period_range:, days:)
    days.group_by { |d| d[:date].beginning_of_week(:sunday) }.sum(BigDecimal("0")) do |week_start, week_days|
      saturday = week_start + 6
      next BigDecimal("0") unless period_range.cover?(saturday)

      countable = week_days.reject { |d| d[:legal_holiday_work] || d[:flextime] }
      actual = countable.sum(BigDecimal("0")) { |d| d[:actual_hours] }
      daily  = countable.sum(BigDecimal("0")) { |d| d[:daily_legal_overtime_hours] }
      [ actual - WEEKLY_LEGAL_HOURS - daily, BigDecimal("0") ].max
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/calculators/weekly_overtime_calculator_spec.rb`
Expected: PASS

- [ ] **Step 5: Lint & commit**

```bash
bundle exec rubocop --force-exclusion app/calculators/weekly_overtime_calculator.rb spec/calculators/weekly_overtime_calculator_spec.rb
git add app/calculators/weekly_overtime_calculator.rb spec/calculators/weekly_overtime_calculator_spec.rb
git commit -m "feat: WeeklyOvertimeCalculator（週40h超・純粋・重複控除/法定休日・flextime除外・3-1 D8）"
```

---

### Task 3: migration + `MonthlyAttendanceSummary` モデル + factory（設計 §1.1）

**Files:**
- Create: `db/migrate/<timestamp>_create_monthly_attendance_summaries.rb`
- Create: `app/models/monthly_attendance_summary.rb`
- Create: `spec/factories/monthly_attendance_summaries.rb`
- Test: `spec/models/monthly_attendance_summary_spec.rb`
- Auto-modified: `db/schema.rb`（migrate により更新・手編集しない）

**Interfaces:**
- Consumes: `users[organization_id, id]` unique index（既存）。
- Produces: `MonthlyAttendanceSummary`（`acts_as_tenant(:organization)`・`belongs_to :user`）。カラム: `organization_id`/`user_id`/`year_month`/`scheduled_work_days`/`work_days`/`total_work_hours`/`total_overtime_hours`/`overtime_hours_over_60`/`holiday_work_hours`/`total_deep_night_hours`/`late_days`/`early_leave_days`。

- [ ] **Step 1: Generate migration skeleton & write its content**

```bash
bin/rails g migration CreateMonthlyAttendanceSummaries
```

生成された `db/migrate/<timestamp>_create_monthly_attendance_summaries.rb` の中身を以下に**全置換**する（`leave_balances` migration と同じ複合 FK / 複合 index idiom・index 名はテーブル名が長いため明示）:

```ruby
# frozen_string_literal: true

class CreateMonthlyAttendanceSummaries < ActiveRecord::Migration[8.1]
  def change
    create_table :monthly_attendance_summaries do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.string :year_month, null: false # 締め期間ラベル "YYYY-MM"（AttendancePeriod#label）
      t.integer :scheduled_work_days, null: false, default: 0
      t.integer :work_days, null: false, default: 0
      t.decimal :total_work_hours, precision: 7, scale: 2, null: false, default: 0
      t.decimal :total_overtime_hours, precision: 7, scale: 2, null: false, default: 0 # legal・法定休日除く
      t.decimal :overtime_hours_over_60, precision: 7, scale: 2, null: false, default: 0
      t.decimal :holiday_work_hours, precision: 7, scale: 2, null: false, default: 0 # 35%・60h カウント外
      t.decimal :total_deep_night_hours, precision: 7, scale: 2, null: false, default: 0
      t.integer :late_days, null: false, default: 0
      t.integer :early_leave_days, null: false, default: 0

      t.timestamps
    end

    # クロステナント参照を DB 層で遮断（leave_balances と同じ複合 FK・§3.6）
    add_foreign_key :monthly_attendance_summaries, :users,
                    column: [ :organization_id, :user_id ], primary_key: [ :organization_id, :id ]

    # 複合 FK 参照先（規約）。テーブル名が長いため index 名を明示（63 文字制限回避）
    add_index :monthly_attendance_summaries, %i[organization_id id],
              unique: true, name: "index_monthly_summaries_org_id"
    add_index :monthly_attendance_summaries, %i[organization_id user_id year_month],
              unique: true, name: "index_monthly_summaries_unique"
    add_index :monthly_attendance_summaries, %i[organization_id user_id],
              name: "index_monthly_summaries_org_user"
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `create_table(:monthly_attendance_summaries)` が走り、`db/schema.rb` に新テーブルが追加される（手編集せず migrate 経由）。

- [ ] **Step 3: Write the failing model test**

```ruby
# spec/models/monthly_attendance_summary_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlyAttendanceSummary do
  let(:org) { ActsAsTenant.test_tenant } # support/tenant.rb が既定テナントを設定
  let(:user) { create(:user, organization: org) }

  it "有効な属性で valid" do
    expect(build(:monthly_attendance_summary, user:, year_month: "2026-03")).to be_valid
  end

  describe "year_month format" do
    it "厳密に YYYY-MM のみ valid" do
      expect(build(:monthly_attendance_summary, user:, year_month: "2026-03")).to be_valid
      ["2026-13", "2026-3", "2026-00", "202603", ""].each do |bad|
        expect(build(:monthly_attendance_summary, user:, year_month: bad)).to be_invalid
      end
    end
  end

  describe "テナント内 uniqueness（同 user 同 year_month）" do
    it "同一 user・同一 year_month は衝突" do
      create(:monthly_attendance_summary, user:, year_month: "2026-03")
      dup = build(:monthly_attendance_summary, user:, year_month: "2026-03")
      expect(dup).to be_invalid
    end
  end

  describe "user_must_belong_to_same_organization（Critical・§3.6）" do
    it "他組織の user を代入で invalid" do
      other_user = ActsAsTenant.with_tenant(create(:organization)) { create(:user) }
      summary = build(:monthly_attendance_summary, user: other_user, year_month: "2026-03")
      expect(summary).to be_invalid
      expect(summary.errors[:user]).to include("は同一組織でなければなりません")
    end
  end

  describe "numericality" do
    it "集計列の負値は invalid" do
      expect(build(:monthly_attendance_summary, user:, total_work_hours: -1)).to be_invalid
    end
  end

  describe "テナントスコープ" do
    it "他社行は default_scope で見えない" do
      create(:monthly_attendance_summary, user:, year_month: "2026-03")
      other = create(:organization)
      ActsAsTenant.with_tenant(other) do
        expect(MonthlyAttendanceSummary.count).to eq(0)
      end
    end
  end
end
```

そして factory:

```ruby
# spec/factories/monthly_attendance_summaries.rb
# frozen_string_literal: true

FactoryBot.define do
  factory :monthly_attendance_summary do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user
    year_month { "2026-03" }
  end
end
```

- [ ] **Step 4: Run test to verify it fails**

Run: `bundle exec rspec spec/models/monthly_attendance_summary_spec.rb`
Expected: FAIL（`uninitialized constant MonthlyAttendanceSummary` — モデル未作成）

- [ ] **Step 5: Write the model**

```ruby
# app/models/monthly_attendance_summary.rb
# frozen_string_literal: true

# 月次（締め期間）サマリ（SPEC §4.13・3-1 設計 §1.1）。永久保持・長期参照の基点。
# 本スライスは AR 由来の集計列のみ。status/AASM・休暇由来列・コンプラフラグは消費 Phase が同梱追加（D4）。
class MonthlyAttendanceSummary < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user

  AGGREGATE_COLUMNS = %i[
    scheduled_work_days work_days total_work_hours total_overtime_hours
    overtime_hours_over_60 holiday_work_hours total_deep_night_hours late_days early_leave_days
  ].freeze

  validates :year_month, presence: true, format: { with: /\A\d{4}-\d{2}\z/ }
  validates_uniqueness_to_tenant :year_month, scope: :user_id
  validates(*AGGREGATE_COLUMNS, numericality: { greater_than_or_equal_to: 0 })
  validate :user_must_belong_to_same_organization

  private

  # ID 基点 fail-closed（leave_balance.rb:27 同型・§3.6）。
  # find_or_initialize_by で organization_id(tenant 由来) と user_id(引数由来) が別経路ゆえ能動検証。
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id

    errors.add(:user, "は同一組織でなければなりません")
  end
end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bundle exec rspec spec/models/monthly_attendance_summary_spec.rb`
Expected: PASS

- [ ] **Step 7: Lint & commit**

```bash
bundle exec rubocop --force-exclusion app/models/monthly_attendance_summary.rb spec/models/monthly_attendance_summary_spec.rb spec/factories/monthly_attendance_summaries.rb db/migrate/*_create_monthly_attendance_summaries.rb
git add db/migrate/*_create_monthly_attendance_summaries.rb db/schema.rb app/models/monthly_attendance_summary.rb spec/models/monthly_attendance_summary_spec.rb spec/factories/monthly_attendance_summaries.rb
git commit -m "feat: MonthlyAttendanceSummary モデル + migration（AR由来集計列・同一組織検証・3-1 §1.1）"
```

---

### Task 4: `MonthlySummaries::Aggregate` — 日次集計（期間窓・status ゲート・永続化・設計 §3.1–§3.2/§3.4）

**Files:**
- Create: `app/services/monthly_summaries/aggregate.rb`
- Test: `spec/services/monthly_summaries/aggregate_spec.rb`

**Interfaces:**
- Consumes: `AttendancePeriod`（Task 1）・`MonthlyAttendanceSummary`（Task 3）・`CompanyCalendarResolver`（既存）・`AttendanceRecord`（既存）。
- Produces:
  - `MonthlySummaries::Aggregate.call(user:, period:, day_types: nil) → MonthlyAttendanceSummary`（upsert 済）
  - 本タスクでは `total_overtime_hours` = 日次 legal OT 寄与のみ（週次は Task 5 で加算）。`overtime_hours_over_60` も同基準。
  - `day_types` 注入時は resolver を呼ばない（③ 一括の共有経路）。

- [ ] **Step 1: Write the failing test**

```ruby
# spec/services/monthly_summaries/aggregate_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::Aggregate do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:user) { create(:user, organization: org) }

  def period(year_month) = AttendancePeriod.new(organization: org, year_month:)

  # 計算済み（clocked_out）の出勤日を 1 件作る helper。calc 8 列を明示。
  def worked(date, actual:, legal_ot: 0, deep_night: 0, late: false, early: false, holiday_work: false, status: :clocked_out)
    create(:attendance_record, user:, work_date: date, status:,
           clock_in: Time.utc(date.year, date.month, date.day, 0),
           clock_out: Time.utc(date.year, date.month, date.day, 9),
           is_holiday_work: holiday_work,
           actual_work_hours: actual, legal_overtime_hours: legal_ot, scheduled_overtime_hours: 0,
           deep_night_hours: deep_night, is_late: late, late_minutes: 0,
           is_early_leave: early, early_leave_minutes: 0)
  end

  describe "締め期間（closing_day≠31）" do
    it "closing_day=25 は前月26日〜当月25日のみ集計（暦月ハードコードなら落ちる）" do
      org.setting.update!(closing_day: 25)
      worked(Date.new(2026, 2, 26), actual: 8)
      worked(Date.new(2026, 3, 25), actual: 8)
      worked(Date.new(2026, 3, 26), actual: 8) # 翌期
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.work_days).to eq(2)
      expect(summary.total_work_hours).to eq(8 + 8)
    end
  end

  describe "日次集計の基本列" do
    it "total_work_hours / total_deep_night_hours / late_days / early_leave_days を集計" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 2), actual: 8, deep_night: 1.5, late: true)
      worked(Date.new(2026, 3, 3), actual: 7, deep_night: 0, early: true)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary).to have_attributes(
        work_days: 2, total_work_hours: 15, total_deep_night_hours: 1.5,
        late_days: 1, early_leave_days: 1
      )
    end
  end

  describe "出勤系 status ゲート（D10・#104 stale 行の除外）" do
    it "on_leave（計算列 stale 残留）は work_days/total_work_hours に乗らない" do
      org.setting.update!(closing_day: 31)
      # #104: 打刻済(clocked_out・計算列 non-NULL)の日が全休承認で on_leave へ上書き＋stale 残留
      worked(Date.new(2026, 3, 2), actual: 9, status: :on_leave)
      worked(Date.new(2026, 3, 3), actual: 8) # 正常な出勤日
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.work_days).to eq(1)
      expect(summary.total_work_hours).to eq(8) # on_leave の 9h は除外
    end
  end

  describe "scheduled_work_days（暦由来・AR 非依存）" do
    it "period.range 内の weekday 日数（出勤実態と独立）" do
      org.setting.update!(closing_day: 31)
      # 2026-03 の平日数（resolver フォールバック weekday）。土日と登録祝日を除く。
      summary = described_class.call(user:, period: period("2026-03"))
      weekday_count = (Date.new(2026, 3, 1)..Date.new(2026, 3, 31)).count { |d| (1..5).cover?(d.cwday) }
      expect(summary.scheduled_work_days).to eq(weekday_count)
    end
  end

  describe "day_types 注入（③ 一括の共有経路）" do
    it "day_types を渡すと resolver を呼ばない" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 2), actual: 8)
      injected = (Date.new(2026, 2, 22)..Date.new(2026, 3, 31)).index_with { :weekday }
      expect(CompanyCalendarResolver).not_to receive(:new)
      described_class.call(user:, period: period("2026-03"), day_types: injected)
    end
  end

  describe "テナント分離 / 防御ラップ" do
    it "他社の同期間 AR を集計に混ぜない" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 2), actual: 8)
      other = create(:organization)
      ActsAsTenant.with_tenant(other) do
        ou = create(:user, organization: other)
        create(:attendance_record, :done, user: ou, work_date: Date.new(2026, 3, 2),
               actual_work_hours: 99, legal_overtime_hours: 0, scheduled_overtime_hours: 0,
               deep_night_hours: 0, is_late: false, late_minutes: 0, is_early_leave: false, early_leave_minutes: 0)
      end
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.total_work_hours).to eq(8)
    end

    it "current_tenant 未設定の素文脈からでも自己完結（防御ラップ回帰）" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 2), actual: 8)
      p = period("2026-03")
      ActsAsTenant.without_tenant do
        expect { described_class.call(user:, period: p) }.not_to raise_error
      end
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bundle exec rspec spec/services/monthly_summaries/aggregate_spec.rb`
Expected: FAIL（`uninitialized constant MonthlySummaries`）

- [ ] **Step 3: Write the service（日次集計・週次は 0 仮置き）**

```ruby
# app/services/monthly_summaries/aggregate.rb
# frozen_string_literal: true

require "bigdecimal"

module MonthlySummaries
  # 月次（締め期間）集計（SPEC §4.13/§5.2/§6.4/§8・3-1 設計 §3）。
  # AR 群 → MonthlyAttendanceSummary（永久保持）の確定スナップショットを per-user・冪等に upsert。
  # 集計の期間は締め期間（AttendancePeriod・closing_day 基準）。判定（§8 コンプラ）はしない＝素材保存のみ。
  # 無条件上書き（F1）: status は見ない純関数。submitted/finalized を上書きしないゲートは呼び出し側責務（3-2/4-2）。
  class Aggregate
    # AR 由来集計の母数（D10）。on_leave（#104 stale 含む）は除外。
    WORKED_STATUSES = %i[working clocked_out morning_half afternoon_half].freeze

    def self.call(user:, period:, day_types: nil) = new(user:, period:, day_types:).call

    def initialize(user:, period:, day_types: nil)
      @user = user
      @period = period
      @injected_day_types = day_types
    end

    def call
      ActsAsTenant.with_tenant(@user.organization) do
        summary = MonthlyAttendanceSummary.find_or_initialize_by(user: @user, year_month: @period.label)
        summary.update!(attributes)
        summary
      end
    end

    private

    def attributes
      {
        scheduled_work_days:    scheduled_work_days,
        work_days:              in_period.size,
        total_work_hours:       sum_hours(in_period, :actual_work_hours),
        total_deep_night_hours: sum_hours(in_period, :deep_night_hours),
        holiday_work_hours:     sum_hours(in_period.select { holiday_work?(_1) }, :actual_work_hours),
        total_overtime_hours:   total_overtime_hours,
        overtime_hours_over_60: [ total_overtime_hours - 60, BigDecimal("0") ].max,
        late_days:              in_period.count(&:is_late),
        early_leave_days:       in_period.count(&:is_early_leave)
      }
    end

    # 日次 legal OT 寄与（period.range 内・法定休日労働日を除く）。週次は Task 5 で加算する。
    def total_overtime_hours
      @total_overtime_hours ||=
        sum_hours(in_period.reject { holiday_work?(_1) }, :legal_overtime_hours)
    end

    # 出勤系 status の AR を窓（week_window）で取得（D10・flextime 判定の N+1 回避）
    def worked_records
      @worked_records ||= AttendanceRecord
        .where(user: @user, work_date: @period.week_window, status: WORKED_STATUSES)
        .includes(:work_pattern).to_a
    end

    # 日次集計の母数 = period.range 内の出勤行
    def in_period
      @in_period ||= worked_records.select { @period.range.cover?(_1.work_date) }
    end

    def day_types
      @day_types ||= @injected_day_types ||
        CompanyCalendarResolver.new(organization: @user.organization)
          .day_types(@period.week_window.first, @period.week_window.last)
    end

    def holiday_work?(record)
      record.is_holiday_work && day_types[record.work_date] == :legal_holiday
    end

    def scheduled_work_days
      @period.range.count { day_types[_1] == :weekday }
    end

    def sum_hours(records, attr)
      records.sum(BigDecimal("0")) { _1.public_send(attr) || 0 }
    end
  end
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bundle exec rspec spec/services/monthly_summaries/aggregate_spec.rb`
Expected: PASS

- [ ] **Step 5: Lint, brakeman & commit**

```bash
bundle exec rubocop --force-exclusion app/services/monthly_summaries/aggregate.rb spec/services/monthly_summaries/aggregate_spec.rb
bin/brakeman --no-pager
git add app/services/monthly_summaries/aggregate.rb spec/services/monthly_summaries/aggregate_spec.rb
git commit -m "feat: MonthlySummaries::Aggregate 日次集計（締め期間窓・status ゲート・day_types 注入・3-1 §3.1-3.2）"
```

---

### Task 5: `MonthlySummaries::Aggregate` — 週次 40h 統合 + 2 系統 + 境界/冪等（設計 §3.3・§4.4）

**Files:**
- Modify: `app/services/monthly_summaries/aggregate.rb`（`total_overtime_hours` に週次 extra を加算）
- Test: `spec/services/monthly_summaries/aggregate_spec.rb`（追記）

**Interfaces:**
- Consumes: `WeeklyOvertimeCalculator`（Task 2）。
- Produces: `total_overtime_hours` = 日次 legal OT 寄与 + 週次 extra（週末土曜が `period.range` 内の週）。`overtime_hours_over_60` = `max(0, total_overtime_hours − 60)`。`holiday_work_hours` 母数は `is_holiday_work AND day_type==legal_holiday`（#108）。

- [ ] **Step 1: Write the failing tests（追記）**

`spec/services/monthly_summaries/aggregate_spec.rb` に以下の describe を追記する:

```ruby
  describe "2 系統分離（本スライスの存在意義・#108）" do
    it "法定休日労働は holiday_work へ・total_overtime に寄与しない（日次/週次 2 経路の除外）" do
      org.setting.update!(closing_day: 31)
      d = Date.new(2026, 3, 1) # 日曜
      create(:company_calendar, date: d, day_type: :legal_holiday)
      worked(d, actual: 10, legal_ot: 2, holiday_work: true)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.holiday_work_hours).to eq(10)
      expect(summary.total_overtime_hours).to eq(0)
    end

    it "holiday_work 負例: is_holiday_work でも day_type≠legal_holiday（sunday フォールバック）は holiday_work=0" do
      org.setting.update!(closing_day: 31)
      d = Date.new(2026, 3, 1) # 日曜・CompanyCalendar 未登録 → resolver は :sunday
      worked(d, actual: 8, holiday_work: true)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.holiday_work_hours).to eq(0)
    end

    it "所定休日土曜の出勤は holiday_work に入らない" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 7), actual: 8, holiday_work: false) # 土曜
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.holiday_work_hours).to eq(0)
    end
  end

  describe "週 40h 統合" do
    it "所定 7h×6 日(月〜土)=42h・日次 OT 0 → total_overtime 2h（週次のみ）" do
      org.setting.update!(closing_day: 31)
      (2..7).each { |d| worked(Date.new(2026, 3, d), actual: 7, legal_ot: 0) } # Mon..Sat
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.total_overtime_hours).to eq(2)
    end

    it "末尾週が翌期へ（月末≠土曜）: その週の週次 OT は当期に乗らない" do
      org.setting.update!(closing_day: 31)
      # 2026-03-31 は火曜。週 3/29(日)〜4/4(土) は土曜 4/4 が 4 月 → 当期(3月)に計上しない。
      # 3/29(日)・3/30・3/31 を各 14h（週 42h）。誤って当期へ計上されれば extra=2h になる強い負例。
      (29..31).each { |d| worked(Date.new(2026, 3, d), actual: 14, legal_ot: 0) }
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.total_overtime_hours).to eq(0)
    end
  end

  describe "60h 境界 3 点" do
    it "total_overtime 59.99/60.00/60.01 → over_60 0/0/0.01" do
      org.setting.update!(closing_day: 31)
      # 日次 legal OT のみで total_overtime を作る（平日 1 日に集約・週 40h は跨がない値）
      { "59.99" => "0", "60.00" => "0", "60.01" => "0.01" }.each do |total, expected_over|
        MonthlyAttendanceSummary.delete_all
        AttendanceRecord.where(user:).delete_all
        worked(Date.new(2026, 3, 3), actual: BigDecimal("8") + BigDecimal(total), legal_ot: BigDecimal(total))
        summary = described_class.call(user:, period: period("2026-03"))
        expect(summary.total_overtime_hours).to eq(BigDecimal(total))
        expect(summary.overtime_hours_over_60).to eq(BigDecimal(expected_over))
      end
    end
  end

  describe "管理監督者(exempt)×深夜（ゼロ化バグを殺す）" do
    it "exempt でも深夜・残業を生値で保存（D5・§8.3）" do
      org.setting.update!(closing_day: 31)
      exempt = create(:user, organization: org, exempt_from_overtime: true)
      create(:attendance_record, user: exempt, work_date: Date.new(2026, 3, 3), status: :clocked_out,
             clock_in: Time.utc(2026, 3, 3, 0), clock_out: Time.utc(2026, 3, 3, 12),
             is_holiday_work: false, actual_work_hours: 10, legal_overtime_hours: 2, scheduled_overtime_hours: 0,
             deep_night_hours: 1.5, is_late: false, late_minutes: 0, is_early_leave: false, early_leave_minutes: 0)
      summary = described_class.call(user: exempt, period: period("2026-03"))
      expect(summary.total_deep_night_hours).to eq(1.5)
      expect(summary.total_overtime_hours).to eq(2)
    end
  end

  describe "冪等性（行数不変 + 追従）" do
    it "2 回 call で count 不変・id 不変、AR 追加で値が追従" do
      org.setting.update!(closing_day: 31)
      worked(Date.new(2026, 3, 3), actual: 8)
      first = described_class.call(user:, period: period("2026-03"))
      expect { described_class.call(user:, period: period("2026-03")) }
        .not_to change { MonthlyAttendanceSummary.count }
      again = described_class.call(user:, period: period("2026-03"))
      expect(again.id).to eq(first.id)

      worked(Date.new(2026, 3, 4), actual: 5)
      updated = described_class.call(user:, period: period("2026-03"))
      expect(updated.total_work_hours).to eq(8 + 5) # 古い値が残らずフル上書き
    end
  end
```

- [ ] **Step 2: Run tests to verify the new weekly/2系統 ones fail**

Run: `bundle exec rspec spec/services/monthly_summaries/aggregate_spec.rb -e "週 40h 統合"`
Expected: FAIL（週次が未加算ゆえ `total_overtime` が 0 のまま＝42h 週で 2h を期待して落ちる）

- [ ] **Step 3: Integrate the weekly calculator into the service**

`total_overtime_hours` に週次 extra を加え、週次の値写像メソッドを追加する。`app/services/monthly_summaries/aggregate.rb` の `total_overtime_hours` を差し替え、`weekly_overtime_hours` を private に追加:

```ruby
    # 日次 legal OT 寄与（period.range 内・法定休日除く）＋ 週次 extra（週末土曜が period.range 内）。
    # 日次=各日の属する締め期間／週次=土曜の属する締め期間（二重の帰属軸・設計 §3.3）。
    def total_overtime_hours
      @total_overtime_hours ||=
        sum_hours(in_period.reject { holiday_work?(_1) }, :legal_overtime_hours) + weekly_overtime_hours
    end

    # service は worked_records を calculator が食える値配列へ写すだけ。分配は WeeklyOvertimeCalculator（D8）。
    def weekly_overtime_hours
      days = worked_records.map do |r|
        { date: r.work_date,
          actual_hours: r.actual_work_hours || 0,
          daily_legal_overtime_hours: r.legal_overtime_hours || 0,
          legal_holiday_work: holiday_work?(r),
          flextime: r.work_pattern&.flextime? || false } # D7・未割当は false
      end
      WeeklyOvertimeCalculator.call(period_range: @period.range, days:)
    end
```

- [ ] **Step 4: Run the full service spec to verify all pass**

Run: `bundle exec rspec spec/services/monthly_summaries/aggregate_spec.rb`
Expected: PASS（Task 4 分も含め全 example green）

- [ ] **Step 5: Lint, brakeman & commit**

```bash
bundle exec rubocop --force-exclusion app/services/monthly_summaries/aggregate.rb spec/services/monthly_summaries/aggregate_spec.rb
bin/brakeman --no-pager
git add app/services/monthly_summaries/aggregate.rb spec/services/monthly_summaries/aggregate_spec.rb
git commit -m "feat: MonthlySummaries::Aggregate 週40h統合 + 2系統/60h/冪等（3-1 §3.3・§4.4）"
```

---

### Task 6: ROADMAP 更新 + 全体 preflight（PR 前）

**Files:**
- Modify: `docs/ROADMAP.md`（3-1 行のチェック + PR 番号は PR 作成後）

- [ ] **Step 1: 全テスト + 静的検証を回す**

Run:
```bash
bundle exec rspec
bundle exec rubocop
bin/brakeman --no-pager
```
Expected: rspec 全 green（既存 + 新規）・rubocop offense 0・brakeman warning 0。

- [ ] **Step 2: `/preflight` スキルで CI 等価チェック**

`/preflight` を実行し、push/PR 前の CI 等価検証（coverage 含む）をまとめて通す。

- [ ] **Step 3: ROADMAP の 3-1 行を更新**

`docs/ROADMAP.md` の `- [ ] **3-1 MonthlyAttendanceSummary + 集計**` を `- [x]` にし、PR リンクを付す（PR 作成後に番号確定）。本スライスで確立した申し送り（F1 status ゲート・F2 `period.next` カスケード・F4 単一エンジン・F5 3-3 が休暇集計吸収・限界12 FY 帰属）を 3-2/3-3/4-x の該当行 or バックログへ 1 行ずつ追記。

- [ ] **Step 4: Commit & PR**

```bash
git add docs/ROADMAP.md
git commit -m "docs: ROADMAP 3-1 完了マーク + 3-2/3-3/4-x ハンドオフ追記"
```
その後 `gh pr create`（`gh auth switch -u kei1110` を先に確認・base main・squash マージ）。

---

## Self-Review

**Spec coverage（設計 §1〜§5 → タスク対応）:**
- §1.1 MonthlyAttendanceSummary（カラム・検証・同一組織・index）→ Task 3 ✓
- §1.2 AttendancePeriod（range/week_window/prev/next/fiscal_year・closing_day クランプ）→ Task 1 ✓
- §2 WeeklyOvertimeCalculator（40h 境界・重複控除・負クランプ・法定休日/flextime 除外・期間帰属）→ Task 2 ✓
- §3.1 窓 fetch（period.week_window・with_tenant・worked ゲート・day_types 注入）→ Task 4 ✓
- §3.2 日次集計（work_days/scheduled/total_work/deep_night/holiday_work/late/early・status ゲート）→ Task 4 ✓
- §3.3 週次統合（calculator 呼び出し・total_overtime 合成・over_60）→ Task 5 ✓
- §3.4 冪等 upsert（find_or_initialize + update!・F1 無条件上書き契約）→ Task 4（永続化）/ Task 5（追従テスト）✓
- §4 テスト（calculator/AttendancePeriod/model/service の各マトリクス）→ 各タスクの spec ✓
- §5 限界（F1/F2/F4/FY 帰属）→ Task 6 でハンドオフ追記 ✓

**Placeholder scan:** 各 step に実コード/実コマンド/期待出力を記載。"TBD"/"適切な〜"/"上記のテスト" は不使用。

**Type consistency:**
- `WeeklyOvertimeCalculator.call(period_range:, days:)` — Task 2 定義 = Task 5 呼び出し一致 ✓
- `AttendancePeriod#range / #week_window / #label / #fiscal_year` — Task 1 定義 = Task 4/5 使用一致 ✓
- `MonthlySummaries::Aggregate.call(user:, period:, day_types:)` — Task 4 定義 = テスト呼び出し一致 ✓
- `MonthlyAttendanceSummary` カラム名（`total_overtime_hours` 等）— Task 3 migration = Task 4/5 `update!` キー一致 ✓

**注記（既知の割り切り）:** `holiday_work_hours` の `is_holiday_work` は出勤系 status の行にのみ立つ前提（2-4 の付与経路）。`worked_records` ゲートと整合。flextime 判定は `work_pattern&.flextime?`（未割当 nil → false）。
