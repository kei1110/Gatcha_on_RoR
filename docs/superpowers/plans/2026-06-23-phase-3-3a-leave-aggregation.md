# Phase 3-3a 休暇集計の素材整備 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 月次サマリ CSV（§6.4）が要求する `paid_leave_days_used` / `total_leave_hours` を `MonthlyAttendanceSummary` へ集計保存できるよう、休暇 AttendanceRecord に `leave_type_id` を持たせ（A 案）、承認 hot path と集計エンジンを拡張する。

**Architecture:** 休暇 AR を「どの種別の休暇か」まで自己記述させ（`leave_type_id`）、`MonthlySummaries::LeaveAggregator` が period 内の凍結済み leave-status AR を**直接読む**（counted_dates 非再計算＝drift ゼロ）。`Aggregate` が 2 値を合成して MAS へ upsert。CSV 出力（exporter/controller/UI）は後続 PR **3-3b**。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / RSpec / FactoryBot / acts_as_tenant / BigDecimal。

**設計典拠:** `docs/superpowers/specs/2026-06-23-phase-3-3-csv-design.md`（§1–§4・§7）。本 plan は同 spec の 3-3a 範囲（§1 データモデル・§2 承認 hot path・§3 集計）を実装する。

## Global Constraints

- **ブランチ:** `feat/phase3-3a-leave-aggregation`（作成済・このブランチで作業）。コミット identity は kei1110 `<eoh2145@gmail.com>`。
- **テナント安全（§3.6）:** model/service/migration はすべてテナント文脈で動く。service は `ActsAsTenant.with_tenant(user.organization)` で自己完結ラップ。テストは `let(:org){create(:organization)}` + `around { |ex| ActsAsTenant.with_tenant(org){ex.run} }`。
- **数値は BigDecimal:** 日数・時間の集計は `BigDecimal("0")` 初期化の `sum`（既存 `aggregate.rb` 同型）。
- **frozen_string_literal:** 全 .rb 先頭に `# frozen_string_literal: true`。
- **schema.rb は手編集禁止:** `bin/rails db:migrate` 経由でのみ更新（生成物ゆえコミットに含める）。
- **status enum（§13.1 凍結・整数）:** working=0 / clocked_out=1 / morning_half=2 / afternoon_half=3 / on_leave=4。`AttendanceRecord::LEAVE_STATUSES = %w[morning_half afternoon_half on_leave]`。
- **CHECK 違反テストは `transaction(requires_new: true)` で DB RAISE 隔離**（transactional fixtures が壊れるのを防ぐ）。
- **完了時:** `bundle exec rspec`・`bundle exec rubocop --force-exclusion <touched>`・`bin/brakeman --no-pager`。merge 前に `tenant-isolation-reviewer` + `approval-engine-reviewer`、`/preflight`。

---

## ファイル構成

- Create: `db/migrate/<ts>_add_leave_type_to_attendance_records.rb` — AR に `leave_type_id` + 複合 FK + CHECK
- Create: `db/migrate/<ts>_add_leave_columns_to_monthly_attendance_summaries.rb` — MAS に 2 列
- Modify: `app/models/attendance_record.rb` — `belongs_to :leave_type` + 整合バリデーション
- Modify: `app/services/leave_requests/apply_approval.rb` — 休暇 AR に `leave_type_id` set
- Modify: `app/services/leave_requests/withdraw.rb` — 戻し分岐で `leave_type_id` クリア
- Create: `app/services/monthly_summaries/leave_aggregator.rb` — 休暇集計（query object）
- Modify: `app/services/monthly_summaries/aggregate.rb` — LeaveAggregator を合成
- Test: `spec/models/attendance_record_spec.rb`・`spec/models/monthly_attendance_summary_spec.rb`・`spec/services/leave_requests/apply_approval_spec.rb`・`spec/services/leave_requests/withdraw_spec.rb`・`spec/services/monthly_summaries/leave_aggregator_spec.rb`（新）・`spec/services/monthly_summaries/aggregate_spec.rb`

---

### Task 1: AR に `leave_type_id`（migration + model + 整合バリデーション + CHECK）

**Files:**
- Create: `db/migrate/<ts>_add_leave_type_to_attendance_records.rb`
- Modify: `app/models/attendance_record.rb`
- Test: `spec/models/attendance_record_spec.rb`

**Interfaces:**
- Produces: `AttendanceRecord#leave_type` / `#leave_type_id`（nullable）・`leave_type_only_on_leave_status` validation・DB CHECK `attendance_records_leave_type_only_on_leave_status`。

- [ ] **Step 1: 失敗するモデル spec を書く**

`spec/models/attendance_record_spec.rb` に追記（末尾の最終 `end` の直前）:

```ruby
  describe "leave_type 整合（3-3a）" do
    let(:leave_type) { create(:leave_type) }

    it "worked status（clocked_out）に leave_type を付けると invalid" do
      rec = build(:attendance_record, :done, leave_type:)
      expect(rec).to be_invalid
      expect(rec.errors[:leave_type]).to be_present
    end

    it "on_leave status なら leave_type を付けて valid" do
      rec = build(:attendance_record, status: :on_leave, clock_in: nil, leave_type:)
      expect(rec).to be_valid
    end

    it "leave_type なしの worked は valid（回帰）" do
      expect(build(:attendance_record, :done)).to be_valid
    end

    it "CHECK 制約: worked 行へ leave_type_id を update_column で差しても DB が弾く" do
      rec = create(:attendance_record, :done)
      expect do
        ActiveRecord::Base.transaction(requires_new: true) do
          rec.update_column(:leave_type_id, leave_type.id) # validation バイパス
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /leave_type_only_on_leave_status|check constraint/i)
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb -e "leave_type 整合"`
Expected: FAIL（`leave_type` 関連付け未定義 / カラム無し）

- [ ] **Step 3: migration を生成して中身を書く**

Run: `bin/rails g migration AddLeaveTypeToAttendanceRecords`

生成された `db/migrate/<ts>_add_leave_type_to_attendance_records.rb` を以下に置き換える:

```ruby
# frozen_string_literal: true

class AddLeaveTypeToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    add_column :attendance_records, :leave_type_id, :bigint, null: true

    # クロステナント参照を DB 層で遮断（既存 work_patterns FK と同型・§3.6）。
    # leave_type_id NULL の worked 行は MATCH SIMPLE で検査スキップ。
    add_foreign_key :attendance_records, :leave_types,
                    column: [ :organization_id, :leave_type_id ], primary_key: [ :organization_id, :id ]

    # worked 行（status 0/1）に休暇種別が紛れ込むのを DB 最終防衛（設計 D8）。
    # status enum: working=0 / clocked_out=1 / morning_half=2 / afternoon_half=3 / on_leave=4（§13.1 凍結）。
    # leave 系 status を追加する場合は本 CHECK も更新すること。
    add_check_constraint :attendance_records,
                         "leave_type_id IS NULL OR status IN (2, 3, 4)",
                         name: "attendance_records_leave_type_only_on_leave_status"

    # 参照側 index は入れない（集計は既存 [user_id, work_date] index が担当・設計 §1.1a）。
  end
end
```

- [ ] **Step 4: model に関連付けとバリデーションを足す**

`app/models/attendance_record.rb` の既存 `belongs_to` 群の隣に:

```ruby
  belongs_to :leave_type, optional: true
```

`validate :clock_out_not_before_clock_in` の隣（validation 宣言群）に:

```ruby
  validate :leave_type_only_on_leave_status
```

`private` 以下、`leave_status?` の隣に:

```ruby
  def leave_type_only_on_leave_status
    return if leave_type_id.nil? || leave_status?

    errors.add(:leave_type, "は休暇ステータスの記録にのみ設定できます")
  end
```

- [ ] **Step 5: migrate して spec を通す**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bundle exec rspec spec/models/attendance_record_spec.rb -e "leave_type 整合"`
Expected: PASS（4 examples）

- [ ] **Step 6: 全体回帰 + lint**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb && bundle exec rubocop --force-exclusion db/migrate app/models/attendance_record.rb`
Expected: PASS / no offenses

- [ ] **Step 7: コミット**

```bash
git add db/migrate db/schema.rb app/models/attendance_record.rb spec/models/attendance_record_spec.rb
git commit -m "feat: AR に leave_type_id（複合 FK + CHECK + 整合バリデーション）"
```

---

### Task 2: MAS に休暇 2 列（migration）

**Files:**
- Create: `db/migrate/<ts>_add_leave_columns_to_monthly_attendance_summaries.rb`
- Test: `spec/models/monthly_attendance_summary_spec.rb`

**Interfaces:**
- Produces: `MonthlyAttendanceSummary#paid_leave_days_used` / `#total_leave_hours`（decimal・NOT NULL・default 0）。

- [ ] **Step 1: 失敗する spec を書く**

`spec/models/monthly_attendance_summary_spec.rb` に追記（末尾 `end` の直前。ファイルが無ければ下記を新規作成）:

```ruby
  describe "休暇集計列（3-3a）" do
    it "paid_leave_days_used / total_leave_hours を持ち default 0" do
      summary = create(:monthly_attendance_summary)
      expect(summary.paid_leave_days_used).to eq(0)
      expect(summary.total_leave_hours).to eq(0)
    end
  end
```

新規作成する場合の全文:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlyAttendanceSummary do
  describe "休暇集計列（3-3a）" do
    it "paid_leave_days_used / total_leave_hours を持ち default 0" do
      summary = create(:monthly_attendance_summary)
      expect(summary.paid_leave_days_used).to eq(0)
      expect(summary.total_leave_hours).to eq(0)
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/monthly_attendance_summary_spec.rb -e "休暇集計列"`
Expected: FAIL（`NoMethodError: paid_leave_days_used`）

- [ ] **Step 3: migration を生成して書く**

Run: `bin/rails g migration AddLeaveColumnsToMonthlyAttendanceSummaries`

生成ファイルを置き換える:

```ruby
# frozen_string_literal: true

class AddLeaveColumnsToMonthlyAttendanceSummaries < ActiveRecord::Migration[8.1]
  def change
    # §4.13 の正本に一致（有給使用日数・総休暇時間）。3-3 設計 §1.1(b)。
    add_column :monthly_attendance_summaries, :paid_leave_days_used, :decimal, precision: 6, scale: 2, null: false, default: 0
    add_column :monthly_attendance_summaries, :total_leave_hours, :decimal, precision: 7, scale: 2, null: false, default: 0
  end
end
```

- [ ] **Step 4: migrate して spec を通す**

Run: `bin/rails db:migrate && bin/rails db:test:prepare && bundle exec rspec spec/models/monthly_attendance_summary_spec.rb -e "休暇集計列"`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add db/migrate db/schema.rb spec/models/monthly_attendance_summary_spec.rb
git commit -m "feat: MAS に paid_leave_days_used / total_leave_hours 列"
```

---

### Task 3: `ApplyApproval` が休暇 AR に `leave_type_id` を set

**Files:**
- Modify: `app/services/leave_requests/apply_approval.rb:50-58`（`upsert_attendance_records`）
- Test: `spec/services/leave_requests/apply_approval_spec.rb`

**Interfaces:**
- Consumes: `AttendanceRecord#leave_type_id`（Task 1）。
- Produces: 承認後の leave-status AR は `leave_type_id == leave_request.leave_type_id`。

- [ ] **Step 1: 失敗する spec を書く**

`spec/services/leave_requests/apply_approval_spec.rb` の最終 `end` 直前に追記:

```ruby
  describe "leave_type_id の AR 焼き込み（3-3a）" do
    it "paid 種別: 作成する休暇 AR に leave_type_id を set" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, granted_days: 20, used_days: 0)
      apply(leave(type: paid_type, days: 1))
      rec = AttendanceRecord.find_by(user:, work_date: start_date)
      expect(rec.leave_type_id).to eq(paid_type.id)
    end

    it "非 paid 種別でも leave_type_id を set" do
      apply(leave(type: unpaid_type, days: 1))
      rec = AttendanceRecord.find_by(user:, work_date: start_date)
      expect(rec.leave_type_id).to eq(unpaid_type.id)
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb -e "leave_type_id の AR 焼き込み"`
Expected: FAIL（`leave_type_id` が nil）

- [ ] **Step 3: 実装**

`app/services/leave_requests/apply_approval.rb` の `upsert_attendance_records` 内、`record.status = leave_status` の直後に 1 行:

```ruby
        record.status = leave_status
        record.leave_type_id = @leave_request.leave_type_id
        record.save!
```

- [ ] **Step 4: spec を通す**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb`
Expected: PASS（既存 + 新規 2 例）

- [ ] **Step 5: コミット**

```bash
git add app/services/leave_requests/apply_approval.rb spec/services/leave_requests/apply_approval_spec.rb
git commit -m "feat: 休暇承認の AR upsert で leave_type_id を焼き込む"
```

---

### Task 4: `Withdraw` が戻し分岐で `leave_type_id` をクリア（F3 Critical）

**Files:**
- Modify: `app/services/leave_requests/withdraw.rb:54-58`（`restore_attendance_records` の else 分岐）
- Test: `spec/services/leave_requests/withdraw_spec.rb`

**Interfaces:**
- Consumes: `AttendanceRecord#leave_type_id`（Task 1）・CHECK 制約。
- Produces: 撤回承認で worked へ戻る AR は `leave_type_id` が nil。

- [ ] **Step 1: 失敗する spec を書く**

`spec/services/leave_requests/withdraw_spec.rb` の最終 `end` 直前に追記:

```ruby
  describe "leave_type_id クリア（3-3a・F3）" do
    it "打刻ありの半休戻しで leave_type_id を nil に戻す" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
      rec = create(:attendance_record, :done, user:, work_date: start_date,
                   status: :afternoon_half, leave_type: paid_type)
      withdraw(create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                      half_day_type: :afternoon, days_requested: BigDecimal("0.5"),
                      approval_status: :withdrawal_requested, withdrawal_reason: "x"))
      rec.reload
      expect(rec.status).to eq("clocked_out")
      expect(rec.leave_type_id).to be_nil
    end

    it "clocked 済日への全休 stale 戻しでも leave_type_id クリア（line-104）" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
      rec = create(:attendance_record, :done, user:, work_date: start_date,
                   status: :on_leave, leave_type: paid_type)
      withdraw(leave(type: paid_type, days: 1))
      rec.reload
      expect(rec.status).to eq("clocked_out")
      expect(rec.leave_type_id).to be_nil
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/leave_requests/withdraw_spec.rb -e "leave_type_id クリア"`
Expected: FAIL（`leave_type_id` が残る・または CHECK 違反で raise）

- [ ] **Step 3: 実装**

`app/services/leave_requests/withdraw.rb` の `restore_attendance_records` 内 else 分岐を変更:

```ruby
          else
            record.update!(status: record.clock_out.present? ? :clocked_out : :working, leave_type_id: nil)
            Clockings::Recalculate.call(record:) if record.clock_out.present?
          end
```

- [ ] **Step 4: spec を通す**

Run: `bundle exec rspec spec/services/leave_requests/withdraw_spec.rb`
Expected: PASS（既存 + 新規 2 例）

- [ ] **Step 5: コミット**

```bash
git add app/services/leave_requests/withdraw.rb spec/services/leave_requests/withdraw_spec.rb
git commit -m "fix: 撤回戻しで worked へ戻る AR の leave_type_id をクリア（CHECK 整合・F3）"
```

---

### Task 5: `MonthlySummaries::LeaveAggregator`（休暇集計の query object）

**Files:**
- Create: `app/services/monthly_summaries/leave_aggregator.rb`
- Test: `spec/services/monthly_summaries/leave_aggregator_spec.rb`

**Interfaces:**
- Consumes: `AttendanceRecord#leave_type` / `#work_pattern` / `#status`・`AttendancePeriod#range`・`UserWorkPattern`（effective 解決）。
- Produces: `LeaveAggregator.call(user:, period:) → { paid_leave_days_used: BigDecimal, total_leave_hours: BigDecimal }`。

- [ ] **Step 1: 失敗する spec を書く**

`spec/services/monthly_summaries/leave_aggregator_spec.rb` を新規作成:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe MonthlySummaries::LeaveAggregator do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:user) { create(:user, organization: org) }
  let(:paid_type) { create(:leave_type, system_type: :annual, paid_leave: true, allow_half_day: true) }
  let(:unpaid_type) { create(:leave_type, system_type: :other, paid_leave: false, allow_half_day: true) }

  def period(year_month) = AttendancePeriod.new(organization: org, year_month:)

  def assign_pattern(hours, start_date: Date.new(2026, 1, 1))
    create(:user_work_pattern, user:, start_date:,
           work_pattern: create(:work_pattern, standard_work_hours: hours))
  end

  def leave_ar(date, status:, type:, **attrs)
    create(:attendance_record, user:, work_date: date, status:, clock_in: nil, leave_type: type, **attrs)
  end

  before { org.setting.update!(closing_day: 31) }

  it "paid 全休 1 日 = paid 1.0 / total_leave_hours = standard_work_hours" do
    assign_pattern(8)
    leave_ar(Date.new(2026, 3, 2), status: :on_leave, type: paid_type)
    result = described_class.call(user:, period: period("2026-03"))
    expect(result[:paid_leave_days_used]).to eq(1)
    expect(result[:total_leave_hours]).to eq(8)
  end

  it "unpaid は paid に乗らないが total_leave_hours には乗る（全種別）" do
    assign_pattern(8)
    leave_ar(Date.new(2026, 3, 2), status: :on_leave, type: unpaid_type)
    result = described_class.call(user:, period: period("2026-03"))
    expect(result[:paid_leave_days_used]).to eq(0)
    expect(result[:total_leave_hours]).to eq(8)
  end

  it "半休（afternoon_half・打刻なし）= 0.5 日 / standard_work_hours ÷2" do
    assign_pattern(8)
    leave_ar(Date.new(2026, 3, 2), status: :afternoon_half, type: paid_type)
    result = described_class.call(user:, period: period("2026-03"))
    expect(result[:paid_leave_days_used]).to eq(BigDecimal("0.5"))
    expect(result[:total_leave_hours]).to eq(4)
  end

  it "standard_work_hours=7 のパターンは full leave 7h" do
    assign_pattern(7)
    leave_ar(Date.new(2026, 3, 2), status: :on_leave, type: paid_type)
    expect(described_class.call(user:, period: period("2026-03"))[:total_leave_hours]).to eq(7)
  end

  it "未割当日（effective パターンなし）は hours 0h・paid は計上" do
    leave_ar(Date.new(2026, 3, 2), status: :on_leave, type: paid_type) # 割当なし
    result = described_class.call(user:, period: period("2026-03"))
    expect(result[:paid_leave_days_used]).to eq(1)
    expect(result[:total_leave_hours]).to eq(0)
  end

  it "半休+打刻 AR は work_pattern スナップショットを優先（effective でなく snapshot）" do
    snapshot = create(:work_pattern, standard_work_hours: 6)
    assign_pattern(8) # effective は 8h だが snapshot 優先なら 3h（6÷2）
    create(:attendance_record, :done, user:, work_date: Date.new(2026, 3, 2),
           status: :afternoon_half, leave_type: paid_type, work_pattern: snapshot)
    expect(described_class.call(user:, period: period("2026-03"))[:total_leave_hours]).to eq(3)
  end

  it "period.range 外の leave AR は計上しない（月跨ぎ per-day）" do
    assign_pattern(8)
    leave_ar(Date.new(2026, 4, 1), status: :on_leave, type: paid_type) # 翌期
    result = described_class.call(user:, period: period("2026-03"))
    expect(result[:paid_leave_days_used]).to eq(0)
    expect(result[:total_leave_hours]).to eq(0)
  end

  it "他社の同日 leave AR を混ぜない（テナント分離）" do
    assign_pattern(8)
    leave_ar(Date.new(2026, 3, 2), status: :on_leave, type: paid_type)
    other = create(:organization)
    ActsAsTenant.with_tenant(other) do
      ou = create(:user, organization: other)
      ot = create(:leave_type, organization: other, paid_leave: true)
      create(:attendance_record, user: ou, work_date: Date.new(2026, 3, 2),
             status: :on_leave, clock_in: nil, leave_type: ot)
    end
    expect(described_class.call(user:, period: period("2026-03"))[:paid_leave_days_used]).to eq(1)
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/monthly_summaries/leave_aggregator_spec.rb`
Expected: FAIL（`uninitialized constant MonthlySummaries::LeaveAggregator`）

- [ ] **Step 3: 実装**

`app/services/monthly_summaries/leave_aggregator.rb` を新規作成:

```ruby
# frozen_string_literal: true

require "bigdecimal"

module MonthlySummaries
  # 休暇集計（SPEC §6.4・§4.13・3-3 設計 §3.1）。
  # period.range 内の leave-status AR を直接読む（counted_dates 非再計算＝drift なし・D5）。
  # paid_leave_days_used（paid 種別のみ・日/半 0.5）と total_leave_hours（全種別・所定時間換算）を返す。
  # 計算 8 列は読まない（status / leave_type / standard_work_hours のみ）ゆえ .calculated を課さない。
  class LeaveAggregator
    HALF_STATUSES = %w[morning_half afternoon_half].freeze

    def self.call(user:, period:) = new(user:, period:).call

    def initialize(user:, period:)
      @user = user
      @period = period
    end

    def call
      ActsAsTenant.with_tenant(@user.organization) do
        {
          paid_leave_days_used: leave_records.sum(BigDecimal("0")) { paid_weight(_1) },
          total_leave_hours:    leave_records.sum(BigDecimal("0")) { hours_for(_1) }
        }
      end
    end

    private

    def leave_records
      @leave_records ||= AttendanceRecord
        .where(user: @user, work_date: @period.range, status: AttendanceRecord::LEAVE_STATUSES)
        .includes(:leave_type, :work_pattern).to_a
    end

    def weight(record) = HALF_STATUSES.include?(record.status) ? BigDecimal("0.5") : BigDecimal("1")

    def paid_weight(record) = record.leave_type&.paid_leave? ? weight(record) : BigDecimal("0")

    def hours_for(record)
      hours = standard_hours_on(record)
      return BigDecimal("0") if hours.nil?

      HALF_STATUSES.include?(record.status) ? hours / 2 : hours
    end

    # §6.1 スナップショット優先: 半休+打刻 AR は work_pattern_id を持つ → record.work_pattern。
    # 純休暇日（work_pattern_id NULL）のみ effective 割当を解決し worked 集計と同日で乖離させない。
    def standard_hours_on(record)
      pattern = record.work_pattern || effective_pattern_on(record.work_date)
      pattern&.standard_work_hours
    end

    def effective_pattern_on(date)
      user_assignments.find do |a|
        a.start_date <= date && (a.end_date.nil? || a.end_date >= date)
      end&.work_pattern
    end

    # active 割当を 1 回ロード（N+1 回避・effective_on と同条件）
    def user_assignments
      @user_assignments ||= @user.user_work_patterns.where(active: true).includes(:work_pattern).to_a
    end
  end
end
```

- [ ] **Step 4: spec を通す**

Run: `bundle exec rspec spec/services/monthly_summaries/leave_aggregator_spec.rb`
Expected: PASS（8 examples）

- [ ] **Step 5: lint + コミット**

```bash
bundle exec rubocop --force-exclusion app/services/monthly_summaries/leave_aggregator.rb
git add app/services/monthly_summaries/leave_aggregator.rb spec/services/monthly_summaries/leave_aggregator_spec.rb
git commit -m "feat: MonthlySummaries::LeaveAggregator（休暇集計・snapshot 優先・drift なし）"
```

---

### Task 6: `Aggregate` が LeaveAggregator を合成

**Files:**
- Modify: `app/services/monthly_summaries/aggregate.rb:32-44`（`attributes`）
- Test: `spec/services/monthly_summaries/aggregate_spec.rb`

**Interfaces:**
- Consumes: `LeaveAggregator.call(user:, period:)`（Task 5）。
- Produces: MAS の `paid_leave_days_used` / `total_leave_hours` が保存される。

- [ ] **Step 1: 失敗する spec を書く**

`spec/services/monthly_summaries/aggregate_spec.rb` の最終 `end` 直前に追記:

```ruby
  describe "休暇集計の合成（3-3a・§3.2）" do
    let(:paid_type) { create(:leave_type, system_type: :annual, paid_leave: true) }

    it "paid_leave_days_used / total_leave_hours を MAS に保存" do
      org.setting.update!(closing_day: 31)
      create(:user_work_pattern, user:, start_date: Date.new(2026, 1, 1),
             work_pattern: create(:work_pattern, standard_work_hours: 8))
      create(:attendance_record, user:, work_date: Date.new(2026, 3, 2),
             status: :on_leave, clock_in: nil, leave_type: paid_type)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.paid_leave_days_used).to eq(1)
      expect(summary.total_leave_hours).to eq(8)
    end

    it "休暇は worked 集計（work_days/total_work_hours）に混入しない" do
      org.setting.update!(closing_day: 31)
      create(:attendance_record, user:, work_date: Date.new(2026, 3, 2),
             status: :on_leave, clock_in: nil, leave_type: paid_type)
      worked(Date.new(2026, 3, 3), actual: 8)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.work_days).to eq(1)
      expect(summary.total_work_hours).to eq(8)
      expect(summary.paid_leave_days_used).to eq(1)
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/monthly_summaries/aggregate_spec.rb -e "休暇集計の合成"`
Expected: FAIL（`paid_leave_days_used` が 0 のまま）

- [ ] **Step 3: 実装**

`app/services/monthly_summaries/aggregate.rb` の `attributes` 末尾の `}` を `.merge(...)` に変更:

```ruby
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
      }.merge(LeaveAggregator.call(user: @user, period: @period))
    end
```

- [ ] **Step 4: spec を通す**

Run: `bundle exec rspec spec/services/monthly_summaries/aggregate_spec.rb`
Expected: PASS（既存 + 新規 2 例）

- [ ] **Step 5: コミット**

```bash
git add app/services/monthly_summaries/aggregate.rb spec/services/monthly_summaries/aggregate_spec.rb
git commit -m "feat: Aggregate に休暇集計（paid_leave_days_used / total_leave_hours）を合成"
```

---

### Task 7: 全体検証 + ROADMAP 更新 + PR

**Files:**
- Modify: `docs/ROADMAP.md`（Phase 3-3 行に 3-3a の進捗を追記）

- [ ] **Step 1: フル回帰**

Run: `bundle exec rspec`
Expected: 全 PASS（既存 + 新規。緑でなければ修正してから次へ）

- [ ] **Step 2: lint + セキュリティ**

Run: `bundle exec rubocop --force-exclusion $(git diff --name-only main --diff-filter=d -- '*.rb') && bin/brakeman --no-pager`
Expected: no offenses / no new warnings

- [ ] **Step 3: ROADMAP に 3-3a の進捗注記**

`docs/ROADMAP.md` の Phase 3-3 行（line 58）に 3-3a 完了の旨と PR 番号を追記（3-3b は別 PR で完了時にチェック）。例:

```markdown
- [ ] **3-3 CSV 2 種**: 月次サマリ・日別明細（UTF-8 BOM・割増区分網羅・§6.4）。**3-3a 休暇集計の素材整備**（AR `leave_type_id`・LeaveAggregator・MAS 2 列）done（PR #XX）／3-3b CSV 出力は後続
```

- [ ] **Step 4: コミット**

```bash
git add docs/ROADMAP.md
git commit -m "docs: ROADMAP に Phase 3-3a（休暇集計の素材整備）の進捗を追記"
```

- [ ] **Step 5: `/preflight` → サブエージェントレビュー → PR**

- `/preflight` を実行（CI 等価の静的検証）。
- `tenant-isolation-reviewer`（migration・FK・テナントラップ）+ `approval-engine-reviewer`（ApplyApproval/Withdraw の atomicity・CHECK 整合）を merge 前に起動。
- `gh pr create`（必要なら `gh auth switch -u kei1110`）。PR 本文に設計 spec リンクと「3-3a スコープ・3-3b は後続」を明記。

---

## Self-Review（spec カバレッジ）

- **§1.1(a) AR leave_type_id + FK + CHECK** → Task 1 ✅
- **§1.1(b) MAS 2 列** → Task 2 ✅
- **§1.1(c) backfill 廃止（再 seed）** → migration を書かない＝実装なし（spec D2/§1.1c の決定どおり）✅
- **§1.2 AR モデル（belongs_to + validation）** → Task 1 ✅
- **§2.1 ApplyApproval set** → Task 3 ✅（absence_to_paid は Phase 4-2 handoff・本 plan 範囲外）
- **§2.2 Withdraw clear（両分岐・F3 Critical）** → Task 4 ✅
- **§3.1 LeaveAggregator（snapshot 優先・全種別 hours・paid 日数・未割当 0h）** → Task 5 ✅
- **§3.2 Aggregate 合成（worked 非混入）** → Task 6 ✅
- **§3.1 注記（§8.6 母集団との境界）** → コード挙動でなく文書 handoff。`LABOR_LAW_REVIEW_NOTES.md` 追記は本 PR の docs ステップで実施（Task 7 に内包・spec 付録）
- **§5–§6（CSV exporter / controller / UI）** → **3-3b の別 plan**（本 plan 範囲外）
- **§7.2 テスト** → 各 Task の spec で網羅（mass-assignment guard は controller 不在ゆえ 3-3b の request spec へ。本 plan は AR への leave_type_id 経路が ApplyApproval サーバ権威のみである点を Task 3 で担保）

> **補足（LABOR_NOTES）:** Task 7 Step 3 と同コミットで `docs/LABOR_LAW_REVIEW_NOTES.md` に spec 付録の文案（`paid_leave_days_used` ≠ §8.6 母集団・給与連携前提の社労士確認）を追記してよい。
