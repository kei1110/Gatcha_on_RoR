# Phase 1-2 計算オブジェクト 4 種 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 退勤打刻時に実労働・残業 2 系統・深夜・遅刻早退を純粋 PORO で算出し attendance_records の 8 列へ保存する（SPEC §5.1〜5.4・設計 docs/superpowers/specs/2026-06-13-phase1-2-calculators-design.md）。

**Architecture:** `app/calculators/` に入力合成（ScheduledWindow）+ 丸め単一ソース（MinuteConversion）+ 4 calculator の純粋層を置き、書き戻しは `Clockings::Recalculate` の一本道。ClockOut からは打刻保全 + rescue 報告（R4）で呼ぶ。

**Tech Stack:** Rails 8.1 / PostgreSQL 17 / RSpec + FactoryBot / acts_as_tenant。

**実行ノート（DEVELOPMENT_WORKFLOW.md 準拠）:**
- Task 1〜7 は完全コード付きの機械的タスク = **haiku 転写候補**。Task 8〜9 は統合（sonnet）。Task 10 は docs（主エージェント直接可）
- 品質レビューバッチ: ①Task 1〜7 完了後（calculator 層）②Task 8〜10 完了後（統合 + docs）。レビュアーには docs/RAILS_GOTCHAS.md を注入し**実挙動検証義務**を課す
- 各ディスパッチにサブエージェント 3 か条を注入: 即コミット / 不要編集 revert / 検証コマンド明記（`bundle exec rspec` `bundle exec rubocop --force-exclusion <files>`・app/ に触れたら `bin/brakeman --no-pager`）
- 時刻リテラル規約: 既存 spec と同じく **UTC リテラル + JST コメント**（org 既定 TZ = Asia/Tokyo = UTC+9）。calculator 単体 spec は JST zone を直接使う

---

## Task 1: migration + AttendanceRecord 計算 8 列

**Files:**
- Create: `db/migrate/<timestamp>_add_calculation_columns_to_attendance_records.rb`（`bin/rails g migration` で生成）
- Modify: `app/models/attendance_record.rb`
- Test: `spec/models/attendance_record_spec.rb`（既存ファイルへ describe 追記）

- [ ] **Step 1: 失敗するテストを書く** — `spec/models/attendance_record_spec.rb` の最上位 describe 内末尾に追記:

```ruby
  describe "計算 8 列（1-2 設計 §1）" do
    let(:org) { create(:organization) }
    let(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

    it "numericality: 負値 invalid・nil valid（NULL = 未計算）" do
      ActsAsTenant.with_tenant(org) do
        record = build(:attendance_record, user:,
                       actual_work_hours: -1, legal_overtime_hours: -1, scheduled_overtime_hours: -1,
                       deep_night_hours: -1, late_minutes: -5, early_leave_minutes: -5)
        expect(record).not_to be_valid
        %i[actual_work_hours legal_overtime_hours scheduled_overtime_hours
           deep_night_hours late_minutes early_leave_minutes].each do |col|
          expect(record.errors[col]).to be_present
        end
        expect(build(:attendance_record, user:)).to be_valid # 8 列 nil で valid
      end
    end

    it "calculated スコープは actual_work_hours 非 NULL のみ返す（is_late 直接 where 禁止の代替経路）" do
      ActsAsTenant.with_tenant(org) do
        raw  = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1))
        calc = create(:attendance_record, user:, work_date: Date.new(2026, 6, 2),
                      clock_in: Time.utc(2026, 6, 2, 0), status: :clocked_out,
                      clock_out: Time.utc(2026, 6, 2, 9), actual_work_hours: 8.0)
        expect(AttendanceRecord.calculated).to contain_exactly(calc)
        expect(AttendanceRecord.calculated).not_to include(raw)
      end
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb`
Expected: FAIL（`actual_work_hours` カラム不在 / `calculated` スコープ未定義）

- [ ] **Step 3: migration 生成 + 記述**

Run: `bin/rails g migration AddCalculationColumnsToAttendanceRecords`

```ruby
class AddCalculationColumnsToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    # 計算 8 列（SPEC §4.8・1-2 設計 §1）。全列 NULL 許容・default なし — NULL = 未計算。
    # 0 埋めは「残業ゼロ」と区別不能（監査上の欠陥）ゆえ採らない
    change_table :attendance_records, bulk: true do |t|
      t.decimal :actual_work_hours, precision: 6, scale: 2
      t.decimal :legal_overtime_hours, precision: 6, scale: 2
      t.decimal :scheduled_overtime_hours, precision: 6, scale: 2
      t.decimal :deep_night_hours, precision: 6, scale: 2
      t.boolean :is_late
      t.boolean :is_early_leave
      t.integer :late_minutes
      t.integer :early_leave_minutes
    end
  end
end
```

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: migrate 成功・schema.rb に 8 列追加（**schema.rb は手編集禁止 — migration 経由のみ**）

- [ ] **Step 4: モデル追記** — `app/models/attendance_record.rb` の `scope :working_within` の直後に追加:

```ruby
  # 計算 8 列（SPEC §4.8・1-2 設計 §1）。書き込みは Clockings::Recalculate 限定 —
  # NULL = 未計算（Recalculate が一括書き込みするため 8 列は一括 NULL / 一括非 NULL が不変条件）。
  # 未計算の除外は必ずこのスコープ経由。is_late 等の boolean を直接 where しないこと —
  # `where(is_late: false)` は SQL 3 値論理で NULL（未計算）行を黙って落とす（1-2 設計 R9）
  scope :calculated, -> { where.not(actual_work_hours: nil) }
```

`validates :clock_in, presence: true` の直後に追加:

```ruby
  validates :actual_work_hours, :legal_overtime_hours, :scheduled_overtime_hours,
            :deep_night_hours, :late_minutes, :early_leave_minutes,
            numericality: { greater_than_or_equal_to: 0 }, allow_nil: true
```

- [ ] **Step 5: パスを確認**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb`
Expected: PASS（既存 example 含む全緑）

- [ ] **Step 6: コミット**

```bash
git add db/migrate db/schema.rb app/models/attendance_record.rb spec/models/attendance_record_spec.rb
git commit -m "feat: attendance_records へ計算 8 列（NULL = 未計算・calculated スコープ）"
```

---

## Task 2: WorkPattern 夜勤等値拒否（R6）

**Files:**
- Modify: `app/models/work_pattern.rb`（`times_must_not_invert_without_night_shift` 検証）
- Test: `spec/models/work_pattern_spec.rb`（既存ファイルへ example 追記）

- [ ] **Step 1: 失敗するテストを書く** — work_pattern_spec.rb の時刻検証の describe 付近に追記:

```ruby
    it "夜勤でも start_time == end_time（長さ 0 の勤務帯）は拒否する（1-2 設計 R6）" do
      pattern = build(:work_pattern, night_shift: true, start_time: "22:00", end_time: "22:00")
      expect(pattern).not_to be_valid
      expect(pattern.errors[:end_time]).to be_present
    end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/work_pattern_spec.rb`
Expected: 新 example のみ FAIL（夜勤は early return で素通りするため valid になってしまう）

- [ ] **Step 3: 検証を修正** — `times_must_not_invert_without_night_shift` を以下へ置換（メソッド名は据え置き — 呼び出し行の変更を避ける。等値拒否の追加は名前の範囲を超えるためコメントで補う）:

```ruby
  # 補強 2（SPEC §4.4 へ逆反映済み）: §5.1 の翌日換算は night_shift かつ start > end が前提。
  # 非夜勤の時刻逆転は負の労働時間を生むため拒否。
  # 等値（長さ 0 の勤務帯）は夜勤含め常時拒否 — ScheduledWindow が長さ 0 の窓になる（1-2 設計 R6）
  def times_must_not_invert_without_night_shift
    return if start_time.blank? || end_time.blank?

    if start_time == end_time
      errors.add(:end_time, "は始業時刻と異なる時刻にしてください")
    elsif !night_shift? && start_time > end_time
      errors.add(:end_time, "は始業時刻より後にしてください（日跨ぎ勤務は夜勤フラグを有効にしてください）")
    end
  end
```

- [ ] **Step 4: パスを確認**

Run: `bundle exec rspec spec/models/work_pattern_spec.rb`
Expected: PASS（既存の非夜勤逆転・等値 example も含め全緑 — 文言を変えた場合は既存 assert を確認）

- [ ] **Step 5: コミット**

```bash
git add app/models/work_pattern.rb spec/models/work_pattern_spec.rb
git commit -m "fix: WorkPattern の夜勤 start == end（長さ 0 勤務帯）を拒否（1-2 R6）"
```

---

## Task 3: MinuteConversion（丸め規則の単一ソース）

**Files:**
- Create: `app/calculators/minute_conversion.rb`
- Test: `spec/calculators/minute_conversion_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "rails_helper"

RSpec.describe MinuteConversion do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }

  describe ".minutes_between" do
    it "差分秒を 60 で整数除算（floor）する" do
      from = zone.local(2026, 6, 1, 9, 0, 30)
      to   = zone.local(2026, 6, 1, 18, 0, 0)
      expect(described_class.minutes_between(from, to)).to eq(539) # 8h59m30s → floor
    end

    it "1 分未満は 0" do
      from = zone.local(2026, 6, 1, 9, 0, 0)
      expect(described_class.minutes_between(from, from + 59)).to eq(0)
    end
  end

  describe ".to_hours" do
    # 整数分 ÷ 60 は第 3 位がちょうど 5 になる値が存在しないため half up/down は判別不能。
    # 検証対象は「切り上げ発火 vs 切り捨て」（1-2 設計 §5・R11）
    it "HALF_UP の切り上げが発火する（truncate との判別値）" do
      expect(described_class.to_hours(10)).to eq(BigDecimal("0.17"))  # truncate なら 0.16
      expect(described_class.to_hours(481)).to eq(BigDecimal("8.02")) # truncate なら 8.01
    end

    it "算術 sanity（非発火値）" do
      expect(described_class.to_hours(0)).to eq(0)
      expect(described_class.to_hours(30)).to eq(BigDecimal("0.5"))
      expect(described_class.to_hours(50)).to eq(BigDecimal("0.83"))
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/calculators/minute_conversion_spec.rb`
Expected: FAIL（NameError: uninitialized constant MinuteConversion）

- [ ] **Step 3: 実装**

```ruby
# 丸め規則の単一ソース（1-2 設計 §3.5・SPEC §5 前文）。
# 中間計算は整数分・最終値のみ時間化（HALF_UP）— 各 calculator へ複製しないこと。
# 第 3 のメソッドは消費者が現れてから足す（YAGNI）
module MinuteConversion
  module_function

  # 全ての分換算は「差分秒 ÷ 60 の整数除算（floor）」で統一（1-2 設計 §0）。
  # TimeWithZone の減算は Float 秒だが、打刻は usec=0 保証（ClockIn/ClockOut で切り詰め）ゆえ
  # 分境界一致時の差分は整数で正確 — floor は安全
  def minutes_between(from, to) = ((to - from) / 60).floor

  def to_hours(minutes) = (minutes.to_d / 60).round(2, half: :up)
end
```

- [ ] **Step 4: パスを確認**

Run: `bundle exec rspec spec/calculators/minute_conversion_spec.rb`
Expected: PASS（4 examples）

- [ ] **Step 5: コミット**

```bash
git add app/calculators/minute_conversion.rb spec/calculators/minute_conversion_spec.rb
git commit -m "feat: MinuteConversion — 秒→分 floor / 分→時 HALF_UP の単一ソース"
```

---

## Task 4: ScheduledWindow（入力合成）

**Files:**
- Create: `app/calculators/scheduled_window.rb`
- Test: `spec/calculators/scheduled_window_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "rails_helper"

# DB 不要 — pattern は Struct duck（night_shift? / flextime? の述語名に応答させること）
RSpec.describe ScheduledWindow do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }
  let(:work_date) { Date.new(2026, 6, 1) }
  let(:duck_class) do
    Struct.new(:start_time, :end_time, :night_shift, :flextime,
               :core_time_start, :core_time_end, :break_minutes,
               :effective_morning_half_break_minutes, :effective_afternoon_half_break_minutes,
               keyword_init: true) do
      def night_shift? = night_shift
      def flextime? = flextime
    end
  end

  # time 型カラムは 2000-01-01 基準の Time — AR の挙動を Time.utc(2000,1,1,...) で再現
  def window(**attrs)
    defaults = {
      start_time: Time.utc(2000, 1, 1, 9), end_time: Time.utc(2000, 1, 1, 18),
      night_shift: false, flextime: false, core_time_start: nil, core_time_end: nil,
      break_minutes: 60,
      effective_morning_half_break_minutes: 30, effective_afternoon_half_break_minutes: 45
    }
    described_class.for(pattern: duck_class.new(**defaults.merge(attrs)), work_date:, zone:)
  end

  it "通常日勤を work_date + 組織 TZ で合成する（コアは nil）" do
    w = window
    expect(w.start_at).to eq(zone.local(2026, 6, 1, 9, 0, 0))
    expect(w.end_at).to eq(zone.local(2026, 6, 1, 18, 0, 0))
    expect(w.core_start_at).to be_nil
    expect(w.core_end_at).to be_nil
  end

  it "夜勤（start > end）は end_at を +1.day 翌日換算する（SPEC §5 入力契約）" do
    w = window(start_time: Time.utc(2000, 1, 1, 22), end_time: Time.utc(2000, 1, 1, 7),
               night_shift: true)
    expect(w.start_at).to eq(zone.local(2026, 6, 1, 22, 0, 0))
    expect(w.end_at).to eq(zone.local(2026, 6, 2, 7, 0, 0))
  end

  it "夜勤フレックスの日跨ぎコア（start > end）は core_end_at のみ翌日換算（R7）" do
    w = window(night_shift: true, flextime: true,
               start_time: Time.utc(2000, 1, 1, 22), end_time: Time.utc(2000, 1, 1, 7),
               core_time_start: Time.utc(2000, 1, 1, 23), core_time_end: Time.utc(2000, 1, 1, 3))
    expect(w.core_start_at).to eq(zone.local(2026, 6, 1, 23, 0, 0))
    expect(w.core_end_at).to eq(zone.local(2026, 6, 2, 3, 0, 0))
  end

  it "break_minutes_for は day_part ごとに委譲する（effective フォールバックの実装は work_pattern_spec が担保）" do
    w = window
    expect(w.break_minutes_for(:full)).to eq(60)
    expect(w.break_minutes_for(:morning_half)).to eq(30)
    expect(w.break_minutes_for(:afternoon_half)).to eq(45)
  end

  it "不正 day_part は KeyError（fail-fast）" do
    expect { window.break_minutes_for(:bogus) }.to raise_error(KeyError)
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/calculators/scheduled_window_spec.rb`
Expected: FAIL（uninitialized constant ScheduledWindow）

- [ ] **Step 3: 実装**

```ruby
# WorkPattern × work_date → 組織 TZ 合成済み所定時刻群（1-2 設計 §2）。
# SPEC §5 入力契約（夜勤 +1.day・日跨ぎコア翌日換算・time 型の加算禁止）の単一実装点 —
# 合成規則をここ以外に書かないこと。
# pattern は duck: WorkPattern AR か、同名メソッドに応答する Struct（テストで DB 不要）。
# effective_* ヘルパ参照は WorkPattern のフォールバック規則（null → break/2）の単一ソース維持（0b-4）
class ScheduledWindow
  BREAK_METHODS = {
    full: :break_minutes,
    morning_half: :effective_morning_half_break_minutes,
    afternoon_half: :effective_afternoon_half_break_minutes
  }.freeze

  def self.for(pattern:, work_date:, zone:) = new(pattern, work_date, zone)

  def initialize(pattern, work_date, zone)
    @pattern = pattern
    @work_date = work_date
    @zone = zone
  end

  def start_at = at(@pattern.start_time)

  # 夜勤の日跨ぎ（night_shift かつ start > end）は翌日換算 — Time.zone 上の +1.day 合成
  def end_at
    base = at(@pattern.end_time)
    @pattern.night_shift? && @pattern.start_time > @pattern.end_time ? base + 1.day : base
  end

  def core_start_at
    return nil unless @pattern.flextime?

    at(@pattern.core_time_start)
  end

  # 日跨ぎコア（night_shift かつ core start > end）も同規則で翌日換算（SPEC §5 入力契約・R7）
  def core_end_at
    return nil unless @pattern.flextime?

    base = at(@pattern.core_time_end)
    @pattern.night_shift? && @pattern.core_time_start > @pattern.core_time_end ? base + 1.day : base
  end

  # day_part: :full | :morning_half | :afternoon_half（§4.8 の将来 status 名と整合）。
  # 不正値は fetch で即例外（fail-fast — 1-1 CalendarComponent と同方式）
  def break_minutes_for(day_part) = @pattern.public_send(BREAK_METHODS.fetch(day_part))

  private

  def at(time)
    @zone.local(@work_date.year, @work_date.month, @work_date.day, time.hour, time.min, time.sec)
  end
end
```

- [ ] **Step 4: パスを確認**

Run: `bundle exec rspec spec/calculators/scheduled_window_spec.rb`
Expected: PASS（5 examples）

- [ ] **Step 5: コミット**

```bash
git add app/calculators/scheduled_window.rb spec/calculators/scheduled_window_spec.rb
git commit -m "feat: ScheduledWindow — §5 入力契約（TZ 合成・夜勤 +1.day・日跨ぎコア）の単一実装点"
```

---

## Task 5: WorkTimeCalculator + OvertimeCalculator

**Files:**
- Create: `app/calculators/work_time_calculator.rb`・`app/calculators/overtime_calculator.rb`
- Test: `spec/calculators/work_time_calculator_spec.rb`・`spec/calculators/overtime_calculator_spec.rb`

- [ ] **Step 1: 失敗するテストを書く（WorkTime）**

```ruby
require "rails_helper"

RSpec.describe WorkTimeCalculator do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }

  # window は break_minutes_for のみ消費 — day_part が実際に渡ることを fetch で検証する stub
  def window_stub(breaks)
    Struct.new(:breaks) do
      def break_minutes_for(day_part) = breaks.fetch(day_part)
    end.new(breaks)
  end

  def call(clock_in:, clock_out:, breaks: { full: 60 }, day_part: :full)
    described_class.call(clock_in:, clock_out:, window: window_stub(breaks), day_part:)
  end

  it "標準 8h: 540 分在席 − 60 休憩 = 480" do
    expect(call(clock_in: zone.local(2026, 6, 1, 9), clock_out: zone.local(2026, 6, 1, 18))).to eq(480)
  end

  it "秒は floor: 9:00:30〜18:00:00 = 在席 539 分 → 479" do
    expect(call(clock_in: zone.local(2026, 6, 1, 9, 0, 30),
                clock_out: zone.local(2026, 6, 1, 18, 0, 0))).to eq(479)
  end

  it "在席 < 休憩は 0 に clamp" do
    expect(call(clock_in: zone.local(2026, 6, 1, 9), clock_out: zone.local(2026, 6, 1, 9, 30))).to eq(0)
  end

  it "半休は day_part の休憩を適用（morning_half = 30 分）" do
    expect(call(clock_in: zone.local(2026, 6, 1, 13), clock_out: zone.local(2026, 6, 1, 18),
                breaks: { morning_half: 30 }, day_part: :morning_half)).to eq(270)
  end

  it "夜勤跨ぎ: 22:00〜翌 7:00 − 60 = 480（打刻側に翌日換算は不要）" do
    expect(call(clock_in: zone.local(2026, 6, 1, 22), clock_out: zone.local(2026, 6, 2, 7))).to eq(480)
  end

  it "break 0 は素通り" do
    expect(call(clock_in: zone.local(2026, 6, 1, 9), clock_out: zone.local(2026, 6, 1, 18),
                breaks: { full: 0 })).to eq(480 + 60)
  end

  it "clock_in == clock_out は 0" do
    t = zone.local(2026, 6, 1, 9)
    expect(call(clock_in: t, clock_out: t)).to eq(0)
  end
end
```

- [ ] **Step 2: 失敗するテストを書く（Overtime）**

```ruby
require "rails_helper"

RSpec.describe OvertimeCalculator do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }
  let(:end_at_1800) { zone.local(2026, 6, 1, 18) }

  def window_stub(end_at)
    Struct.new(:end_at).new(end_at)
  end

  def call(actual:, clock_out:, end_at: end_at_1800)
    described_class.call(actual_work_minutes: actual, clock_out:, window: window_stub(end_at))
  end

  it "legal 境界 3 点: 479/480/481 分 → 0/0/1（労基法 32 条 2 項・480 分固定）" do
    out = zone.local(2026, 6, 1, 18)
    expect(call(actual: 479, clock_out: out).legal_overtime_minutes).to eq(0)
    expect(call(actual: 480, clock_out: out).legal_overtime_minutes).to eq(0)
    expect(call(actual: 481, clock_out: out).legal_overtime_minutes).to eq(1)
  end

  it "legal は window（所定）に依存しない — 同じ actual なら end_at が違っても同値（半休 480 不変の根拠）" do
    out = zone.local(2026, 6, 1, 18)
    early_end = window_stub(zone.local(2026, 6, 1, 13))
    expect(described_class.call(actual_work_minutes: 481, clock_out: out, window: early_end)
             .legal_overtime_minutes).to eq(1)
  end

  it "scheduled 等値・秒境界 3 点: 18:00:00 → 0・18:00:01 → 0（floor）・18:01:00 → 1" do
    expect(call(actual: 0, clock_out: zone.local(2026, 6, 1, 18, 0, 0)).scheduled_overtime_minutes).to eq(0)
    expect(call(actual: 0, clock_out: zone.local(2026, 6, 1, 18, 0, 1)).scheduled_overtime_minutes).to eq(0)
    expect(call(actual: 0, clock_out: zone.local(2026, 6, 1, 18, 1, 0)).scheduled_overtime_minutes).to eq(1)
  end

  it "早帰りの scheduled は max(0)" do
    expect(call(actual: 0, clock_out: zone.local(2026, 6, 1, 17)).scheduled_overtime_minutes).to eq(0)
  end

  it "夜勤は +1.day 換算済み end_at 基準: 翌日 7:30 退勤（end 翌日 7:00）→ 30 分" do
    night_end = zone.local(2026, 6, 2, 7)
    expect(call(actual: 0, clock_out: zone.local(2026, 6, 2, 7, 30), end_at: night_end)
             .scheduled_overtime_minutes).to eq(30)
  end
end
```

- [ ] **Step 3: 失敗を確認**

Run: `bundle exec rspec spec/calculators/work_time_calculator_spec.rb spec/calculators/overtime_calculator_spec.rb`
Expected: FAIL（uninitialized constant × 2）

- [ ] **Step 4: 実装（WorkTime）**

```ruby
# 実労働時間（SPEC §5.1・1-2 設計 §3.1）: 退勤 − 出勤 − 休憩。整数分を返す純粋関数。
# 夜勤の翌日換算は打刻側には不要（clock_in/clock_out は実時刻 — 差分が自然に正）
class WorkTimeCalculator
  def self.call(clock_in:, clock_out:, window:, day_part:)
    presence = MinuteConversion.minutes_between(clock_in, clock_out)
    [presence - window.break_minutes_for(day_part), 0].max
  end
end
```

- [ ] **Step 5: 実装（Overtime）**

```ruby
# 残業 2 系統（SPEC §5.2 補正後・1-2 設計 §3.2）。整数分の Data を返す純粋関数。
# - legal: 実労働 8h 超のみ（所定に依存しない — 半休でも閾値不変）。所定超過の表示は scheduled が担う
# - scheduled: 時刻基準（退勤 − 所定終業）。半休・フレックスでも同式 — 所定終業の定義は end_at が唯一
class OvertimeCalculator
  Result = Data.define(:legal_overtime_minutes, :scheduled_overtime_minutes)

  # 労基法 32 条 2 項「休憩時間を除き一日について八時間」— 法定値・テナント改変不可（SPEC §8 原則）。
  # 出典: https://laws.e-gov.go.jp/law/322AC0000000049（原典照合 2026-06-13）
  LEGAL_DAILY_MINUTES = 480

  def self.call(actual_work_minutes:, clock_out:, window:)
    Result.new(
      legal_overtime_minutes: [actual_work_minutes - LEGAL_DAILY_MINUTES, 0].max,
      scheduled_overtime_minutes:
        [MinuteConversion.minutes_between(window.end_at, clock_out), 0].max
    )
  end
end
```

- [ ] **Step 6: パスを確認**

Run: `bundle exec rspec spec/calculators/work_time_calculator_spec.rb spec/calculators/overtime_calculator_spec.rb`
Expected: PASS（7 + 5 examples）

- [ ] **Step 7: コミット**

```bash
git add app/calculators/work_time_calculator.rb app/calculators/overtime_calculator.rb spec/calculators/work_time_calculator_spec.rb spec/calculators/overtime_calculator_spec.rb
git commit -m "feat: WorkTime / Overtime calculator（実労働・法定 480 分固定 + 所定外の 2 系統）"
```

---

## Task 6: DeepNightCalculator

**Files:**
- Create: `app/calculators/deep_night_calculator.rb`
- Test: `spec/calculators/deep_night_calculator_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "rails_helper"

RSpec.describe DeepNightCalculator do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }
  let(:work_date) { Date.new(2026, 6, 1) }

  def call(clock_in:, clock_out:, break_minutes: 0)
    described_class.call(clock_in:, clock_out:, break_minutes:, work_date:, zone:)
  end

  describe "22:00 側境界（含まない開始点・SPEC §5.3）" do
    let(:clock_in) { zone.local(2026, 6, 1, 13) }

    it "22:00:00 ちょうど退勤 = 0（重複 0 秒）" do
      expect(call(clock_in:, clock_out: zone.local(2026, 6, 1, 22, 0, 0))).to eq(0)
    end

    it "22:00:01 退勤 = 0（重複 1 秒 → floor）" do
      expect(call(clock_in:, clock_out: zone.local(2026, 6, 1, 22, 0, 1))).to eq(0)
    end

    it "22:01:00 退勤 = 1 分" do
      expect(call(clock_in:, clock_out: zone.local(2026, 6, 1, 22, 1, 0))).to eq(1)
    end
  end

  describe "5:00 側境界（出勤側・対称）" do
    let(:clock_out) { zone.local(2026, 6, 1, 14) }

    it "5:00:00 ちょうど出勤 = 0" do
      expect(call(clock_in: zone.local(2026, 6, 1, 5, 0, 0), clock_out:)).to eq(0)
    end

    it "4:59:59 出勤 = 0（1 秒 → floor）" do
      expect(call(clock_in: zone.local(2026, 6, 1, 4, 59, 59), clock_out:)).to eq(0)
    end

    it "4:59:00 出勤 = 1 分" do
      expect(call(clock_in: zone.local(2026, 6, 1, 4, 59, 0), clock_out:)).to eq(1)
    end
  end

  it "早朝シフトは前日窓 [D−1 22:00, D 5:00] を捕捉する（4:00 出勤 → 60 分・§5.3 隣接 2 窓の消費）" do
    expect(call(clock_in: zone.local(2026, 6, 1, 4), clock_out: zone.local(2026, 6, 1, 13))).to eq(60)
  end

  it "夜勤通し 22:00〜翌 5:00（break 0）= 420 分" do
    expect(call(clock_in: zone.local(2026, 6, 1, 22), clock_out: zone.local(2026, 6, 2, 5))).to eq(420)
  end

  it "2 窓同時寄与 + 按分: 03:00〜23:30・break 60 → overlap 210・按分 floor(60×210/1230)=10 → 200 分" do
    expect(call(clock_in: zone.local(2026, 6, 1, 3), clock_out: zone.local(2026, 6, 1, 23, 30),
                break_minutes: 60)).to eq(200)
  end

  it "按分 FLOOR 判別値: 20:00〜翌 5:00・break 60 → 60×420/540 = 46.67 → 46（HALF_UP なら 47）→ 374 分" do
    expect(call(clock_in: zone.local(2026, 6, 1, 20), clock_out: zone.local(2026, 6, 2, 5),
                break_minutes: 60)).to eq(374)
  end

  it "秒は 2 窓合算後に 1 回だけ floor（R1）: 各窓 30 秒ずつ → 合算 60 秒 = 1 分（窓ごと floor なら 0）" do
    expect(call(clock_in: zone.local(2026, 6, 1, 4, 59, 30),
                clock_out: zone.local(2026, 6, 1, 22, 0, 30))).to eq(1)
  end

  it "presence 0（in == out）は 0 ガード" do
    t = zone.local(2026, 6, 1, 23)
    expect(call(clock_in: t, clock_out: t)).to eq(0)
  end

  it "第 3 窓は数えない（定義域 pin）: D 4:00 〜 D+1 23:00 → 前日窓 60 + 当日窓 420 = 480 分" do
    expect(call(clock_in: zone.local(2026, 6, 1, 4), clock_out: zone.local(2026, 6, 2, 23))).to eq(480)
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/calculators/deep_night_calculator_spec.rb`
Expected: FAIL（uninitialized constant DeepNightCalculator）

- [ ] **Step 3: 実装**

```ruby
# 深夜労働（SPEC §5.3・1-2 設計 §3.3）: 隣接 2 窓との重複 − 休憩按分。整数分を返す純粋関数。
# 深夜帯は法定帯でパターン非依存 — フレックス・夜勤・mode_conflict すべてロジック同一（免除なし）。
# 労基法 37 条 4 項「午後十時から午前五時まで」— 法定値・テナント改変不可。
# 出典: https://laws.e-gov.go.jp/law/322AC0000000049（原典照合 2026-06-13）
class DeepNightCalculator
  NIGHT_START_HOUR = 22
  NIGHT_END_HOUR = 5

  # 定義域: clock_out < D+1 22:00 を前提（第 3 窓は数えない）。ClockOut の window 探索（前日まで）と
  # 4-2 打刻漏れバッチが上流で抑止する（1-2 設計 §3.3 — spec で現挙動を pin 済み）
  def self.call(clock_in:, clock_out:, break_minutes:, work_date:, zone:)
    overlap_seconds = windows(work_date, zone).sum do |from, to|
      [[clock_out, to].min - [clock_in, from].max, 0].max
    end
    overlap_minutes = (overlap_seconds / 60).floor # 2 窓の秒を合算してから 1 回だけ floor（R1）
    presence_minutes = MinuteConversion.minutes_between(clock_in, clock_out)
    return 0 if overlap_minutes.zero? || presence_minutes.zero?

    # 休憩按分（SPEC §5.3 Step 2）: FLOOR = 控除を小さく = 労働者有利。
    # presence は gross 在席分（休憩込み）— 整数除算が床関数を兼ねる
    deep_night_break = break_minutes * overlap_minutes / presence_minutes
    [overlap_minutes - deep_night_break, 0].max
  end

  # 出勤日 D 基準の隣接 2 窓: [D−1 22:00, D 5:00] と [D 22:00, D+1 5:00]（SPEC §5.3 Step 1 —
  # 単窓では早朝シフトの D 0:00〜5:00 帯を取りこぼす・1-1 設計レビュー補正）
  def self.windows(work_date, zone)
    [
      [boundary(work_date - 1, zone, NIGHT_START_HOUR), boundary(work_date, zone, NIGHT_END_HOUR)],
      [boundary(work_date, zone, NIGHT_START_HOUR), boundary(work_date + 1, zone, NIGHT_END_HOUR)]
    ]
  end
  private_class_method :windows

  def self.boundary(date, zone, hour) = zone.local(date.year, date.month, date.day, hour)
  private_class_method :boundary
end
```

- [ ] **Step 4: パスを確認**

Run: `bundle exec rspec spec/calculators/deep_night_calculator_spec.rb`
Expected: PASS（12 examples）

- [ ] **Step 5: コミット**

```bash
git add app/calculators/deep_night_calculator.rb spec/calculators/deep_night_calculator_spec.rb
git commit -m "feat: DeepNightCalculator — 隣接 2 窓 + 秒合算 1 回 floor + 按分 FLOOR"
```

---

## Task 7: LateEarlyCalculator

**Files:**
- Create: `app/calculators/late_early_calculator.rb`
- Test: `spec/calculators/late_early_calculator_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "rails_helper"

RSpec.describe LateEarlyCalculator do
  let(:zone) { ActiveSupport::TimeZone["Asia/Tokyo"] }
  let(:window_class) { Struct.new(:start_at, :end_at, :core_start_at, :core_end_at, keyword_init: true) }
  let(:fixed_window) do
    window_class.new(start_at: zone.local(2026, 6, 1, 9), end_at: zone.local(2026, 6, 1, 18),
                     core_start_at: nil, core_end_at: nil)
  end
  let(:flex_window) do
    window_class.new(start_at: zone.local(2026, 6, 1, 9), end_at: zone.local(2026, 6, 1, 18),
                     core_start_at: zone.local(2026, 6, 1, 10), core_end_at: zone.local(2026, 6, 1, 15))
  end

  def call(clock_in:, clock_out:, window: fixed_window, flextime: false, day_part: :full)
    described_class.call(clock_in:, clock_out:, window:, flextime:, day_part:)
  end

  describe "固定時間制" do
    it "等値は遅刻・早退でない（負例 — > と >= の mutation を殺す）" do
      r = call(clock_in: zone.local(2026, 6, 1, 9, 0, 0), clock_out: zone.local(2026, 6, 1, 18, 0, 0))
      expect(r.is_late).to be(false)
      expect(r.is_early_leave).to be(false)
      expect(r.late_minutes).to eq(0)
      expect(r.early_leave_minutes).to eq(0)
    end

    it "1 分未満の遅刻は is_late=true + late_minutes=0（判定は秒厳密・分数は floor）" do
      r = call(clock_in: zone.local(2026, 6, 1, 9, 0, 30), clock_out: zone.local(2026, 6, 1, 18))
      expect(r.is_late).to be(true)
      expect(r.late_minutes).to eq(0)
    end

    it "遅刻と早退は同時成立する（in 10:00 / out 17:00 → 各 60 分）" do
      r = call(clock_in: zone.local(2026, 6, 1, 10), clock_out: zone.local(2026, 6, 1, 17))
      expect(r).to eq(described_class::Result.new(
        is_late: true, late_minutes: 60, is_early_leave: true, early_leave_minutes: 60))
    end

    it "夜勤の日跨ぎ退勤は早退でない（end_at は +1.day 換算済み前提）" do
      night = window_class.new(start_at: zone.local(2026, 6, 1, 22), end_at: zone.local(2026, 6, 2, 7),
                               core_start_at: nil, core_end_at: nil)
      r = call(clock_in: zone.local(2026, 6, 1, 22), clock_out: zone.local(2026, 6, 2, 7), window: night)
      expect(r.is_early_leave).to be(false)
    end
  end

  describe "フレックス（コア基準・分数 0 固定）" do
    it "コア開始後の出勤は遅刻（true・0 分）・等値は false" do
      late = call(clock_in: zone.local(2026, 6, 1, 10, 0, 1), clock_out: zone.local(2026, 6, 1, 16),
                  window: flex_window, flextime: true)
      expect(late.is_late).to be(true)
      expect(late.late_minutes).to eq(0) # §5.4 二値管理

      on_time = call(clock_in: zone.local(2026, 6, 1, 10, 0, 0), clock_out: zone.local(2026, 6, 1, 16),
                     window: flex_window, flextime: true)
      expect(on_time.is_late).to be(false)
    end

    it "コア終了前の退勤は早退（true・0 分）" do
      r = call(clock_in: zone.local(2026, 6, 1, 9), clock_out: zone.local(2026, 6, 1, 14, 59),
               window: flex_window, flextime: true)
      expect(r.is_early_leave).to be(true)
      expect(r.early_leave_minutes).to eq(0)
    end
  end

  describe "半休の片側免除（両制度共通・SPEC §5.4）" do
    it "morning_half は遅刻免除・早退のみ判定" do
      r = call(clock_in: zone.local(2026, 6, 1, 13), clock_out: zone.local(2026, 6, 1, 17),
               day_part: :morning_half)
      expect(r.is_late).to be(false)
      expect(r.late_minutes).to eq(0)
      expect(r.is_early_leave).to be(true)
      expect(r.early_leave_minutes).to eq(60)
    end

    it "afternoon_half は早退免除・遅刻のみ判定" do
      r = call(clock_in: zone.local(2026, 6, 1, 9, 30), clock_out: zone.local(2026, 6, 1, 13),
               day_part: :afternoon_half)
      expect(r.is_late).to be(true)
      expect(r.late_minutes).to eq(30)
      expect(r.is_early_leave).to be(false)
    end

    it "半休 × フレックス複合: morning_half は遅刻 skip + コア終了基準の早退のみ（0 分固定）" do
      r = call(clock_in: zone.local(2026, 6, 1, 11), clock_out: zone.local(2026, 6, 1, 14),
               window: flex_window, flextime: true, day_part: :morning_half)
      expect(r.is_late).to be(false)
      expect(r.is_early_leave).to be(true)
      expect(r.early_leave_minutes).to eq(0)
    end
  end

  it "mode_conflict は flex のコア判定が優先（日跨ぎコアは window 側で換算済み）" do
    night_flex = window_class.new(
      start_at: zone.local(2026, 6, 1, 22), end_at: zone.local(2026, 6, 2, 7),
      core_start_at: zone.local(2026, 6, 1, 23), core_end_at: zone.local(2026, 6, 2, 3))
    r = call(clock_in: zone.local(2026, 6, 1, 22, 30), clock_out: zone.local(2026, 6, 2, 2),
             window: night_flex, flextime: true)
    expect(r.is_late).to be(false)        # コア開始 23:00 前に在席
    expect(r.is_early_leave).to be(true)  # コア終了翌 3:00 前に退勤
  end

  it "不正 day_part は ArgumentError（fail-fast）" do
    expect {
      call(clock_in: zone.local(2026, 6, 1, 9), clock_out: zone.local(2026, 6, 1, 18), day_part: :bogus)
    }.to raise_error(ArgumentError, /day_part/)
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/calculators/late_early_calculator_spec.rb`
Expected: FAIL（uninitialized constant LateEarlyCalculator）

- [ ] **Step 3: 実装**

```ruby
# 遅刻・早退判定（SPEC §5.4・1-2 設計 §3.4）。Data を返す純粋関数。
# 固定時間制 = start_at/end_at 基準（秒厳密・分数 floor）。
# フレックス = コア基準の二値・分数 0 固定。mode_conflict は flex 判定が優先（1-2 設計 §0-2 —
# WorkTime/Overtime が読む night_shift 換算とは別カラムゆえ矛盾なく共存）。
# 半休の片側免除: morning_half = 遅刻免除 / afternoon_half = 早退免除（両制度共通）
class LateEarlyCalculator
  Result = Data.define(:is_late, :late_minutes, :is_early_leave, :early_leave_minutes)

  DAY_PARTS = %i[full morning_half afternoon_half].freeze

  def self.call(clock_in:, clock_out:, window:, flextime:, day_part:)
    raise ArgumentError, "unknown day_part: #{day_part.inspect}" unless DAY_PARTS.include?(day_part)

    late_threshold  = flextime ? window.core_start_at : window.start_at
    early_threshold = flextime ? window.core_end_at : window.end_at

    is_late = day_part != :morning_half && clock_in > late_threshold
    is_early_leave = day_part != :afternoon_half && clock_out < early_threshold

    Result.new(
      is_late:,
      late_minutes:
        is_late && !flextime ? MinuteConversion.minutes_between(late_threshold, clock_in) : 0,
      is_early_leave:,
      early_leave_minutes:
        is_early_leave && !flextime ? MinuteConversion.minutes_between(clock_out, early_threshold) : 0
    )
  end
end
```

- [ ] **Step 4: パスを確認**

Run: `bundle exec rspec spec/calculators/late_early_calculator_spec.rb`
Expected: PASS（11 examples）

- [ ] **Step 5: コミット**

```bash
git add app/calculators/late_early_calculator.rb spec/calculators/late_early_calculator_spec.rb
git commit -m "feat: LateEarlyCalculator — 固定/フレックス/半休免除/mode_conflict 役割分担"
```

---

## Task 8: Clockings::Recalculate（書き戻し唯一経路）

**Files:**
- Create: `app/services/clockings/recalculate.rb`
- Test: `spec/services/clockings/recalculate_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "rails_helper"

# 時刻リテラルは UTC・JST コメント併記（org 既定 TZ = Asia/Tokyo）
RSpec.describe Clockings::Recalculate do
  let(:org) { create(:organization) }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  def night_pattern
    ActsAsTenant.with_tenant(org) do
      create(:work_pattern, start_time: "22:00", end_time: "07:00", night_shift: true,
                            break_minutes: 60, standard_work_hours: 8)
    end
  end

  def create_record(pattern:, clock_in:, clock_out:)
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in:, clock_out:, status: :clocked_out, work_pattern: pattern)
    end
  end

  it "夜勤の 8 列を保存する（総合・HALF_UP 発火含む）" do
    record = create_record(pattern: night_pattern,
                           clock_in: Time.utc(2026, 6, 1, 13),       # JST 22:00
                           clock_out: Time.utc(2026, 6, 1, 22, 30))  # JST 翌 7:30
    described_class.call(record:)
    record.reload
    expect(record.actual_work_hours).to eq(8.5)            # 570 − 60 = 510 分
    expect(record.legal_overtime_hours).to eq(0.5)         # 510 − 480 = 30 分
    expect(record.scheduled_overtime_hours).to eq(0.5)     # 翌 7:00 終業 → 30 分
    expect(record.deep_night_hours).to eq(6.27)            # 376 分 — HALF_UP 発火（truncate なら 6.26）
    expect(record.is_late).to be(false)
    expect(record.late_minutes).to eq(0)
    expect(record.is_early_leave).to be(false)
    expect(record.early_leave_minutes).to eq(0)
  end

  it "未割当（work_pattern nil）は全列 NULL のまま skip" do
    record = create_record(pattern: nil,
                           clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 9))
    described_class.call(record:)
    record.reload
    expect(record.actual_work_hours).to be_nil
    expect(record.is_late).to be_nil
  end

  it "stale 残置 pin: 計算済みレコードのパターンが外れた後の再計算は値を変えない（2-2 で再訪）" do
    record = create_record(pattern: night_pattern,
                           clock_in: Time.utc(2026, 6, 1, 13), clock_out: Time.utc(2026, 6, 1, 22, 30))
    described_class.call(record:)
    record.update_column(:work_pattern_id, nil)
    described_class.call(record:)
    expect(record.reload.actual_work_hours).to eq(8.5)
  end

  it "呼び出し側の with_tenant に依存せず成功する（自己完結 — console/将来ジョブの単体呼び出し想定）" do
    record = create_record(pattern: night_pattern,
                           clock_in: Time.utc(2026, 6, 1, 13), clock_out: Time.utc(2026, 6, 1, 22, 30))
    # with_tenant ブロックの外（= この example の素の文脈）から直接呼ぶ
    expect { described_class.call(record:) }.not_to raise_error
    expect(record.reload.actual_work_hours).to eq(8.5)
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/clockings/recalculate_spec.rb`
Expected: FAIL（uninitialized constant Clockings::Recalculate）

- [ ] **Step 3: 実装**

```ruby
module Clockings
  # 計算 8 列の書き戻し唯一経路（1-2 設計 §4）。退勤打刻のほか 2-2/2-3 打刻変更承認・
  # Phase 2 休暇承認の再計算もこの入口に合流する（SPEC §4.8）。
  # 例外は投げ得る — rescue は呼び出し側の責務（ClockOut は打刻保全 + Rails.error.report・R4）。
  # 未割当（pattern nil）は何もしない: 全列 NULL = 未計算の意味論（brainstorm 決定 3）。
  # 計算済みレコードのパターンが外れた場合も残置（クリアしない — 2-2 の再計算設計で再訪）
  class Recalculate
    def self.call(record:) = new(record).call

    def initialize(record)
      @record = record
    end

    def call
      ActsAsTenant.with_tenant(@record.organization) do
        pattern = @record.work_pattern
        next @record if pattern.nil?

        zone = ActiveSupport::TimeZone[@record.organization.time_zone]
        window = ScheduledWindow.for(pattern:, work_date: @record.work_date, zone:)
        clock_in = @record.clock_in.in_time_zone(zone)   # §5 入力契約: 組織 TZ 変換済みを渡す
        clock_out = @record.clock_out.in_time_zone(zone)
        day_part = :full # Phase 2 で status（morning_half 等）から導出

        actual = WorkTimeCalculator.call(clock_in:, clock_out:, window:, day_part:)
        overtime = OvertimeCalculator.call(actual_work_minutes: actual, clock_out:, window:)
        # break は day_part 解決済みの値を渡す — 実際に控除した休憩と按分母体を一致させる
        deep_night = DeepNightCalculator.call(
          clock_in:, clock_out:, break_minutes: window.break_minutes_for(day_part),
          work_date: @record.work_date, zone:)
        late_early = LateEarlyCalculator.call(
          clock_in:, clock_out:, window:, flextime: pattern.flextime?, day_part:)

        @record.update!(
          actual_work_hours: MinuteConversion.to_hours(actual),
          legal_overtime_hours: MinuteConversion.to_hours(overtime.legal_overtime_minutes),
          scheduled_overtime_hours: MinuteConversion.to_hours(overtime.scheduled_overtime_minutes),
          deep_night_hours: MinuteConversion.to_hours(deep_night),
          is_late: late_early.is_late,
          late_minutes: late_early.late_minutes,
          is_early_leave: late_early.is_early_leave,
          early_leave_minutes: late_early.early_leave_minutes
        )
        @record
      end
    end
  end
end
```

- [ ] **Step 4: パスを確認**

Run: `bundle exec rspec spec/services/clockings/recalculate_spec.rb`
Expected: PASS（4 examples）

- [ ] **Step 5: コミット**

```bash
git add app/services/clockings/recalculate.rb spec/services/clockings/recalculate_spec.rb
git commit -m "feat: Clockings::Recalculate — 計算 8 列の書き戻し唯一経路"
```

---

## Task 9: ClockIn/ClockOut 統合（usec 切り詰め + rescue 報告）

**Files:**
- Modify: `app/services/clockings/clock_in.rb`（`clock_in: Time.current` → 秒切り詰め）
- Modify: `app/services/clockings/clock_out.rb`（秒切り詰め + Recalculate 呼び出し + rescue）
- Test: `spec/services/clockings/clock_out_spec.rb`（example 追加 + 既存 race テスト拡張）

- [ ] **Step 1: 失敗するテストを書く** — clock_out_spec.rb 末尾に追記:

```ruby
  describe "計算列の保存（1-2 統合）" do
    it "退勤で 8 列が埋まる（日勤 9:00–18:00・JST 18:30 退勤）" do
      pattern = create(:work_pattern) # 9:00–18:00・break 60
      record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                      clock_in: Time.utc(2026, 6, 1, 0), work_pattern: pattern) # JST 9:00
      travel_to Time.utc(2026, 6, 1, 9, 30) do # JST 18:30
        described_class.call(user:)

        record.reload
        expect(record.actual_work_hours).to eq(8.5)        # 570 − 60 = 510 分
        expect(record.legal_overtime_hours).to eq(0.5)     # 510 − 480
        expect(record.scheduled_overtime_hours).to eq(0.5) # 18:30 − 18:00
        expect(record.deep_night_hours).to eq(0)
        expect(record.is_late).to be(false)
        expect(record.is_early_leave).to be(false)
      end
    end

    it "夜勤跨ぎは deep_night_hours まで埋まる（22:00–翌 7:00・按分 46 分控除）" do
      pattern = create(:work_pattern, start_time: "22:00", end_time: "07:00",
                       night_shift: true, break_minutes: 60, standard_work_hours: 8)
      record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                      clock_in: Time.utc(2026, 6, 1, 13), work_pattern: pattern) # JST 22:00
      travel_to Time.utc(2026, 6, 1, 22) do # JST 翌 7:00
        described_class.call(user:)

        # assert は travel_to 内（RAILS_GOTCHAS: timeoutable がセッションを切る罠と同型の時刻依存）
        record.reload
        expect(record.actual_work_hours).to eq(8.0)     # 540 − 60
        expect(record.deep_night_hours).to eq(6.23)     # overlap 420 − floor(60×420/540)=46 → 374 分
        expect(record.is_early_leave).to be(false)      # 終業ちょうど
      end
    end

    it "未割当は退勤成功 + 全列 NULL のまま" do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 0)) # work_pattern なし
      travel_to Time.utc(2026, 6, 1, 9) do
        result = described_class.call(user:)
        expect(result).to be_success
        expect(result.record.actual_work_hours).to be_nil
      end
    end

    it "Recalculate の例外でも退勤は保全される（R4: rescue + Rails.error.report・8 列 NULL）" do
      record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                      clock_in: Time.utc(2026, 6, 1, 0), work_pattern: create(:work_pattern))
      allow(Clockings::Recalculate).to receive(:call).and_raise(RuntimeError, "calc bug")
      expect(Rails.error).to receive(:report) # kwargs まで縛らない（matcher の kwargs 互換罠を避ける）

      travel_to Time.utc(2026, 6, 1, 9) do
        result = described_class.call(user:)
        expect(result).to be_success
        expect(record.reload).to be_clocked_out
        expect(record.actual_work_hours).to be_nil
      end
    end

    it "打刻はサブ秒を持たない（usec 切り詰め — 9:00:00 ちょうど打刻の偽遅刻防止）" do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 0))
      # travel_to は既定で usec を 0 に切り詰めるため with_usec: true で本物のサブ秒を再現する
      travel_to Time.utc(2026, 6, 1, 9, 0, 0, 123_456), with_usec: true do
        result = described_class.call(user:)
        expect(result.record.clock_out.usec).to eq(0)
      end
    end
  end
```

既存の race テスト（「ロック取得待ちの間に…」）を 2 箇所変更 — record の create に `work_pattern: create(:work_pattern)` を追加（パターン無しだと NULL が自明に成立し assert が無意味）し、末尾 assert に 1 行追加:

```ruby
      expect(record.reload.actual_work_hours).to be_nil # 敗者経路では計算しない
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/clockings/clock_out_spec.rb`
Expected: 新 5 example FAIL（計算列が埋まらない / usec 非ゼロ）。既存は PASS のまま

- [ ] **Step 3: ClockOut を修正** — `call` 内の `record.update!` 行とその直後を以下へ:

```ruby
          if record.working?
            # usec 切り詰め: PG timestamptz はマイクロ秒精度 — サブ秒を残すと「ちょうど打刻」が
            # 偽遅刻になる（1-2 設計 R2。MinuteConversion の floor 安全性の前提でもある）
            record.update!(clock_out: Time.current.change(usec: 0), status: :clocked_out)
            recalculate(record)
            Result.new(success: true, record:, error: nil)
          else
```

private に追加:

```ruby
    # 計算は全域関数ゆえ例外 = 実装バグだが、退勤打刻は保全する（1-2 設計 §4 R4 — 打刻ブロック禁止）。
    # 8 列は NULL のまま（= 未計算）。検知は error report（Sentry 連携は Phase 5）→ 恒久は 4-2 バッチ
    def recalculate(record)
      Clockings::Recalculate.call(record:)
    rescue StandardError => e
      Rails.error.report(e, context: { attendance_record_id: record.id }, source: "clockings")
    end
```

- [ ] **Step 4: ClockIn を修正** — `clock_in: Time.current,` を:

```ruby
          clock_in: Time.current.change(usec: 0), # サブ秒切り詰め（1-2 設計 R2 — ClockOut と対）
```

- [ ] **Step 5: パスを確認（全 suite — 既存の `eq(Time.current)` assert が travel_to の usec 0 時刻で成立し続けることを含む）**

Run: `bundle exec rspec`
Expected: PASS（全緑）

- [ ] **Step 6: コミット**

```bash
git add app/services/clockings/clock_in.rb app/services/clockings/clock_out.rb spec/services/clockings/clock_out_spec.rb
git commit -m "feat: ClockOut → Recalculate 統合（打刻保全 + rescue 報告）・打刻の usec 切り詰め"
```

---

## Task 10: docs 逆反映（設計 §7 全件）

**Files:**
- Modify: `docs/SPEC.md`・`docs/ROADMAP.md`・`docs/LABOR_LAW_REVIEW_NOTES.md`・`app/models/work_pattern.rb`（コメント 1 行）

- [ ] **Step 1: SPEC §5.2** — 式ブロックの `法定残業 (legal_overtime_hours)     = max(0, 実労働時間 − 所定労働時間)` を:

```
法定残業 (legal_overtime_hours)     = max(0, 実労働時間 − 8h)   # 労基法 32 条 2 項「休憩時間を除き一日について八時間」
```

へ変更し、式ブロック直後に追記:

```markdown
> **8h は法定値固定**（480 分・テナント設定で改変不可・§8 原則）。所定基準の超過は scheduled 系統が担う。
> 旧式「実労働 − 所定」は §0.3 用語集・本節週 40h 注記（1 日 8h 超）と矛盾していたため補正
> （出典: <https://laws.e-gov.go.jp/law/322AC0000000049>・原典照合 2026-06-13・1-2 設計）。
```

- [ ] **Step 2: SPEC §0.3 用語集（44 行付近）** — 「法定残業 = 実労働 − 所定（8h 超・…」を「法定残業 = 実労働 − 8h（割増とコンプラ判定の基準）。所定外残業 = 退勤 − 所定終業（表示用に併存）」へ。**§4.8 列説明（386 行付近）** — `legal_overtime_hours | decimal(6,2) | 法定残業（実労働−所定。負は 0）` を `法定残業（実労働 − 8h。負は 0）` へ。`grep -n '実労働.*所定' docs/SPEC.md` で残存ゼロを確認

- [ ] **Step 3: SPEC §5 前文（606〜608 行）** — 入力契約の段落末尾に追記:

```markdown
> **秒の扱い（1-2 設計）:** 打刻は秒精度で保存（書き込み時に usec 切り詰め）。分換算は「差分秒 ÷ 60 の
> 整数除算（floor）」で統一。深夜 2 窓の重複は**秒で合算してから 1 回だけ floor**（窓ごと floor は
> 労働者不利の追加切り捨てを生むため不可）。日次 floor の端数処理は社労士確認中（NOTES #16）。
```

- [ ] **Step 4: SPEC §5.3** — Step 2 の `total_work_minutes` 行へ「（= 退勤 − 出勤の gross 在席分・休憩込み）」を追記

- [ ] **Step 5: SPEC §4.4（332 行付近）** — mode_conflict の段落（「同時指定は保存許可」近傍）へ追記: 「**優先ルール（1-2 確定）:** WorkTime/Overtime は night_shift の翌日換算・LateEarly は flextime のコアタイム判定を適用（別カラムを読むため矛盾なく共存）」。同時に `app/models/work_pattern.rb:38` のコメントを:

```ruby
  # 同時指定は保存許可・画面で警告バッジ（SPEC §4.4）。優先ルールは 1-2 で確定:
  # WorkTime/Overtime = night_shift 換算・LateEarly = flextime コア判定（役割分担で共存）
```

- [ ] **Step 6: SPEC §4.8** — 計算列の注記（398 行付近 `> **計算列の方針:**`）へ追記: 「8 列は NULL = 未計算（Recalculate が一括書き込み — 一括 NULL / 一括非 NULL が不変条件）。未計算の除外は `calculated` スコープ経由のみ」。**SPEC §2.3（120〜125 行）** — calculators の一覧へ `scheduled_window.rb`（入力合成）・`minute_conversion.rb`（丸め単一ソース）を追加

- [ ] **Step 7: NOTES #16 新規** — `docs/LABOR_LAW_REVIEW_NOTES.md` の確認事項テーブル末尾へ:

```markdown
| 16 | 日次の秒切り捨て（§5 前文・1-2） | 打刻秒→分換算を floor（切り捨て）で統一（最大 59 秒/日 + 深夜按分 floor）。労働者不利方向の端数処理 | 昭 63.3.14 基発 150 号とされる端数処理通達は MHLW DB で**原典取得不能・未照合**（後継解釈例規 平 21.10.5 基発 1005 第 1 号に端数処理の定めなし）。月単位丸め容認とされる通説の真偽含め原典確認が必要 | 日次 floor の適法性。打刻時刻の分単位切り詰め運用（秒を持たない他社製品）との比較。賃金計算上の丸めとの責任分界（本システムは時間集計のみ） |
```

- [ ] **Step 8: ROADMAP** — 1-2 行を `- [x]` + `（PR #xx）` 化（PR 番号は PR 作成後に確定）。行 84 の `app/services/calculations` を `app/calculators` へ修正

- [ ] **Step 9: 全 suite + コミット**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: PASS / no offenses

```bash
git add docs/SPEC.md docs/ROADMAP.md docs/LABOR_LAW_REVIEW_NOTES.md app/models/work_pattern.rb
git commit -m "docs: 1-2 逆反映 — §5.2 法定残業 8h 補正・秒規則・mode_conflict 確定・NOTES #16"
```

---

## 完了チェック（PR 前）

- [ ] `/preflight`（rubocop は `--force-exclusion`・app/ 変更ありゆえ brakeman 含む）
- [ ] `/legal-citation-audit` の照合結果（32 条 2 項・37 条 4 項 — 設計レビューで照合済み）を PR 本文に記録
- [ ] RAILS_GOTCHAS — 実装中に新しい罠を踏んだら同 PR で追記
- [ ] PR 本文: 設計書リンク・R1〜R11 の要約・NOTES #16 新設の旨
