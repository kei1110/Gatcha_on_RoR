# Phase 1-1 AttendanceRecord + 打刻 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 社員がブラウザの出勤/退勤ボタンで打刻でき、パターンスナップショット・二重打刻防止・社員ホーム（ヘッダー + 当月カレンダー）が動く。

**Architecture:** AttendanceRecord（消費分のみ 6 カラム・unique [user_id, work_date]・複合 FK）+ Clockings::{ClockIn, ClockOut, State}（述語は `AttendanceRecord.working_within` に単一化）+ headless ClockingPolicy + redirect(303) ベースの UI。設計: docs/superpowers/specs/2026-06-12-phase1-1-attendance-clocking-design.md

**Tech Stack:** Rails 8.1 / PostgreSQL 17 / acts_as_tenant / Pundit / ViewComponent / RSpec + FactoryBot

---

## 折衷案 v2 実行ノート（コントローラ向け・タスク本文ではない）

- **モデル割当**: Task 2・5・6・7 = sonnet ／ **Task 3・4・8 = haiku 試験**（計画が全コードを持つ転写型 — 逸脱が出たら即 sonnet へ戻し、実測を記録）／ Task 1 = sonnet（schema dump 確認という判断が混じる）
- **スペック準拠レビュー**: 全タスク主エージェントが git diff 直接突合
- **品質レビュー（独立サブエージェント・実挙動検証義務の定型句必須)**: Task 1 単独（スキーマ = 心臓部）／ **Task 2+3+4 バッチ**／ Task 5 単独（認可）／ **Task 6+7 バッチ**／ Task 8 は docs 転写ゆえ品質レビュー省略（主エージェント突合のみ）
- **Codex は診断専用**（定常実装に使わない）
- 各ディスパッチにサブエージェント 3 か条 + docs/RAILS_GOTCHAS.md の注入を忘れない

### RAILS_GOTCHAS 適用箇所（計画に織込済み・レビュー時の照合点）

- 書き込み系 redirect は一律 `status: :see_other`（Turbo 302 メソッド保持）
- `enum :status, validate: true`（不正値 500 防止）
- request spec の setup モデル操作は `ActsAsTenant.with_tenant(org) { ... }` で包む
- rubocop は必ず `bundle exec rubocop --force-exclusion <files>`
- モデル検証の uniqueness は置かず DB unique index + RecordNotUnique rescue（TOCTOU）

---

### Task 1: AttendanceRecord（migration + モデル + factory + model spec）

**Files:**
- Create: `db/migrate/<timestamp>_create_attendance_records.rb`（`bin/rails g migration CreateAttendanceRecords --no-timestamps` ではなく手書きで作成。timestamp は `date +%Y%m%d%H%M%S` で採番）
- Create: `app/models/attendance_record.rb`
- Modify: `app/models/user.rb:13`（has_many 追加）
- Create: `spec/factories/attendance_records.rb`
- Create: `spec/models/attendance_record_spec.rb`

- [ ] **Step 1: migration を作成**

`db/migrate/<timestamp>_create_attendance_records.rb`:

```ruby
class CreateAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :attendance_records do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.date :work_date, null: false
      # SPEC §4.8 は timestamptz。clock_in NOT NULL は「1-1 の全行は打刻起源」の帰結 —
      # on_leave/absent の NULL 意味論は 2-2/4-2 が消費と同時に緩和する（1-1 設計 §1）
      t.timestamptz :clock_in, null: false
      t.timestamptz :clock_out
      t.bigint :work_pattern_id
      t.integer :status, null: false

      t.timestamps
    end

    # 二重打刻防止の背骨（user_id はグローバル一意 PK ゆえテナント越境なしの全域一意が安全 — ②型）
    add_index :attendance_records, %i[user_id work_date], unique: true
    # プロジェクト規約（後続スライス LeaveRequest 等の複合 FK 受け皿）
    add_index :attendance_records, %i[organization_id id], unique: true

    # 越境 FK の最終防衛（user_work_patterns と同型の確立パターン）
    add_foreign_key :attendance_records, :users,
                    column: %i[organization_id user_id], primary_key: %i[organization_id id]
    add_foreign_key :attendance_records, :work_patterns,
                    column: %i[organization_id work_pattern_id], primary_key: %i[organization_id id]
  end
end
```

- [ ] **Step 2: migrate して schema.rb を確認**

Run: `bin/rails db:migrate && git diff db/schema.rb`
Expected: `t.timestamptz "clock_in", null: false` / `t.timestamptz "clock_out"` がそのまま dump されること（`t.datetime` に化けたら timestamptz 非対応の兆候 — 即報告）。複合 FK 2 本と index 3 本（organization_id 単独 + 2 複合）が出ること。schema.rb は**手編集禁止**。

- [ ] **Step 3: モデル + User 関連 + factory を書く**

`app/models/attendance_record.rb`:

```ruby
class AttendanceRecord < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user
  # optional: 未割当打刻は NULL（SPEC §5.4 — 1-2 が計算スキップ）。
  # work_pattern_id の書き込みはスナップショットサービス（Clockings::ClockIn）限定。
  # 直接代入経路（1-3 代理打刻・2-3 変更承認）を作る場合は UserWorkPattern 同型の
  # fail-closed 検証を追加すること — 複合 FK は最終防衛（1-1 設計 §1）
  belongs_to :work_pattern, optional: true

  # 残り 4 値は SPEC §4.8 の列挙順で整数を予約: morning_half: 2 / afternoon_half: 3 /
  # on_leave: 4 / absent: 5（消費スライス 2-2/4-2 で追記 — 1-1 設計 §1。
  # plain enum は意図的逸脱: AASM 化は状態が 3 つ以上になる 2-2 で再判断・SPEC §13 実装注記）
  enum :status, { working: 0, clocked_out: 1 }, validate: true

  # 退勤対象・出勤ガード・ホーム表示の単一述語源（1-1 設計 §1 — 二度書き禁止）。
  # window = 夜勤の日付跨ぎ退勤を前日レコードに合流させる探索範囲（SPEC §4.8 出勤日統一）。
  # 端なし Range も可（State の stale 探索が使う）
  scope :working_within, ->(window) { where(status: :working, work_date: window) }

  validates :work_date, presence: true
  validates :clock_in, presence: true
  # 同日 uniqueness のモデル検証は意図的に置かない — TOCTOU で race に勝てないため
  # unique index [user_id, work_date] + RecordNotUnique rescue（Clockings::ClockIn）が一次防衛
  validate :clock_out_not_before_clock_in

  private

  def clock_out_not_before_clock_in
    return if clock_out.blank? || clock_in.blank? || clock_out >= clock_in

    errors.add(:clock_out, "は出勤時刻以降にしてください")
  end
end
```

`app/models/user.rb` の 13 行目 `has_many :user_work_patterns, dependent: :destroy` の直後に追加:

```ruby
  has_many :attendance_records, dependent: :restrict_with_error
```

`spec/factories/attendance_records.rb`:

```ruby
FactoryBot.define do
  factory :attendance_record do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user
    work_date { Date.new(2026, 6, 1) }
    clock_in { Time.utc(2026, 6, 1, 0) } # JST 09:00（unique [user_id, work_date] — 同一 user の複数行は work_date を明示すること）
    status { :working }
  end
end
```

- [ ] **Step 4: model spec を書く**

`spec/models/attendance_record_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe AttendanceRecord, type: :model do
  describe "status enum" do
    it "整数マッピングを固定する（残り 4 値は §4.8 列挙順で 2〜5 を予約 — 並べ替え事故防止）" do
      expect(described_class.statuses).to eq("working" => 0, "clocked_out" => 1)
    end
  end

  describe "検証" do
    it "work_date / clock_in / status は必須" do
      record = described_class.new
      record.valid?
      expect(record.errors[:work_date]).to be_present
      expect(record.errors[:clock_in]).to be_present
      expect(record.errors[:status]).to be_present
    end

    it "clock_out が clock_in より前なら invalid" do
      record = build(:attendance_record,
                     clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 5, 31, 23))
      expect(record).not_to be_valid
      expect(record.errors[:clock_out]).to be_present
    end

    it "clock_out 同時刻は valid（境界）・翌日に跨ぐ退勤も valid（夜勤）" do
      base = Time.utc(2026, 6, 1, 13) # JST 22:00
      expect(build(:attendance_record, clock_in: base, clock_out: base, status: :clocked_out)).to be_valid
      expect(build(:attendance_record, clock_in: base, clock_out: base + 9.hours, status: :clocked_out)).to be_valid
    end
  end

  describe "unique index [user_id, work_date]" do
    it "同一ユーザー同一日の 2 行目は RecordNotUnique（モデル検証は意図的に無し — TOCTOU）" do
      record = create(:attendance_record)
      dup = build(:attendance_record, user: record.user, work_date: record.work_date)
      expect { dup.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "acts_as_tenant" do
    it "organization はテナント文脈から自動代入される" do
      record = described_class.create!(user: create(:user), work_date: Date.new(2026, 6, 3),
                                       clock_in: Time.utc(2026, 6, 3, 0), status: :working)
      expect(record.organization).to eq(ActsAsTenant.test_tenant)
    end
  end

  describe ".working_within" do
    let(:user) { create(:user) }

    it "window 内の working のみ返す（clocked_out・window 外 working を除外）" do
      inside = create(:attendance_record, user:, work_date: Date.new(2026, 6, 2),
                      clock_in: Time.utc(2026, 6, 2, 0))
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1), status: :clocked_out,
             clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 9))
      create(:attendance_record, user:, work_date: Date.new(2026, 5, 30),
             clock_in: Time.utc(2026, 5, 30, 0))

      window = Date.new(2026, 6, 1)..Date.new(2026, 6, 2)
      expect(described_class.working_within(window)).to contain_exactly(inside)
    end

    it "端なし Range も受ける（State の stale 探索と同一述語 — 二度書き防止の前提）" do
      old = create(:attendance_record, user:, work_date: Date.new(2026, 5, 30),
                   clock_in: Time.utc(2026, 5, 30, 0))
      expect(described_class.working_within(..Date.new(2026, 5, 31))).to contain_exactly(old)
    end
  end
end
```

- [ ] **Step 5: spec 実行 + rubocop**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb`
Expected: 全 PASS（8 examples）
Run: `bundle exec rubocop --force-exclusion db/migrate app/models/attendance_record.rb app/models/user.rb spec/models/attendance_record_spec.rb spec/factories/attendance_records.rb`
Expected: no offenses

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb app/models/attendance_record.rb app/models/user.rb spec/models/attendance_record_spec.rb spec/factories/attendance_records.rb
git commit -m "feat: AttendanceRecord（消費分 6 カラム・unique [user_id, work_date]・複合 FK）"
```

---

### Task 2: Clockings 基盤 + ClockIn サービス

**Files:**
- Create: `app/services/clockings.rb`
- Create: `app/services/clockings/clock_in.rb`
- Test: `spec/services/clockings/clock_in_spec.rb`

- [ ] **Step 1: 共有モジュールを書く**

`app/services/clockings.rb`:

```ruby
# 打刻系サービスの共有部品（1-1 設計 §2）
module Clockings
  # 0b-5 OrganizationSettings::Updater と同型の戻り値規約
  Result = Data.define(:success, :record, :error) do
    def success? = success
  end

  # 退勤探索・出勤ガードの window 幅（日）。夜勤の日付跨ぎ退勤を前日レコードへ合流させ、
  # それより前の取り残し working は 4-2 打刻漏れバッチの検出対象として温存する（SPEC §4.8）
  WINDOW_DAYS = 1

  # 打刻状態の探索範囲。ClockIn ガード・ClockOut 対象・State 表示で共有（述語の単一ソース）
  def self.window(today) = (today - WINDOW_DAYS)..today
end
```

- [ ] **Step 2: ClockIn の failing spec を書く**

`spec/services/clockings/clock_in_spec.rb`:

```ruby
require "rails_helper"

# 時刻リテラルはすべて UTC。org の TZ 既定は Asia/Tokyo（= UTC+9）
RSpec.describe Clockings::ClockIn do
  let(:user) { create(:user) }

  it "working レコードを作成し、有効割当のパターンをスナップショットする（SPEC §4.8・§6.1）" do
    pattern = create(:work_pattern)
    create(:user_work_pattern, user:, work_pattern: pattern, start_date: Date.new(2026, 1, 1))

    travel_to Time.utc(2026, 6, 1, 1) do # JST 6/1 10:00
      result = described_class.call(user:)

      expect(result).to be_success
      expect(result.record.work_date).to eq(Date.new(2026, 6, 1))
      expect(result.record.work_pattern_id).to eq(pattern.id)
      expect(result.record).to be_working
      expect(result.record.clock_in).to eq(Time.current)
      expect(result.record.clock_out).to be_nil
    end
  end

  it "有効割当が無ければ work_pattern_id NULL で保存する（SPEC §5.4 — 打刻はブロックしない）" do
    travel_to Time.utc(2026, 6, 1, 1) do
      result = described_class.call(user:)
      expect(result).to be_success
      expect(result.record.work_pattern_id).to be_nil
    end
  end

  it "TZ 境界: JST 8:59（UTC 前日 23:59）でも work_date は JST 当日（Organization#today 経由の検証）" do
    travel_to Time.utc(2026, 5, 31, 23, 59) do # JST 6/1 08:59
      result = described_class.call(user:)
      expect(result.record.work_date).to eq(Date.new(2026, 6, 1))
    end
  end

  it "同日レコードが既にあれば :already_clocked_in（退勤済みでも同様 = 両ボタン無効の決定）" do
    travel_to Time.utc(2026, 6, 1, 1) do
      described_class.call(user:)
      result = described_class.call(user:)
      expect(result).not_to be_success
      expect(result.error).to eq(:already_clocked_in)
    end
  end

  it "window 内に working が残っていれば :still_working（前日退勤忘れ・夜勤中の再出勤防止）" do
    create(:attendance_record, user:, work_date: Date.new(2026, 5, 31),
           clock_in: Time.utc(2026, 5, 31, 0))
    travel_to Time.utc(2026, 6, 1, 1) do
      expect(described_class.call(user:).error).to eq(:still_working)
    end
  end

  it "window 外（2 日以上前）の取り残し working は出勤を妨げない（4-2 検出対象として温存）" do
    create(:attendance_record, user:, work_date: Date.new(2026, 5, 29),
           clock_in: Time.utc(2026, 5, 29, 0))
    travel_to Time.utc(2026, 6, 1, 1) do
      expect(described_class.call(user:)).to be_success
    end
  end

  it "同一組織の他人の同日行・working には反応しない（user 起点クエリの検証 — セキュリティレビュー）" do
    other = create(:user)
    create(:attendance_record, user: other, work_date: Date.new(2026, 6, 1),
           clock_in: Time.utc(2026, 6, 1, 0))
    travel_to Time.utc(2026, 6, 1, 1) do
      expect(described_class.call(user:)).to be_success
    end
  end

  it "検証レースの敗者は unique index で :already_clocked_in に合流する（SPEC §6.1 サーバー側防衛）" do
    travel_to Time.utc(2026, 6, 1, 1) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1), status: :clocked_out,
             clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 0, 30))
      relation = user.attendance_records
      allow(user).to receive(:attendance_records).and_return(relation)
      allow(relation).to receive(:exists?).and_return(false) # 同日ガードだけ素通りさせ index を実発火させる

      result = described_class.call(user:)
      expect(result).not_to be_success
      expect(result.error).to eq(:already_clocked_in)
    end
  end
end
```

- [ ] **Step 3: 実行して失敗を確認**

Run: `bundle exec rspec spec/services/clockings/clock_in_spec.rb`
Expected: FAIL（`uninitialized constant Clockings::ClockIn`）

- [ ] **Step 4: ClockIn を実装**

`app/services/clockings/clock_in.rb`:

```ruby
module Clockings
  # 出勤打刻（1-1 設計 §2）。操作対象は常に呼び出し側の current_user — user_id を外から受けない。
  # with_tenant で自己完結: console/将来ジョブから呼ばれても自社の行しか触れない（SPEC §3.6）。
  # クエリは全て user.attendance_records 起点（同一テナント内の他人に触れない — 1-1 設計 §2）
  class ClockIn
    def self.call(user:) = new(user).call

    def initialize(user)
      @user = user
      @organization = user.organization
    end

    def call
      ActsAsTenant.with_tenant(@organization) do
        today = @organization.today
        # ガードは Clockings::State と同じ述語（UI とサーバー判定を割らない）
        next failure(:already_clocked_in) if @user.attendance_records.exists?(work_date: today)
        next failure(:still_working) if @user.attendance_records
                                             .working_within(Clockings.window(today)).exists?

        record = @user.attendance_records.create!(
          work_date: today,
          clock_in: Time.current,
          # パターンスナップショット（SPEC §4.8・§6.1）: 打刻時点で確定し以後の割当変更は当日に
          # 影響しない（不遡及）。未割当は NULL = 1-2 計算スキップ（SPEC §5.4）。
          # active 割当の重複は exclusion constraint（0b-4）で排除済みゆえ高々 1 件
          work_pattern_id: @user.user_work_patterns.effective_on(today).pick(:work_pattern_id),
          status: :working
        )
        Result.new(success: true, record:, error: nil)
      end
    rescue ActiveRecord::RecordNotUnique
      # 同時タブ・モバイル二重タップ（SPEC §6.1）: unique index [user_id, work_date] が一次防衛。
      # 検証レースの敗者はここで「出勤済み」に合流する
      failure(:already_clocked_in)
    end

    private

    def failure(error) = Result.new(success: false, record: nil, error:)
  end
end
```

- [ ] **Step 5: spec 実行 + rubocop**

Run: `bundle exec rspec spec/services/clockings/clock_in_spec.rb`
Expected: 全 PASS（8 examples）
Run: `bundle exec rubocop --force-exclusion app/services/clockings.rb app/services/clockings/clock_in.rb spec/services/clockings/clock_in_spec.rb`
Expected: no offenses

- [ ] **Step 6: Commit**

```bash
git add app/services/clockings.rb app/services/clockings/clock_in.rb spec/services/clockings/clock_in_spec.rb
git commit -m "feat: Clockings::ClockIn（パターンスナップショット・二重打刻防止・race 合流）"
```

---

### Task 3: Clockings::ClockOut サービス

**Files:**
- Create: `app/services/clockings/clock_out.rb`
- Test: `spec/services/clockings/clock_out_spec.rb`

- [ ] **Step 1: failing spec を書く**

`spec/services/clockings/clock_out_spec.rb`:

```ruby
require "rails_helper"

# 時刻リテラルはすべて UTC。org の TZ 既定は Asia/Tokyo（= UTC+9）
RSpec.describe Clockings::ClockOut do
  let(:user) { create(:user) }

  it "当日の working を退勤させる" do
    record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                    clock_in: Time.utc(2026, 6, 1, 0))
    travel_to Time.utc(2026, 6, 1, 9) do # JST 18:00
      result = described_class.call(user:)

      expect(result).to be_success
      expect(record.reload).to be_clocked_out
      expect(record.clock_out).to eq(Time.current)
    end
  end

  it "夜勤跨ぎ: 前日の working に翌日の退勤が合流し work_date は前日のまま（SPEC §4.8 出勤日統一）" do
    record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                    clock_in: Time.utc(2026, 6, 1, 13)) # JST 6/1 22:00 出勤
    travel_to Time.utc(2026, 6, 1, 22) do # JST 6/2 07:00
      result = described_class.call(user:)

      expect(result).to be_success
      expect(record.reload.work_date).to eq(Date.new(2026, 6, 1))
      expect(record.clock_out).to eq(Time.current)
    end
  end

  it "working が無ければ :not_working" do
    travel_to Time.utc(2026, 6, 1, 9) do
      result = described_class.call(user:)
      expect(result).not_to be_success
      expect(result.error).to eq(:not_working)
    end
  end

  it "退勤済みの後は :not_working（両ボタン無効の決定 — 証跡なし上書き経路を作らない）" do
    create(:attendance_record, user:, work_date: Date.new(2026, 6, 1), status: :clocked_out,
           clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 8))
    travel_to Time.utc(2026, 6, 1, 9) do
      expect(described_class.call(user:).error).to eq(:not_working)
    end
  end

  it "window 外（2 日以上前）の working は退勤対象にしない（4-2 温存・誤った当日退勤の混入防止）" do
    create(:attendance_record, user:, work_date: Date.new(2026, 5, 29),
           clock_in: Time.utc(2026, 5, 29, 0))
    travel_to Time.utc(2026, 6, 1, 9) do
      expect(described_class.call(user:).error).to eq(:not_working)
    end
  end

  it "同僚の working しか無ければ :not_working（user 起点クエリの検証 — セキュリティレビュー）" do
    other = create(:user)
    create(:attendance_record, user: other, work_date: Date.new(2026, 6, 1),
           clock_in: Time.utc(2026, 6, 1, 0))
    travel_to Time.utc(2026, 6, 1, 9) do
      expect(described_class.call(user:).error).to eq(:not_working)
    end
  end

  it "window 内に working が 2 件あれば新しい work_date を退勤させる（防御的 — 通常はガードで発生しない）" do
    old_record = create(:attendance_record, user:, work_date: Date.new(2026, 5, 31),
                        clock_in: Time.utc(2026, 5, 31, 0))
    new_record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                        clock_in: Time.utc(2026, 6, 1, 0))
    travel_to Time.utc(2026, 6, 1, 9) do
      described_class.call(user:)

      expect(new_record.reload).to be_clocked_out
      expect(old_record.reload).to be_working
    end
  end

  it "ロック取得待ちの間に他方が退勤済みへ変えていたら :not_working（同時タブ race の敗者）" do
    record = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
                    clock_in: Time.utc(2026, 6, 1, 0))
    # with_lock の reload 後に「他タブが勝った」状況を再現する（lock 機構そのものは AR を信頼）
    allow_any_instance_of(AttendanceRecord).to receive(:with_lock) do |rec, &block|
      rec.update_columns(status: AttendanceRecord.statuses[:clocked_out],
                         clock_out: Time.utc(2026, 6, 1, 8))
      block.call
    end

    travel_to Time.utc(2026, 6, 1, 9) do
      result = described_class.call(user:)
      expect(result).not_to be_success
      expect(result.error).to eq(:not_working)
      expect(record.reload.clock_out).to eq(Time.utc(2026, 6, 1, 8)) # 先勝ちの時刻が保持される
    end
  end
end
```

- [ ] **Step 2: 実行して失敗を確認**

Run: `bundle exec rspec spec/services/clockings/clock_out_spec.rb`
Expected: FAIL（`uninitialized constant Clockings::ClockOut`）

- [ ] **Step 3: ClockOut を実装**

`app/services/clockings/clock_out.rb`:

```ruby
module Clockings
  # 退勤打刻（1-1 設計 §2）。対象は「window 内の最新 working」— work_date でなく status 起点に
  # するのが夜勤対応の要（日付跨ぎ退勤が前日の出勤レコードに合流する・SPEC §4.8 出勤日統一)。
  # window 外の取り残し working は触らない（4-2 打刻漏れバッチの検出対象として温存）。
  # 退勤済み後の再打刻は不可 — 時刻修正は 2-3 打刻変更申請に一本化（§0 時刻不変条件）
  class ClockOut
    def self.call(user:) = new(user).call

    def initialize(user)
      @user = user
      @organization = user.organization
    end

    def call
      ActsAsTenant.with_tenant(@organization) do
        window = Clockings.window(@organization.today)
        record = @user.attendance_records.working_within(window).order(work_date: :desc).first
        next failure(:not_working) if record.nil?

        record.with_lock do
          # 同時タブ race: ロック待ちの間に他方が退勤済みへ変えていたら敗北（先勝ちの時刻を保持）
          if record.working?
            record.update!(clock_out: Time.current, status: :clocked_out)
            Result.new(success: true, record:, error: nil)
          else
            failure(:not_working)
          end
        end
      end
    end

    private

    def failure(error) = Result.new(success: false, record: nil, error:)
  end
end
```

- [ ] **Step 4: spec 実行 + rubocop**

Run: `bundle exec rspec spec/services/clockings/clock_out_spec.rb`
Expected: 全 PASS（8 examples）
Run: `bundle exec rubocop --force-exclusion app/services/clockings/clock_out.rb spec/services/clockings/clock_out_spec.rb`
Expected: no offenses

- [ ] **Step 5: Commit**

```bash
git add app/services/clockings/clock_out.rb spec/services/clockings/clock_out_spec.rb
git commit -m "feat: Clockings::ClockOut（夜勤跨ぎ合流・window 外温存・行ロック race 直列化）"
```

---

### Task 4: Clockings::State（ホーム導出 PORO）

**Files:**
- Create: `app/services/clockings/state.rb`
- Test: `spec/services/clockings/state_spec.rb`

- [ ] **Step 1: failing spec を書く**

`spec/services/clockings/state_spec.rb`:

```ruby
require "rails_helper"

# 時刻リテラルはすべて UTC。org の TZ 既定は Asia/Tokyo（= UTC+9）
RSpec.describe Clockings::State do
  let(:user) { create(:user) }

  def state = described_class.new(user:)

  context "レコードなし（未出勤）" do
    it "off_duty・出勤のみ活性・バナーなし" do
      travel_to Time.utc(2026, 6, 1, 1) do
        expect(state.status).to eq(:off_duty)
        expect(state.can_clock_in?).to be(true)
        expect(state.can_clock_out?).to be(false)
        expect(state.stale_working_record).to be_nil
      end
    end
  end

  context "当日 working（出勤中）" do
    before do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 0))
    end

    it "working・退勤のみ活性" do
      travel_to Time.utc(2026, 6, 1, 9) do
        expect(state.status).to eq(:working)
        expect(state.can_clock_in?).to be(false)
        expect(state.can_clock_out?).to be(true)
      end
    end

    it "夜勤の日付跨ぎ後も working（前日レコードを window で拾う）" do
      travel_to Time.utc(2026, 6, 1, 22) do # JST 6/2 07:00
        expect(state.status).to eq(:working)
        expect(state.can_clock_out?).to be(true)
        expect(state.can_clock_in?).to be(false)
      end
    end
  end

  context "当日 clocked_out（退勤済）" do
    before do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1), status: :clocked_out,
             clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 9))
    end

    it "clocked_out・両ボタン無効（ユーザー決定）" do
      travel_to Time.utc(2026, 6, 1, 10) do
        expect(state.status).to eq(:clocked_out)
        expect(state.can_clock_in?).to be(false)
        expect(state.can_clock_out?).to be(false)
      end
    end
  end

  context "window 外の取り残し working（退勤忘れ）" do
    before do
      create(:attendance_record, user:, work_date: Date.new(2026, 5, 29),
             clock_in: Time.utc(2026, 5, 29, 0))
    end

    it "stale_working_record が拾われ、表示は off_duty・出勤は活性（4-2 まで打刻は止めない）" do
      travel_to Time.utc(2026, 6, 1, 1) do
        expect(state.stale_working_record&.work_date).to eq(Date.new(2026, 5, 29))
        expect(state.status).to eq(:off_duty)
        expect(state.can_clock_in?).to be(true)
      end
    end

    it "window 内（前日）の working は stale ではない（still_working ガード側の領分）" do
      create(:attendance_record, user:, work_date: Date.new(2026, 5, 31),
             clock_in: Time.utc(2026, 5, 31, 0))
      travel_to Time.utc(2026, 6, 1, 1) do
        expect(state.stale_working_record&.work_date).to eq(Date.new(2026, 5, 29))
        expect(state.working_record.work_date).to eq(Date.new(2026, 5, 31))
      end
    end
  end

  describe "#unassigned_pattern?" do
    it "有効割当が無ければ true・あれば false" do
      travel_to Time.utc(2026, 6, 1, 1) do
        expect(state.unassigned_pattern?).to be(true)
      end

      create(:user_work_pattern, user:, start_date: Date.new(2026, 1, 1))
      travel_to Time.utc(2026, 6, 1, 1) do
        expect(state.unassigned_pattern?).to be(false)
      end
    end
  end
end
```

- [ ] **Step 2: 実行して失敗を確認**

Run: `bundle exec rspec spec/services/clockings/state_spec.rb`
Expected: FAIL（`uninitialized constant Clockings::State`）

- [ ] **Step 3: State を実装**

`app/services/clockings/state.rb`:

```ruby
module Clockings
  # ホームのヘッダー・ボタン活性・バナー導出（読み取り専用・1-1 設計 §2）。
  # サービスのガードと同じ述語（working_within・同日行）を共有し UI とサーバー判定を割らない。
  # クエリは全て user.attendance_records 起点 + with_tenant 自己完結（サービスと同じ規約）
  class State
    def initialize(user:)
      @user = user
      @organization = user.organization
      @today = @organization.today
    end

    attr_reader :today

    # 未出勤 :off_duty / 出勤中 :working / 退勤済 :clocked_out
    def status
      if working_record
        :working
      elsif today_record&.clocked_out?
        :clocked_out
      else
        :off_duty
      end
    end

    def can_clock_in? = today_record.nil? && working_record.nil?

    def can_clock_out? = working_record.present?

    def today_record
      return @today_record if defined?(@today_record)

      @today_record = with_tenant { @user.attendance_records.find_by(work_date: @today) }
    end

    def working_record
      return @working_record if defined?(@working_record)

      @working_record = with_tenant do
        @user.attendance_records.working_within(Clockings.window(@today))
             .order(work_date: :desc).first
      end
    end

    # window より前の取り残し working（退勤忘れバナー — 労務レビュー反映・ユーザー承認）。
    # 出勤は止めない（打刻ブロック禁止の原則）— 検知バッチと是正経路は 4-2/2-3
    def stale_working_record
      return @stale_working_record if defined?(@stale_working_record)

      @stale_working_record = with_tenant do
        @user.attendance_records.working_within(..(@today - Clockings::WINDOW_DAYS - 1))
             .order(work_date: :desc).first
      end
    end

    # 未割当バナー（SPEC §5.4 透明化・0b-4 社員詳細バナーと同型の E 原則）
    def unassigned_pattern?
      return @unassigned_pattern if defined?(@unassigned_pattern)

      @unassigned_pattern = with_tenant { @user.user_work_patterns.effective_on(@today).none? }
    end

    private

    def with_tenant(&) = ActsAsTenant.with_tenant(@organization, &)
  end
end
```

- [ ] **Step 4: spec 実行 + rubocop**

Run: `bundle exec rspec spec/services/clockings/state_spec.rb`
Expected: 全 PASS（8 examples）
Run: `bundle exec rubocop --force-exclusion app/services/clockings/state.rb spec/services/clockings/state_spec.rb`
Expected: no offenses

- [ ] **Step 5: Commit**

```bash
git add app/services/clockings/state.rb spec/services/clockings/state_spec.rb
git commit -m "feat: Clockings::State（ヘッダー/ボタン/バナー導出 — サービスと述語共有）"
```

---

### Task 5: ClockingPolicy + ルート + ClockingsController + ja.yml

**Files:**
- Create: `app/policies/clocking_policy.rb`
- Create: `app/controllers/clockings_controller.rb`
- Modify: `config/routes.rb`（`root "home#show"` の直前に挿入）
- Modify: `config/locales/ja.yml`（`activerecord.models` / `attributes` への追記 + `clockings` キー新設）
- Test: `spec/policies/clocking_policy_spec.rb` / `spec/requests/clockings_spec.rb`

- [ ] **Step 1: failing spec 2 本を書く**

`spec/policies/clocking_policy_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ClockingPolicy do
  it "ログイン済みなら全ロールで打刻可（管理監督者も記録対象 — SPEC §8.3 の整理と整合）" do
    [ create(:user), create(:user, :manager_role), create(:user, :hr_admin) ].each do |user|
      policy = described_class.new(user, :clocking)
      expect(policy.clock_in?).to be(true)
      expect(policy.clock_out?).to be(true)
    end
  end

  it "未ログイン（user nil）は不可（literal true にしない深層防御）" do
    policy = described_class.new(nil, :clocking)
    expect(policy.clock_in?).to be(false)
    expect(policy.clock_out?).to be(false)
  end
end
```

`spec/requests/clockings_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Clockings", type: :request do
  let!(:org)  { create(:organization, subdomain: "acme") } # TZ 既定 Asia/Tokyo
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  describe "POST /clocking/clock_in" do
    it "未認証はサインインへ" do
      post clock_in_clocking_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))
    end

    it "打刻して 303 でホームへ・成功 flash（Turbo の 302 メソッド保持対策 = see_other 必須）" do
      sign_in user
      travel_to Time.utc(2026, 6, 1, 1) do
        expect {
          post clock_in_clocking_url(host: tenant_host(org))
        }.to change { AttendanceRecord.unscoped.where(user: user).count }.by(1)
      end

      expect(response).to redirect_to(root_url(host: tenant_host(org)))
      expect(response).to have_http_status(:see_other)
      follow_redirect!
      expect(response.body).to include("出勤を記録しました")
    end

    it "パラメータに他人の user_id を混ぜても current_user に記録される（SPEC §3.5 — パラメータ不受理）" do
      other = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in user
      travel_to Time.utc(2026, 6, 1, 1) do
        post clock_in_clocking_url(host: tenant_host(org)),
             params: { user_id: other.id, clocking: { user_id: other.id } }
      end

      expect(AttendanceRecord.unscoped.where(user: other)).to be_empty
      expect(AttendanceRecord.unscoped.where(user: user).count).to eq(1)
    end

    it "二重打刻は 303 + alert で合流（SPEC §6.1）" do
      sign_in user
      travel_to Time.utc(2026, 6, 1, 1) do
        post clock_in_clocking_url(host: tenant_host(org))
        post clock_in_clocking_url(host: tenant_host(org))
      end

      expect(response).to have_http_status(:see_other)
      follow_redirect!
      expect(response.body).to include("すでに出勤済みです")
    end
  end

  describe "POST /clocking/clock_out" do
    it "退勤して 303・成功 flash" do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
               clock_in: Time.utc(2026, 6, 1, 0))
      end
      sign_in user
      travel_to Time.utc(2026, 6, 1, 9) do
        post clock_out_clocking_url(host: tenant_host(org))
      end

      expect(response).to have_http_status(:see_other)
      follow_redirect!
      expect(response.body).to include("退勤を記録しました")
    end

    it "working なしは 303 + alert（打刻変更申請への誘導文言）" do
      sign_in user
      travel_to Time.utc(2026, 6, 1, 9) do
        post clock_out_clocking_url(host: tenant_host(org))
      end

      follow_redirect!
      expect(response.body).to include("出勤打刻がありません")
    end
  end
end
```

- [ ] **Step 2: 実行して失敗を確認**

Run: `bundle exec rspec spec/policies/clocking_policy_spec.rb spec/requests/clockings_spec.rb`
Expected: FAIL（`uninitialized constant ClockingPolicy` / `undefined method 'clock_in_clocking_url'`）

- [ ] **Step 3: policy・routes・controller・ja.yml を実装**

`app/policies/clocking_policy.rb`:

```ruby
# 打刻の headless policy（authorize :clocking, :clock_in? — 1-1 設計 §3）。
# Scope は定義しない: 操作対象はコントローラ構造で current_user 固定（パラメータ不受理・
# SPEC §3.5 の最強形 — IDOR 面が存在しない）、一覧系データ取得は current_user.attendance_records
# 起点を必須とする（補償統制）。誤って policy_scope を呼べば Pundit::NotDefinedError で fail-closed。
# 将来の一覧/管理画面（§12.2 ダッシュボード等）は AttendanceRecordPolicy + Scope を新設すること。
# 代理打刻（1-3）は別コントローラ・別ポリシーで作る。
class ClockingPolicy < ApplicationPolicy
  # 全ロール可（管理監督者も打刻記録の対象 — 深夜割増 §8.3 のためにも記録は必須）。
  # literal true にせず user.present? で深層防御（HomePolicy と同型）
  def clock_in? = user.present?
  def clock_out? = user.present?
end
```

`config/routes.rb` の `root "home#show"` の直前に挿入:

```ruby
  resource :clocking, only: [] do
    post :clock_in
    post :clock_out
  end
```

`app/controllers/clockings_controller.rb`:

```ruby
# 打刻（1-1 設計 §4）。操作対象は常に current_user — params を一切消費しない（SPEC §3.5）。
# 応答は redirect 一本（既存パターン合流・1-1 設計 §4 で Turbo Stream を不採用とした決定）
class ClockingsController < ApplicationController
  def clock_in
    authorize :clocking, :clock_in?
    redirect_with Clockings::ClockIn.call(user: current_user), t(".success")
  end

  def clock_out
    authorize :clocking, :clock_out?
    redirect_with Clockings::ClockOut.call(user: current_user), t(".success")
  end

  private

  # 書き込み系の redirect は一律 see_other（Turbo は 302 だとメソッドを保持して再発行する — RAILS_GOTCHAS）
  def redirect_with(result, success_message)
    if result.success?
      redirect_to root_path, notice: success_message, status: :see_other
    else
      redirect_to root_path, alert: t("clockings.errors.#{result.error}"), status: :see_other
    end
  end
end
```

`config/locales/ja.yml` — 既存の `activerecord.models` に `attendance_record`、`activerecord.attributes` に `attendance_record` セクションを**既存キーへマージ**（トップレベル重複を作らない）。`clockings` はトップレベル新設:

```yaml
  # activerecord.models 配下に追記
    attendance_record: "勤怠記録"
  # activerecord.attributes 配下に追記
    attendance_record:
      work_date: "勤務日"
      clock_in: "出勤時刻"
      clock_out: "退勤時刻"
      status: "状態"
  # トップレベル（ja: 直下）に新設
  clockings:
    status:
      off_duty: "未出勤"
      working: "出勤中"
      clocked_out: "退勤済"
    clock_in:
      success: "出勤を記録しました"
    clock_out:
      success: "退勤を記録しました"
    errors:
      already_clocked_in: "すでに出勤済みです"
      still_working: "前日の退勤が記録されていません。先に退勤を打刻してください"
      not_working: "出勤打刻がありません。過去日の退勤時刻は打刻変更申請（Phase 2 で提供予定）で記録します。それまでは管理者に連絡してください"
```

- [ ] **Step 4: spec 実行 + rubocop**

Run: `bundle exec rspec spec/policies/clocking_policy_spec.rb spec/requests/clockings_spec.rb`
Expected: 全 PASS（8 examples）
Run: `bundle exec rubocop --force-exclusion app/policies/clocking_policy.rb app/controllers/clockings_controller.rb spec/policies/clocking_policy_spec.rb spec/requests/clockings_spec.rb`
Expected: no offenses

- [ ] **Step 5: Commit**

```bash
git add app/policies/clocking_policy.rb app/controllers/clockings_controller.rb config/routes.rb config/locales/ja.yml spec/policies/clocking_policy_spec.rb spec/requests/clockings_spec.rb
git commit -m "feat: 打刻ルート + ClockingsController + headless policy（303 redirect・パラメータ不受理）"
```

---

### Task 6: 社員ホーム ヘッダー（HomeController 拡張 + _clocking partial）

**Files:**
- Modify: `app/controllers/home_controller.rb`（全置換）
- Modify: `app/views/home/show.html.erb`（全置換）
- Create: `app/views/home/_clocking.html.erb`
- Test: `spec/requests/home_spec.rb`（新規）

注: カレンダーの組込みは Task 7。本タスクの show.html.erb にはカレンダーを**入れない**。

- [ ] **Step 1: failing spec を書く**

`spec/requests/home_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Home", type: :request do
  let!(:org)  { create(:organization, subdomain: "acme") }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  before { sign_in user }

  def visit_home(params = {})
    get root_url(host: tenant_host(org)), params: params
  end

  it "未出勤: ステータスと出勤ボタンが出る + 未割当バナー（割当ゼロ）" do
    travel_to Time.utc(2026, 6, 1, 1) do
      visit_home
    end

    expect(response.body).to include("未出勤")
    expect(response.body).to include("勤務パターンが割り当てられていません")
  end

  it "有効割当があれば未割当バナーは出ない（対照）" do
    ActsAsTenant.with_tenant(org) do
      create(:user_work_pattern, user:, start_date: Date.new(2026, 1, 1))
    end
    travel_to Time.utc(2026, 6, 1, 1) do
      visit_home
    end

    expect(response.body).not_to include("勤務パターンが割り当てられていません")
  end

  it "出勤中: ステータスが変わる" do
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 0))
    end
    travel_to Time.utc(2026, 6, 1, 9) do
      visit_home
    end

    expect(response.body).to include("出勤中")
  end

  it "退勤済: 注記（打刻変更申請への誘導）が出る" do
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1), status: :clocked_out,
             clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 9))
    end
    travel_to Time.utc(2026, 6, 1, 10) do
      visit_home
    end

    expect(response.body).to include("退勤済")
    expect(response.body).to include("時刻の修正は打刻変更申請で行えます")
  end

  it "退勤忘れ: window 外の取り残し working で警告バナー" do
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 5, 29),
             clock_in: Time.utc(2026, 5, 29, 0))
    end
    travel_to Time.utc(2026, 6, 1, 1) do
      visit_home
    end

    expect(response.body).to include("5月29日 の退勤記録がありません")
  end
end
```

- [ ] **Step 2: 実行して失敗を確認**

Run: `bundle exec rspec spec/requests/home_spec.rb`
Expected: FAIL（「未出勤」等の文言が view に無い）

- [ ] **Step 3: controller + view を実装**

`app/controllers/home_controller.rb`（全置換）:

```ruby
class HomeController < ApplicationController
  # 月ナビの暴走 URL（遠方年）を当月へフォールバックさせる範囲ガード（1-1 設計 §4）
  MONTH_RANGE = Date.new(2020, 1, 1)..Date.new(2100, 12, 1)

  def show
    authorize :home, :show?
    @state = Clockings::State.new(user: current_user)
    @month = parse_month
    # カレンダーは current_user 起点必須（ClockingPolicy の補償統制 — 1-1 設計 §4）。
    # 当月データは各 1 クエリ（records は index_by で日付引きに変換）
    @records = current_user.attendance_records
                           .where(work_date: @month.all_month).index_by(&:work_date)
    @day_types = CompanyCalendarResolver.new(organization: ActsAsTenant.current_tenant)
                                        .day_types(@month, @month.end_of_month)
  end

  private

  # ?month=YYYY-MM。不正値・範囲外は今日の月へフォールバック（1-1 設計 §4）
  def parse_month
    month = Date.strptime(params[:month].to_s, "%Y-%m")
    MONTH_RANGE.cover?(month) ? month : @state.today.beginning_of_month
  rescue ArgumentError
    @state.today.beginning_of_month
  end
end
```

`app/views/home/show.html.erb`（全置換）:

```erb
<main class="mx-auto w-full max-w-3xl p-4">
  <div class="flex items-center justify-between">
    <h1 class="text-2xl font-bold">Gatcha 勤怠</h1>
    <div class="flex items-center gap-3 text-sm text-gray-600">
      <span><%= current_user.name %>（<%= ActsAsTenant.current_tenant.name %>）</span>
      <%= button_to "ログアウト", destroy_user_session_path, method: :delete,
            class: "rounded bg-gray-800 px-3 py-1.5 text-white" %>
    </div>
  </div>

  <%= render "home/clocking", state: @state %>
</main>
```

`app/views/home/_clocking.html.erb`:

```erb
<section class="mt-6 rounded border border-gray-300 p-6">
  <div class="flex items-center justify-between">
    <p class="text-lg font-bold">
      <%= state.today.strftime("%Y年%-m月%-d日") %>（<%= %w[日 月 火 水 木 金 土][state.today.wday] %>）
    </p>
    <span class="rounded px-3 py-1 text-sm <%= { off_duty: "bg-gray-200 text-gray-700",
                                                 working: "bg-blue-100 text-blue-800",
                                                 clocked_out: "bg-green-100 text-green-800" }[state.status] %>">
      <%= t("clockings.status.#{state.status}") %>
    </span>
  </div>

  <%# モバイルは大きめ UI（SPEC §6.1）。連打防止は Turbo 標準の submit 中 disable に委ねる %>
  <div class="mt-4 flex gap-4">
    <%= button_to "出勤", clock_in_clocking_path, disabled: !state.can_clock_in?,
          class: "w-32 rounded px-6 py-3 text-lg text-white #{state.can_clock_in? ? 'bg-blue-600 hover:bg-blue-700' : 'bg-gray-300 cursor-not-allowed'}" %>
    <%= button_to "退勤", clock_out_clocking_path, disabled: !state.can_clock_out?,
          class: "w-32 rounded px-6 py-3 text-lg text-white #{state.can_clock_out? ? 'bg-blue-600 hover:bg-blue-700' : 'bg-gray-300 cursor-not-allowed'}" %>
  </div>

  <% if state.status == :clocked_out %>
    <p class="mt-2 text-sm text-gray-500">時刻の修正は打刻変更申請で行えます（Phase 2 で提供予定）</p>
  <% end %>

  <% if state.unassigned_pattern? %>
    <div class="mt-4 rounded border border-yellow-400 bg-yellow-50 p-3 text-sm text-yellow-800">
      勤務パターンが割り当てられていません。打刻は記録されますが労働時間が計算されません。管理者に連絡してください。
    </div>
  <% end %>

  <% if state.stale_working_record %>
    <div class="mt-4 rounded border border-red-400 bg-red-50 p-3 text-sm text-red-800">
      <%= state.stale_working_record.work_date.strftime("%-m月%-d日") %> の退勤記録がありません。管理者に連絡してください。
    </div>
  <% end %>
</section>
```

- [ ] **Step 4: spec 実行 + rubocop**

Run: `bundle exec rspec spec/requests/home_spec.rb spec/requests/clockings_spec.rb`
Expected: 全 PASS（home 5 + clockings 6 — Task 5 の follow_redirect! が新 view を踏むため両方回す）
Run: `bundle exec rubocop --force-exclusion app/controllers/home_controller.rb spec/requests/home_spec.rb`
Expected: no offenses

- [ ] **Step 5: Commit**

```bash
git add app/controllers/home_controller.rb app/views/home spec/requests/home_spec.rb
git commit -m "feat: 社員ホームヘッダー（打刻ステータス/ボタン・未割当/退勤忘れバナー）"
```

---

### Task 7: Home::CalendarComponent（当月色分け + 前後月ナビ）

**Files:**
- Create: `app/components/home/calendar_component.rb`
- Create: `app/components/home/calendar_component.html.erb`
- Modify: `app/views/home/show.html.erb`（render 1 行追加）
- Test: `spec/components/home/calendar_component_spec.rb`

- [ ] **Step 1: failing spec を書く**

`spec/components/home/calendar_component_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Home::CalendarComponent, type: :component do
  let(:month) { Date.new(2026, 6, 1) }
  let(:today) { Date.new(2026, 6, 15) }

  # 未登録日の ISO 曜日フォールバックを再現（CompanyCalendarResolver#day_types と同じ形）
  def default_day_types(range = Date.new(2026, 6, 1)..Date.new(2026, 6, 30))
    range.index_with { |d| { 6 => :saturday, 7 => :sunday }.fetch(d.cwday, :weekday) }
  end

  def component(records: {}, day_types: default_day_types)
    described_class.new(month:, today:, records:, day_types:)
  end

  describe "#classify" do
    it "当日 working は :working / 過去日 working は :stale_working（退勤忘れの取り残し）" do
      records = {
        Date.new(2026, 6, 15) => build(:attendance_record, work_date: Date.new(2026, 6, 15)),
        Date.new(2026, 6, 10) => build(:attendance_record, work_date: Date.new(2026, 6, 10))
      }
      c = component(records:)
      expect(c.classify(Date.new(2026, 6, 15))).to eq(:working)
      expect(c.classify(Date.new(2026, 6, 10))).to eq(:stale_working)
    end

    it "clocked_out は :clocked_out（過去日でも当日でも）" do
      records = {
        Date.new(2026, 6, 10) => build(:attendance_record, :done, work_date: Date.new(2026, 6, 10)),
        Date.new(2026, 6, 15) => build(:attendance_record, :done, work_date: Date.new(2026, 6, 15))
      }
      c = component(records:)
      expect(c.classify(Date.new(2026, 6, 10))).to eq(:clocked_out)
      expect(c.classify(Date.new(2026, 6, 15))).to eq(:clocked_out)
    end

    it "休日は day_type が :weekday 以外すべて（未登録の土日もフォールバックでグレーにならない — §4.7）" do
      day_types = default_day_types.merge(Date.new(2026, 6, 11) => :holiday,
                                          Date.new(2026, 6, 12) => :legal_holiday)
      c = component(day_types:)
      expect(c.classify(Date.new(2026, 6, 7))).to eq(:holiday)   # 日曜（フォールバック）
      expect(c.classify(Date.new(2026, 6, 6))).to eq(:holiday)   # 土曜（フォールバック）
      expect(c.classify(Date.new(2026, 6, 11))).to eq(:holiday)  # 祝日行
      expect(c.classify(Date.new(2026, 6, 12))).to eq(:holiday)  # 法定休日行
    end

    it "過去の未打刻平日は :unpunched・当日未打刻と未来日は :plain・月外は :outside" do
      c = component
      expect(c.classify(Date.new(2026, 6, 10))).to eq(:unpunched) # 過去平日（水）
      expect(c.classify(Date.new(2026, 6, 15))).to eq(:plain)     # 当日（月）未打刻
      expect(c.classify(Date.new(2026, 6, 22))).to eq(:plain)     # 未来平日
      expect(c.classify(Date.new(2026, 5, 31))).to eq(:outside)   # 前月余白
    end

    it "休日に出勤記録があれば記録の分類が勝つ（休日出勤の可視化）" do
      records = { Date.new(2026, 6, 7) => build(:attendance_record, :done, work_date: Date.new(2026, 6, 7)) }
      expect(component(records:).classify(Date.new(2026, 6, 7))).to eq(:clocked_out)
    end
  end

  describe "レンダリング" do
    it "月タイトル・曜日ヘッダ・前後月ナビが出る" do
      render_inline(component)
      expect(page).to have_text("2026年6月")
      expect(page).to have_link("← 前月", href: "/?month=2026-05")
      expect(page).to have_link("翌月 →", href: "/?month=2026-07")
      expect(page).to have_text("日")
      expect(page).to have_text("土")
    end

    it "2026 年 6 月は月初が月曜 — 前週日曜の余白セルは数字なし・30 日分が描画される" do
      render_inline(component)
      expect(page).to have_css("td", text: /\A30\z/) # 6/30
      expect(page).to have_css("tbody tr", count: 5) # 6 月は 5 週
    end

    it "2 月（28 日・月初日曜）の境界でも壊れない" do
      feb = described_class.new(month: Date.new(2026, 2, 1), today: Date.new(2026, 2, 10),
                                records: {},
                                day_types: default_day_types(Date.new(2026, 2, 1)..Date.new(2026, 2, 28)))
      render_inline(feb)
      expect(page).to have_text("2026年2月")
      expect(page).to have_css("td", text: /\A28\z/)
      expect(page).to have_css("tbody tr", count: 4) # 2/1 日曜開始 → ちょうど 4 週
    end
  end
end
```

- [ ] **Step 2: factory に :done trait を追加**

`spec/factories/attendance_records.rb` の factory ブロック内に追加:

```ruby
    trait :done do
      status { :clocked_out }
      clock_out { clock_in + 9.hours }
    end
```

- [ ] **Step 3: 実行して失敗を確認**

Run: `bundle exec rspec spec/components/home/calendar_component_spec.rb`
Expected: FAIL（`uninitialized constant Home::CalendarComponent`）

- [ ] **Step 4: component を実装**

`app/components/home/calendar_component.rb`:

```ruby
module Home
  # 当月カレンダー（§12.1 最小・1-1 設計 §4）。色分けは 1-1 で判定可能な分類のみ —
  # 休暇=緑/半休=黄/欠勤=赤は Phase 2/4-2 で classify に分岐を足す。
  # day_types は CompanyCalendarResolver#day_types の戻り値（未登録日の ISO 曜日フォールバック内蔵）
  class CalendarComponent < ViewComponent::Base
    WDAYS = %w[日 月 火 水 木 金 土].freeze

    CELL_CLASSES = {
      outside: "",
      working: "bg-blue-200 font-bold",
      stale_working: "bg-blue-100",   # 退勤忘れの取り残し — 退勤済と同系（1-1 設計 §4）
      clocked_out: "bg-blue-100",
      holiday: "bg-orange-50 text-orange-400",
      unpunched: "bg-gray-200 text-gray-500",
      plain: ""
    }.freeze

    # month: 月初日 / today: Organization#today / records: { work_date => AttendanceRecord }
    def initialize(month:, today:, records:, day_types:)
      @month = month
      @today = today
      @records = records
      @day_types = day_types
    end

    def title = @month.strftime("%Y年%-m月")
    def prev_month_param = (@month << 1).strftime("%Y-%m")
    def next_month_param = (@month >> 1).strftime("%Y-%m")

    # 日曜始まりの週配列（前後月の余白セル込み — §4.7 の暦週解釈と整合）
    def weeks
      first = @month.beginning_of_week(:sunday)
      last  = @month.end_of_month.end_of_week(:sunday)
      (first..last).each_slice(7)
    end

    # 日 → 分類 symbol（spec で全分類網羅・1-1 設計 §4）。出勤記録は休日判定より優先（休日出勤の可視化）
    def classify(date)
      return :outside unless date.month == @month.month

      record = @records[date]
      if record&.working?
        date == @today ? :working : :stale_working
      elsif record
        :clocked_out
      elsif holiday?(date)
        :holiday
      elsif date < @today
        :unpunched
      else
        :plain
      end
    end

    def cell_class(date) = CELL_CLASSES.fetch(classify(date))

    def outside?(date) = classify(date) == :outside

    private

    # :weekday 以外（saturday/sunday/holiday/company_holiday/legal_holiday）を休日 1 スタイルに縮約
    # （§12.1 は休日種別の視覚区別を要求しない — YAGNI レビュー反映）
    def holiday?(date)
      @day_types[date] != :weekday
    end
  end
end
```

`app/components/home/calendar_component.html.erb`:

```erb
<section class="mt-6 rounded border border-gray-300 p-6">
  <div class="flex items-center justify-between">
    <%= link_to "← 前月", root_path(month: prev_month_param), class: "text-sm text-blue-600" %>
    <h2 class="font-bold"><%= title %></h2>
    <%= link_to "翌月 →", root_path(month: next_month_param), class: "text-sm text-blue-600" %>
  </div>

  <table class="mt-4 w-full table-fixed text-center text-sm">
    <thead>
      <tr>
        <% WDAYS.each do |wday| %>
          <th class="py-1 font-normal text-gray-500"><%= wday %></th>
        <% end %>
      </tr>
    </thead>
    <tbody>
      <% weeks.each do |week| %>
        <tr>
          <% week.each do |date| %>
            <td class="h-12 border border-gray-100 align-top <%= cell_class(date) %>">
              <%= date.day unless outside?(date) %>
            </td>
          <% end %>
        </tr>
      <% end %>
    </tbody>
  </table>
</section>
```

`app/views/home/show.html.erb` の `<%= render "home/clocking", state: @state %>` の直後に追加:

```erb
  <%= render Home::CalendarComponent.new(month: @month, today: @state.today,
                                         records: @records, day_types: @day_types) %>
```

- [ ] **Step 5: spec 実行 + rubocop**

Run: `bundle exec rspec spec/components/home/calendar_component_spec.rb spec/requests/home_spec.rb`
Expected: 全 PASS（component 8 + home 5）
Run: `bundle exec rubocop --force-exclusion app/components/home/calendar_component.rb spec/components/home/calendar_component_spec.rb spec/factories/attendance_records.rb`
Expected: no offenses

- [ ] **Step 6: 月パラメータのフォールバック spec を home_spec に追加して回す**

`spec/requests/home_spec.rb` 末尾（最後の it の後）に追加:

```ruby
  describe "?month= パラメータ" do
    it "有効値で当該月・不正値/範囲外は当月へフォールバック" do
      travel_to Time.utc(2026, 6, 1, 1) do
        visit_home(month: "2026-05")
        expect(response.body).to include("2026年5月")

        visit_home(month: "garbage")
        expect(response.body).to include("2026年6月")

        visit_home(month: "1999-01")
        expect(response.body).to include("2026年6月")
      end
    end
  end
```

Run: `bundle exec rspec spec/requests/home_spec.rb`
Expected: 全 PASS（6 examples）

- [ ] **Step 7: Commit**

```bash
git add app/components/home spec/components/home app/views/home/show.html.erb spec/requests/home_spec.rb spec/factories/attendance_records.rb
git commit -m "feat: Home::CalendarComponent（当月色分け・前後月ナビ・Resolver 連携）"
```

---

### Task 8: docs 逆反映（SPEC §13 注記・§5.3 補正・労務 NOTES）

**Files:**
- Modify: `docs/SPEC.md`（§13.1 末尾に注記追加・§5.3 Step 1 置換）
- Modify: `docs/LABOR_LAW_REVIEW_NOTES.md`（#14・#15 行追加・#12 の確認内容セル末尾に追記）

- [ ] **Step 1: SPEC §13.1 に実装注記を追加**

`docs/SPEC.md` §13.1（AttendanceRecord.status の状態遷移図セクション）の**末尾**（次の `### 13.2` の直前）に追加:

```markdown
> **実装注記（1-1）:** AttendanceRecord.status は 2 状態（working/clocked_out）の間 plain enum で実装する（整数は本図の列挙順で 0〜5 を予約済み）。AASM 化は状態が 3 つ以上になる 2-2 で再判断する — §2.2-3 の AASM 列挙（申請・締め）とは両立し、本図との 1 対 1 対応はその時点で回復する。副作用のイベント紐付け（§13.6）の置き場も同時に確定する。
```

- [ ] **Step 2: SPEC §5.3 の Step 1 を隣接 2 窓へ補正**

`docs/SPEC.md` §5.3 のコードブロック内、以下の 2 行:

```
Step 1: 勤務帯 [clock_in, clock_out] と深夜帯 [22:00, 翌05:00] の重複（overlap_minutes）を算出
        夜勤も出勤日の 22:00〜翌05:00 との overlap で算出
```

を以下へ置換:

```
Step 1: 勤務帯 [clock_in, clock_out] と隣接 2 つの深夜帯の重複（overlap_minutes）を合算
        深夜帯 = [前日22:00, 当日05:00] と [当日22:00, 翌日05:00] の 2 窓（出勤日 D 基準）
        ※単窓 [D 22:00, D+1 05:00] のみでは早朝シフト（例: 4:00 出勤）の D 0:00〜5:00 帯を
          取りこぼす（労基法 37 条 4 項「午後十時から午前五時まで」— 1-1 設計レビューで補正）
```

- [ ] **Step 3: 労務 NOTES に #14・#15 追加 + #12 更新**

`docs/LABOR_LAW_REVIEW_NOTES.md` の確認事項テーブル（#13 行の直後）に 2 行追加:

```markdown
| 14 | 夜勤の法定休日跨ぎ（§4.8・1-1） | `work_date` = 出勤日統一（1 日 1 レコード）の下、夜勤が法定休日の暦日（0:00〜24:00）に食い込む部分／法定休日出勤が翌平日に食い込む部分の取り扱い。継続勤務は始業日の「一日」の労働とする解釈（昭 63.1.1 基発 1 号・照合済み 2026-06-12 <https://www.mhlw.go.jp/web/t_doc?dataId=00tb1899&dataType=1&pageNo=1>）は 32 条の労働時間集計の原則であり、35 条の休日が暦日で判定される場合の 35% 算定・36 協定 2 系統への振り分けとは別建ての可能性 | 労基法 35 条（照合済み <https://laws.e-gov.go.jp/law/322AC0000000049>）／休日 = 暦日の解釈（昭 23.4.5 基発 535 号とされる — 原典未照合。交替制の例外は昭 42.12.27 基収 5675-2 が MHLW DB に存在・本文未取得） | 跨ぎ部分を分割計上すべきか、出勤日側の属性（35% 対象時間の別カラム等）で持つか。三交替等で暦日休日の例外（継続 24 時間）を採る顧客の扱い。Phase 1-2（計算）・2-4（is_holiday_work）設計前に確認 |
| 15 | 同日再出勤（中抜け勤務）の記録（§4.8・§6.1・1-1） | AttendanceRecord は 1 日 1 区間（clock_in/clock_out 各 1 つ）で、退勤後の再打刻は不可（1-1 ユーザー決定）。同日 2 度目の勤務は打刻変更申請による clock_out 延長でしか反映できず、中抜けを控除する入力欄がない（過大計上 = 賃金側で過払い、控除運用 = 把握漏れの二択） | 労働時間の適正把握（平 29.1.20 基発 0120 第 3 号 — 原典未照合・MCP 検索対象外の指針類）／労基法 109 条（照合済み） | 1 日複数区間の頻度が実顧客で問題になる水準か。v1 は「申請 reason に中抜けを記載 + 管理者が時刻調整」の運用で足りるか、v2 で複数区間 or 中抜け控除入力を要するか |
```

#12 行の**確認内容セル**（最後の列）の末尾に追記:

```markdown
 ※2026-06-12 Phase 1-1 設計で (a) は「計算スキップ（NULL 扱い）」を v1 採用と決定（本人向け警告バナーで透明化）。安全側仮計算 vs 遡及スナップショット補正（ROADMAP バックログ）の最終判断は **Phase 4-1 着手前（§8 コンプラ集計の母数確定前）** を再判断トリガーとする — NULL スキップ分は 36 協定・産業医面談 80h の母数から漏れるため、Phase 4 をスキップ状態のまま出荷しないこと
```

- [ ] **Step 4: 検証 + Commit**

Run: `grep -c "^| 1[45] |" docs/LABOR_LAW_REVIEW_NOTES.md`
Expected: `2`
Run: `grep -n "隣接 2 つの深夜帯" docs/SPEC.md && grep -n "実装注記（1-1）" docs/SPEC.md`
Expected: 各 1 ヒット

```bash
git add docs/SPEC.md docs/LABOR_LAW_REVIEW_NOTES.md
git commit -m "docs: 1-1 逆反映（SPEC §13 enum 注記・§5.3 深夜帯 2 窓補正・労務 NOTES #14/#15/#12 更新）"
```

---

### 最終確認（全タスク完了後・コントローラ実施）

- [ ] `bundle exec rspec` 全件 green（既存 352 + 新規 ≈ 50）
- [ ] `bin/brakeman --no-pager` 警告 0
- [ ] `/preflight` → PR 作成（ROADMAP 1-1 行の更新を PR に同梱 — PR 番号確定後）
