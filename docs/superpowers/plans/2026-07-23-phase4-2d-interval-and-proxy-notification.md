# Phase 4-2d 勤務間インターバル + 代理打刻通知 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 出勤打刻時（本人・代理の両経路）の勤務間インターバル判定 + 記録 + 通知（§6.9）、代理打刻の本人通知（§9.1・暫定バナー置換）、`interval_violation_count` の締め時 Aggregate 派生集計（設計 §13①）を実装し、Phase 4-2 を完了させる。

**Architecture:** 純粋判定 `IntervalShortageCalculator`(PORO) を `IntervalCheck`(Service) が使い、不足時に {AR.note 追記 + AttendanceHistory(interval_shortage)} を 1 tx で記録。controller が commit 後 best-effort で Notifier を発火（4-1c producer 規範）。MAS への increment はせず `MonthlySummaries::Aggregate` が締め時に AH イベントを count する。

**Tech Stack:** Rails 8 / acts_as_tenant / Notifier（4-1）/ 既存 `Clockings` モジュール部品（`append_note` / `record_history` / `Result`）

**設計正本:** `docs/superpowers/specs/2026-06-28-phase4-2-daily-batch-design.md` §6 + §10③⑧⑩ + §11⑨ + **§13（2026-07-23 追補・最新 binding）**

## Global Constraints

- **鉄則 6: いかなる違反検知でも打刻をブロックしない**（SPEC §8）。IntervalCheck の呼び出しは `Clockings.check_interval_safely` 経由の best-effort（`recalculate_safely` 同型）
- **鉄則 7: enum 追加は無し**。`AttendanceHistory.event_type` の `interval_shortage: 8`・`Notification.source_type` の `proxy_clocked: 5` / `interval_shortage: 6` は**予約済み・既存**。enum ハッシュに触れない
- **鉄則 1/2/3**: schema.rb・Gemfile.lock 手編集禁止（本スライスは migration 無し）／rubocop は `git diff --name-only main...HEAD | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion` で `Inspecting N files` の N を確認／spec のモデル操作は `ActsAsTenant.with_tenant(org)` で包む
- **MAS への increment 禁止**（設計 §13①）: clock_in 経路で `MonthlyAttendanceSummary` に触れるコードを書かない。回数の SSOT は `AttendanceHistory(interval_shortage)`（event_date = work_date）
- **通知は commit 後・rescue+log**（§9.5）: `Notifier.call` を service の tx 内に置かない。通知失敗が打刻応答を覆さない
- **RAILS_GOTCHAS 注入**（各タスクで遵守）: 書込み系 redirect は `status: :see_other`（Turbo 302 メソッド保持）／`org.today`・day_type 依存 spec は `travel_to` + UTC org で pin／`with_tenant(引数 org)` 自己ラップ service は昇格**前**に actor の organization_id 一致を検証（昇格プリミティブ・ROADMAP 対称化 backlog 準拠）／`rescue` は「その経路で実際に飛ぶ例外」だけに絞る／新規 `.rb` に `# frozen_string_literal: true`
- **虚偽 remedy 禁止**（設計 §11③の教訓）: 通知文で「打刻変更申請」を約束するのは**その時点で実際に申請可能な文脈のみ**（CCR は clocked_out 記録が前提・`new_entry` は #48 まで拒否）
- 検証コマンド（全タスク共通の完了条件）: `bundle exec rspec <触った spec>` → タスク末尾で関連全 spec。app/ に触れた最終タスクで `bin/brakeman --no-pager`

---

### Task 1: `Clockings::IntervalShortageCalculator`（PORO・純粋判定）

**Files:**
- Create: `app/services/clockings/interval_shortage_calculator.rb`
- Test: `spec/services/clockings/interval_shortage_calculator_spec.rb`

**Interfaces:**
- Consumes: なし（DB 非依存の純関数）
- Produces: `Clockings::IntervalShortageCalculator.call(prev_clock_out: Time|nil, clock_in: Time, threshold_hours: Integer) → Integer(不足分) | nil(非違反)`。Task 2 の `IntervalCheck` が呼ぶ

- [ ] **Step 1: 失敗するテストを書く**

```ruby
# frozen_string_literal: true

require "rails_helper"

# DB 非依存の純関数（設計 §10③/§13④）。境界は §10⑧: 11h ちょうど = 非違反・下回れば違反。
RSpec.describe Clockings::IntervalShortageCalculator do
  def call(prev:, at:, threshold: 11)
    described_class.call(prev_clock_out: prev, clock_in: at, threshold_hours: threshold)
  end

  it "閾値ちょうど（11h）は非違反 = nil（`<` 境界・§10⑧）" do
    prev = Time.utc(2026, 6, 1, 9, 0)
    expect(call(prev: prev, at: prev + 11.hours)).to be_nil
  end

  it "閾値を 1 分下回れば違反 = 不足 1 分" do
    prev = Time.utc(2026, 6, 1, 9, 0)
    expect(call(prev: prev, at: prev + 10.hours + 59.minutes)).to eq(1)
  end

  it "秒以下は floor（10:59:59 の休息は 659 分 = 違反・不足 1 分）" do
    prev = Time.utc(2026, 6, 1, 9, 0)
    expect(call(prev: prev, at: prev + 10.hours + 59.minutes + 59.seconds)).to eq(1)
  end

  it "閾値を 30 秒上回る（11h00m30s）は非違反 = nil（floor は違反側に倒れない）" do
    prev = Time.utc(2026, 6, 1, 9, 0)
    expect(call(prev: prev, at: prev + 11.hours + 30.seconds)).to be_nil
  end

  it "prev_clock_out が nil（初回出勤・退勤記録なし）は nil" do
    expect(call(prev: nil, at: Time.utc(2026, 6, 1, 9))).to be_nil
  end

  it "夜勤明け 9h は違反 = 不足 120 分（§10⑧ 夜勤両方向の違反側）" do
    prev = Time.utc(2026, 6, 1, 22, 0)
    expect(call(prev: prev, at: prev + 9.hours)).to eq(120)
  end

  it "夜勤明け 12h は非違反（§10⑧ 夜勤両方向の非違反側）" do
    prev = Time.utc(2026, 6, 1, 22, 0)
    expect(call(prev: prev, at: prev + 12.hours)).to be_nil
  end

  it "threshold は org 設定値を尊重する（threshold=8 なら 7h59m で不足 1 分・8h で nil）" do
    prev = Time.utc(2026, 6, 1, 9, 0)
    expect(call(prev: prev, at: prev + 7.hours + 59.minutes, threshold: 8)).to eq(1)
    expect(call(prev: prev, at: prev + 8.hours, threshold: 8)).to be_nil
  end
end
```

- [ ] **Step 2: FAIL を確認**

Run: `bundle exec rspec spec/services/clockings/interval_shortage_calculator_spec.rb`
Expected: FAIL（`uninitialized constant Clockings::IntervalShortageCalculator`）

- [ ] **Step 3: 実装**

```ruby
# frozen_string_literal: true

module Clockings
  # 勤務間インターバル不足の純粋判定（SPEC §6.9・設計 §10③/§13④）。DB を触らない。
  # 11h ちょうど = 非違反・1 分でも下回れば違反（`<` 境界・§10⑧）。秒以下は floor で分に丸める
  # （10:59:59 の休息は 659 分 = 違反側・11:00:30 は 660 分 = 非違反側 — 実インターバルに忠実）。
  # 戻り値: 不足分（分・正の整数）。非違反・判定不能（prev なし）は nil
  class IntervalShortageCalculator
    def self.call(prev_clock_out:, clock_in:, threshold_hours:)
      return nil if prev_clock_out.nil?

      interval_minutes = ((clock_in - prev_clock_out) / 60).floor
      threshold_minutes = threshold_hours * 60
      return nil if interval_minutes >= threshold_minutes

      threshold_minutes - interval_minutes
    end
  end
end
```

- [ ] **Step 4: PASS を確認**

Run: `bundle exec rspec spec/services/clockings/interval_shortage_calculator_spec.rb`
Expected: 8 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add app/services/clockings/interval_shortage_calculator.rb spec/services/clockings/interval_shortage_calculator_spec.rb
git commit -m "feat(4-2d): IntervalShortageCalculator — インターバル不足の純粋判定（11h 丁度非違反・floor 分丸め）"
```

---

### Task 2: `Clockings::IntervalCheck`（Service・記録）+ `check_interval_safely` + AH actor 検証

**Files:**
- Create: `app/services/clockings/interval_check.rb`
- Modify: `app/services/clockings.rb`（`check_interval_safely` を末尾メソッドとして追加）
- Modify: `app/models/attendance_history.rb:39`（`interval_shortage` の actor 必須検証を 1 行追加）
- Test: `spec/services/clockings/interval_check_spec.rb`

**Interfaces:**
- Consumes: Task 1 の `IntervalShortageCalculator.call`／既存 `Clockings.append_note(existing, fragment)`・`Clockings.record_history(event_type:, organization:, user:, actor:, source:, note:, previous:, current:)`・`Organization#setting#rest_interval_hours`
- Produces: `Clockings::IntervalCheck.call(record: AttendanceRecord, actor: User) → IntervalCheck::Result(violation, shortage_minutes)`（`#violation?` 述語付き）と `Clockings.check_interval_safely(record:, actor:) → Result | nil`（例外時 nil）。Task 3/4 の controller が呼ぶ

- [ ] **Step 1: 失敗するテストを書く**

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clockings::IntervalCheck do
  let(:org)  { create(:organization) } # TZ 既定 Asia/Tokyo・rest_interval_hours 既定 11
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  # 前日 clocked_out（clock_out 明示）→ 当日 working（clock_in 明示）を作る
  def build_pair(prev_out:, today_in:)
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, :done, user:, work_date: prev_out.to_date,
             clock_in: prev_out - 9.hours, clock_out: prev_out)
      create(:attendance_record, user:, work_date: today_in.to_date,
             clock_in: today_in, status: :working)
    end
  end

  it "不足時: AR.note 追記 + AttendanceHistory(interval_shortage・actor 付き) を記録し violation を返す" do
    record = build_pair(prev_out: Time.utc(2026, 6, 1, 13),          # JST 6/1 22:00 退勤
                        today_in: Time.utc(2026, 6, 1, 23))          # JST 6/2 08:00 出勤（休息 10h）
    result = nil
    expect {
      result = described_class.call(record:, actor: user)
    }.to change { AttendanceHistory.unscoped.where(event_type: :interval_shortage).count }.by(1)

    expect(result).to be_violation
    expect(result.shortage_minutes).to eq(60)
    history = AttendanceHistory.unscoped.where(event_type: :interval_shortage).last
    expect(history.actor_id).to eq(user.id)
    expect(history.event_date).to eq(record.work_date)
    expect(record.reload.note).to include("勤務間インターバル不足")
    expect(record.note).to include("不足 60 分")
  end

  it "非違反（11h ちょうど）: 何も記録せず violation false（AH 0 件・note 不変）" do
    record = build_pair(prev_out: Time.utc(2026, 6, 1, 12),          # JST 6/1 21:00 退勤
                        today_in: Time.utc(2026, 6, 1, 23))          # JST 6/2 08:00 出勤（休息 11h）
    result = nil
    expect {
      result = described_class.call(record:, actor: user)
    }.not_to change { AttendanceHistory.unscoped.count }

    expect(result).not_to be_violation
    expect(record.reload.note).to be_nil
  end

  it "直前退勤は「直近の clock_out を持つ AR」を時刻降順で解決する（夜勤の翌々日判定を prev_day 固定にしない・§13④）" do
    ActsAsTenant.with_tenant(org) do
      # 3 日前にも退勤があるが、直近は前日夜勤明け（6/2 08:00 JST 退勤）
      create(:attendance_record, :done, user:, work_date: Date.new(2026, 5, 30),
             clock_in: Time.utc(2026, 5, 30, 0), clock_out: Time.utc(2026, 5, 30, 9))
      create(:attendance_record, :done, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 13), clock_out: Time.utc(2026, 6, 1, 23)) # 夜勤明け JST 6/2 08:00
    end
    record = ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 3),
             clock_in: Time.utc(2026, 6, 3, 0), status: :working)                     # JST 6/3 09:00 出勤
    end
    result = described_class.call(record:, actor: user)
    # 直近退勤 JST 6/2 08:00 → 出勤 JST 6/3 09:00 = 25h ≥ 11h → 非違反（5/30 と比較したら違反になるが、それは誤り）
    expect(result).not_to be_violation
  end

  it "退勤記録が 1 件も無ければ非違反（初回出勤）" do
    record = ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 0), status: :working)
    end
    expect(described_class.call(record:, actor: user)).not_to be_violation
  end

  it "org 設定の閾値を尊重する（rest_interval_hours=8 なら休息 10h は非違反）" do
    ActsAsTenant.with_tenant(org) { org.setting.update!(rest_interval_hours: 8) }
    record = build_pair(prev_out: Time.utc(2026, 6, 1, 13), today_in: Time.utc(2026, 6, 1, 23)) # 休息 10h
    expect(described_class.call(record:, actor: user)).not_to be_violation
  end

  it "他テナントの actor は昇格前ガードで拒否（RAILS_GOTCHAS「with_tenant は昇格プリミティブ」）" do
    other_org  = create(:organization, subdomain: "other")
    other_user = ActsAsTenant.with_tenant(other_org) { create(:user) }
    record = build_pair(prev_out: Time.utc(2026, 6, 1, 13), today_in: Time.utc(2026, 6, 1, 23))
    expect {
      described_class.call(record:, actor: other_user)
    }.to raise_error(ArgumentError, /actor org mismatch/)
    expect(AttendanceHistory.unscoped.where(event_type: :interval_shortage).count).to eq(0)
  end

  it "note 追記は既存 note を保全する（Clockings.append_note の ； 連結）" do
    record = build_pair(prev_out: Time.utc(2026, 6, 1, 13), today_in: Time.utc(2026, 6, 1, 23))
    ActsAsTenant.with_tenant(org) { record.update!(note: "既存メモ") }
    described_class.call(record:, actor: user)
    expect(record.reload.note).to start_with("既存メモ；")
  end
end
```

- [ ] **Step 2: FAIL を確認**

Run: `bundle exec rspec spec/services/clockings/interval_check_spec.rb`
Expected: FAIL（`uninitialized constant Clockings::IntervalCheck`）

- [ ] **Step 3: 実装**

`app/services/clockings/interval_check.rb`（新規）:

```ruby
# frozen_string_literal: true

module Clockings
  # 出勤打刻時の勤務間インターバル判定 + 記録（SPEC §6.9・設計 §6.1/§13）。
  # 打刻はブロックしない（鉄則 6）— controller からは Clockings.check_interval_safely 経由で呼ぶ。
  # 代理経路（ProxyClockIn 成功後）でも同一判定（§13② — 休息不足の事実は打刻経路に依らない）。
  # MAS には触れない（§13①: interval_violation_count は締め時に Aggregate が AH を count する）。
  class IntervalCheck
    Result = Data.define(:violation, :shortage_minutes) do
      def violation? = violation
    end
    NO_VIOLATION = Result.new(violation: false, shortage_minutes: nil)

    def self.call(record:, actor:) = new(record, actor).call

    def initialize(record, actor)
      @record = record
      @actor = actor
      @user = record.user
      @organization = @user.organization
    end

    def call
      guard_actor_same_organization!
      ActsAsTenant.with_tenant(@organization) do
        shortage = IntervalShortageCalculator.call(
          prev_clock_out: previous_clock_out,
          clock_in: @record.clock_in,
          threshold_hours: threshold_hours
        )
        next NO_VIOLATION if shortage.nil?

        record_violation(shortage)
        Result.new(violation: true, shortage_minutes: shortage)
      end
    end

    private

    # with_tenant 昇格前の操作者検証（RAILS_GOTCHAS「with_tenant は昇格プリミティブ」・
    # Absences::Confirm#guard_actor_same_organization! と同型 — ROADMAP 対称化 backlog 準拠）
    def guard_actor_same_organization!
      return if @actor.organization_id == @organization.id

      raise ArgumentError, "actor org mismatch: actor=#{@actor.id} record=#{@record.id}"
    end

    def threshold_hours = @organization.setting.rest_interval_hours

    # 「同一 user の直近の clock_out を持つ AR」を時刻降順で 1 件（§13④ — prev_day 固定にしない）。
    # 夜勤（前日行に日跨ぎ退勤が入る）も検索条件だけで自然に翌々日判定になる。自レコードは clock_out nil ゆえ対象外
    def previous_clock_out
      @user.attendance_records.where.not(clock_out: nil)
           .where(clock_out: ...@record.clock_in)
           .order(clock_out: :desc).pick(:clock_out)
    end

    # {note 追記 + AH(interval_shortage)} を 1 tx（設計 §6.1）。打刻直後の自レコードへの
    # update! ゆえ並行 DELETE の 0 行 UPDATE 窓は実質無い（同一リクエスト内・作成直後）
    def record_violation(shortage)
      fragment = note_fragment(shortage)
      ActiveRecord::Base.transaction do
        previous = @record.dup # record_history 規約: update! 前にスナップショット
        @record.update!(note: Clockings.append_note(@record.note, fragment))
        Clockings.record_history(
          event_type: :interval_shortage, organization: @organization,
          user: @user, actor: @actor, source: @record, note: fragment,
          previous:, current: @record
        )
      end
    end

    def note_fragment(shortage)
      rest = threshold_hours * 60 - shortage
      "勤務間インターバル不足：休息 #{rest / 60}時間#{format('%02d', rest % 60)}分" \
        "（規定 #{threshold_hours} 時間・不足 #{shortage} 分）"
    end
  end
end
```

`app/services/clockings.rb` の `record_history` メソッドの**後**（module 末尾）に追加:

```ruby
  # インターバル判定を打刻保全しつつ実行（ClockingsController / ProxyClockingsController が共有）。
  # 例外 = 実装バグだが打刻はブロックしない（recalculate_safely と同型・鉄則 6）。nil = 判定不能
  def self.check_interval_safely(record:, actor:)
    Clockings::IntervalCheck.call(record:, actor:)
  rescue StandardError => e
    Rails.error.report(e, severity: :error,
                          context: { attendance_record_id: record.id }, source: "clockings")
    nil
  end
```

`app/models/attendance_history.rb` の `validates :actor_id, presence: true, if: :absence_dismissed?` の行の**直後**に追加（他 event_type と同じ縦並び・不変ゆえ事前防御）:

```ruby
  validates :actor_id, presence: true, if: :interval_shortage? # 4-2d（打刻者 = 本人 or 代理操作者）
```

- [ ] **Step 4: PASS を確認**

Run: `bundle exec rspec spec/services/clockings/interval_check_spec.rb spec/models/attendance_history_spec.rb`
Expected: 全 examples PASS（attendance_history_spec は既存回帰の確認）

- [ ] **Step 5: Commit**

```bash
git add app/services/clockings/interval_check.rb app/services/clockings.rb app/models/attendance_history.rb spec/services/clockings/interval_check_spec.rb
git commit -m "feat(4-2d): IntervalCheck — 不足時に note 追記 + AH(interval_shortage) を 1 tx 記録（MAS 非接触・§13①）"
```

---

### Task 3: 本人出勤打刻への配線（controller + i18n + request spec）

**Files:**
- Modify: `app/controllers/clockings_controller.rb`
- Modify: `config/locales/ja.yml`（`clockings:` 配下に `interval_warning` を追加）
- Test: `spec/requests/clockings_spec.rb`（既存ファイルに describe 追加）

**Interfaces:**
- Consumes: Task 2 の `Clockings.check_interval_safely(record:, actor:) → Result | nil`・既存 `Notifier.call(target_user:, title:, body:, priority:, source_type:, subject_user:)`・`User#manager`
- Produces: なし（末端）。flash `alert` に警告文・manager へ `Notification(source_type: :interval_shortage)`

- [ ] **Step 1: 失敗するテストを書く** — `spec/requests/clockings_spec.rb` の `describe "POST /clocking/clock_in"` ブロック末尾に追加:

```ruby
    describe "勤務間インターバル（§6.9・4-2d）" do
      let!(:manager) { ActsAsTenant.with_tenant(org) { create(:user, role: :manager) } }
      before { ActsAsTenant.with_tenant(org) { user.update!(manager: manager) } }

      def clock_in_at(time)
        travel_to(time) { post clock_in_clocking_url(host: tenant_host(org)) }
      end

      before do
        # 前日 JST 22:00 退勤（UTC 6/1 13:00）
        ActsAsTenant.with_tenant(org) do
          create(:attendance_record, :done, user:, work_date: Date.new(2026, 6, 1),
                 clock_in: Time.utc(2026, 6, 1, 4), clock_out: Time.utc(2026, 6, 1, 13))
        end
        sign_in user
      end

      it "不足時: 打刻は成功（303）+ AH 記録 + note 追記 + 警告 flash + manager へ通知（非ブロック複合 assert・§10⑧）" do
        expect {
          clock_in_at(Time.utc(2026, 6, 1, 23)) # JST 6/2 08:00 出勤 = 休息 10h
        }.to change { AttendanceRecord.unscoped.where(user:).count }.by(1)
          .and change { AttendanceHistory.unscoped.where(event_type: :interval_shortage).count }.by(1)
          .and change { Notification.unscoped.where(target_user: manager, source_type: :interval_shortage).count }.by(1)

        expect(response).to have_http_status(:see_other)
        travel_to(Time.utc(2026, 6, 1, 23)) do
          follow_redirect!
          expect(response.body).to include("出勤を記録しました")
          expect(response.body).to include("勤務間インターバルが不足")
        end
        record = AttendanceRecord.unscoped.where(user:).order(:work_date).last
        expect(record.note).to include("勤務間インターバル不足")
      end

      it "非違反（休息 11h）: AH も通知も警告も出ない（対照）" do
        expect {
          clock_in_at(Time.utc(2026, 6, 2, 0)) # JST 6/2 09:00 出勤 = 休息 11h ちょうど
        }.to change { AttendanceRecord.unscoped.where(user:).count }.by(1)
        expect(AttendanceHistory.unscoped.where(event_type: :interval_shortage).count).to eq(0)
        expect(Notification.unscoped.where(source_type: :interval_shortage).count).to eq(0)
      end

      it "manager 不在（トップ階層）でも打刻と記録は成功し、通知だけ skip" do
        ActsAsTenant.with_tenant(org) { user.update!(manager: nil) }
        expect {
          clock_in_at(Time.utc(2026, 6, 1, 23))
        }.to change { AttendanceHistory.unscoped.where(event_type: :interval_shortage).count }.by(1)
        expect(Notification.unscoped.where(source_type: :interval_shortage).count).to eq(0)
        expect(response).to have_http_status(:see_other)
      end

      it "通知が失敗しても打刻応答は覆らない（§9.5 レジリエンス）" do
        allow(Notifier).to receive(:call).and_raise(StandardError, "boom")
        expect {
          clock_in_at(Time.utc(2026, 6, 1, 23))
        }.to change { AttendanceRecord.unscoped.where(user:).count }.by(1)
        expect(response).to have_http_status(:see_other)
      end
    end
```

- [ ] **Step 2: FAIL を確認**

Run: `bundle exec rspec spec/requests/clockings_spec.rb`
Expected: 新 4 examples が FAIL（AH 0 件・警告文なし）。既存 examples は PASS のまま

- [ ] **Step 3: 実装** — `app/controllers/clockings_controller.rb` を以下へ全置換:

```ruby
# frozen_string_literal: true

# 打刻（1-1 設計 §4）。操作対象は常に current_user — params を一切消費しない（SPEC §3.5）。
# 応答は redirect 一本（既存パターン合流・1-1 設計 §4 で Turbo Stream を不採用とした決定）
class ClockingsController < ApplicationController
  def clock_in
    authorize :clocking, :clock_in?
    result = Clockings::ClockIn.call(user: current_user)
    interval = interval_check(result)
    notify_interval_shortage(result.record, interval) if interval&.violation?
    redirect_with result, t(".success"), warning: interval_warning(interval)
  end

  def clock_out
    authorize :clocking, :clock_out?
    redirect_with Clockings::ClockOut.call(user: current_user), t(".success")
  end

  private

  # 出勤 commit 後の勤務間インターバル判定（§6.9・best-effort・打刻をブロックしない = 鉄則 6）
  def interval_check(result)
    return nil unless result.success?

    Clockings.check_interval_safely(record: result.record, actor: current_user)
  end

  def interval_warning(interval)
    return nil unless interval&.violation?

    t("clockings.interval_warning",
      threshold: current_user.organization.setting.rest_interval_hours,
      shortage: interval.shortage_minutes)
  end

  # 直属 manager への情報提供通知（§6.9・§9.2）。manager 不在（トップ階層）は skip。
  # commit 後 best-effort（§9.5 — 通知失敗が打刻応答を覆さない・absence_confirmations 同型）
  def notify_interval_shortage(record, interval)
    manager = current_user.manager
    return if manager.nil?

    Notifier.call(
      target_user: manager, subject_user: current_user,
      priority: :informational, source_type: :interval_shortage,
      title: "勤務間インターバル不足",
      body: "#{current_user.name} さんの #{record.work_date} の出勤で勤務間インターバルが" \
            "不足しました（不足 #{interval.shortage_minutes} 分）。"
    )
  rescue StandardError => e
    Rails.logger.error(
      "[Notifier] producer 通知失敗 source_type=interval_shortage user=#{current_user.id}: #{e.class}: #{e.message}"
    )
  end

  # 書き込み系の redirect は一律 see_other（Turbo は 302 だとメソッドを保持して再発行する — RAILS_GOTCHAS）。
  # warning は成功時のみ alert に載せる（インターバル警告 — 打刻成功 notice と併存）
  def redirect_with(result, success_message, warning: nil)
    if result.success?
      flash[:alert] = warning if warning
      redirect_to root_path, notice: success_message, status: :see_other
    else
      redirect_to root_path, alert: t("clockings.errors.#{result.error}"), status: :see_other
    end
  end
end
```

`config/locales/ja.yml` の `clockings:` 配下（`errors:` ブロックの後・同インデント階層）に追加:

```yaml
    interval_warning: 勤務間インターバルが不足しています（規定 %{threshold} 時間・不足 %{shortage} 分）。休息を確保してください
```

- [ ] **Step 4: PASS を確認**

Run: `bundle exec rspec spec/requests/clockings_spec.rb spec/services/clockings/`
Expected: 全 examples PASS

- [ ] **Step 5: Commit**

```bash
git add app/controllers/clockings_controller.rb config/locales/ja.yml spec/requests/clockings_spec.rb
git commit -m "feat(4-2d): 本人出勤打刻にインターバル判定を配線（警告 flash + manager 通知・非ブロック）"
```

---

### Task 4: 代理打刻への配線（インターバル + proxy_clocked 通知 + request spec）

**Files:**
- Modify: `app/controllers/proxy_clockings_controller.rb`
- Modify: `config/locales/ja.yml`（`proxy_clockings:` 配下に `interval_warning` を追加）
- Test: `spec/requests/proxy_clockings_spec.rb`（既存ファイルに describe 追加）

**Interfaces:**
- Consumes: Task 2 の `Clockings.check_interval_safely`・`Notifier.call`・既存 `roster`（`ProxyClockingPolicy::Scope`）
- Produces: なし（末端）。本人へ `Notification(source_type: :proxy_clocked)`（出勤・退勤とも）と `Notification(source_type: :interval_shortage)`（不足時）・操作者 flash に警告

- [ ] **Step 1: 失敗するテストを書く** — `spec/requests/proxy_clockings_spec.rb` に describe 追加（既存の let 群 `org` / `manager` / `sub` の定義形はファイル冒頭の既存記述に合わせて再利用する。無ければ以下の形で新設）:

```ruby
  describe "通知とインターバル（4-2d）" do
    let!(:org)     { create(:organization, subdomain: "acme") }
    let!(:manager) { ActsAsTenant.with_tenant(org) { create(:user, role: :manager) } }
    let!(:sub)     { ActsAsTenant.with_tenant(org) { create(:user, manager: manager) } }
    before { sign_in manager }

    it "代理出勤成功で本人へ proxy_clocked 通知（informational・操作者が subject）" do
      travel_to Time.utc(2026, 6, 1, 1) do
        expect {
          post clock_in_proxy_clocking_url(sub, host: tenant_host(org)),
               params: { proxy_clock_reason: "system_failure" }
        }.to change { Notification.unscoped.where(target_user: sub, source_type: :proxy_clocked).count }.by(1)
      end
      notification = Notification.unscoped.where(source_type: :proxy_clocked).last
      expect(notification.subject_user_id).to eq(manager.id)
      expect(notification.body).to include(manager.name)
    end

    it "代理退勤成功でも本人へ proxy_clocked 通知" do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, user: sub, work_date: Date.new(2026, 6, 1),
               clock_in: Time.utc(2026, 6, 1, 0), status: :working)
      end
      travel_to Time.utc(2026, 6, 1, 9) do
        expect {
          post clock_out_proxy_clocking_url(sub, host: tenant_host(org)),
               params: { proxy_clock_reason: "system_failure" }
        }.to change { Notification.unscoped.where(target_user: sub, source_type: :proxy_clocked).count }.by(1)
      end
    end

    it "代理出勤の失敗（出勤済み）では通知しない（成功時のみ・幻通知防止）" do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, user: sub, work_date: Date.new(2026, 6, 1),
               clock_in: Time.utc(2026, 6, 1, 0), status: :working)
      end
      travel_to Time.utc(2026, 6, 1, 1) do
        expect {
          post clock_in_proxy_clocking_url(sub, host: tenant_host(org)),
               params: { proxy_clock_reason: "system_failure" }
        }.not_to change { Notification.unscoped.count }
      end
    end

    it "代理出勤でもインターバル判定が走る（§13② — AH 記録 + 本人へ通知 + 操作者へ警告 flash）" do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, :done, user: sub, work_date: Date.new(2026, 6, 1),
               clock_in: Time.utc(2026, 6, 1, 4), clock_out: Time.utc(2026, 6, 1, 13)) # JST 22:00 退勤
      end
      travel_to Time.utc(2026, 6, 1, 23) do # JST 6/2 08:00 = 休息 10h
        expect {
          post clock_in_proxy_clocking_url(sub, host: tenant_host(org)),
               params: { proxy_clock_reason: "system_failure" }
        }.to change { AttendanceHistory.unscoped.where(event_type: :interval_shortage).count }.by(1)
          .and change { Notification.unscoped.where(target_user: sub, source_type: :interval_shortage).count }.by(1)

        expect(response).to have_http_status(:see_other)
        follow_redirect!
        expect(response.body).to include("勤務間インターバルが不足")
        history = AttendanceHistory.unscoped.where(event_type: :interval_shortage).last
        expect(history.actor_id).to eq(manager.id) # 打刻者 = 代理操作者
      end
    end

    it "通知が失敗しても代理打刻の応答は覆らない（§9.5）" do
      allow(Notifier).to receive(:call).and_raise(StandardError, "boom")
      travel_to Time.utc(2026, 6, 1, 1) do
        expect {
          post clock_in_proxy_clocking_url(sub, host: tenant_host(org)),
               params: { proxy_clock_reason: "system_failure" }
        }.to change { AttendanceRecord.unscoped.where(user: sub).count }.by(1)
        expect(response).to have_http_status(:see_other)
      end
    end
  end
```

- [ ] **Step 2: FAIL を確認**

Run: `bundle exec rspec spec/requests/proxy_clockings_spec.rb`
Expected: 新 5 examples が FAIL（Notification 0 件）。既存 examples は PASS のまま

- [ ] **Step 3: 実装** — `app/controllers/proxy_clockings_controller.rb` の `clock_in` / `clock_out` と private 群を以下へ差し替え（`index` と `roster` は不変）:

```ruby
  def clock_in
    authorize :proxy_clocking, :clock_in?
    target = roster.find(params[:id])
    result = Clockings::ProxyClockIn.call(operator: current_user, target_user: target,
                                          reason: params[:proxy_clock_reason])
    interval = nil
    if result.success?
      notify_proxy_clocked(target, kind: "出勤", remedy: "退勤打刻の後に打刻変更申請で修正できます")
      interval = Clockings.check_interval_safely(record: result.record, actor: current_user)
      notify_target_interval(target, result.record, interval) if interval&.violation?
    end
    redirect_with(result, t(".success"), warning: interval_warning(target, interval))
  end

  def clock_out
    authorize :proxy_clocking, :clock_out?
    target = roster.find(params[:id])
    result = Clockings::ProxyClockOut.call(operator: current_user, target_user: target,
                                           reason: params[:proxy_clock_reason])
    notify_proxy_clocked(target, kind: "退勤", remedy: "打刻変更申請で修正できます") if result.success?
    redirect_with(result, t(".success"))
  end

  private

  # policy_scope(User) 単独は top-level UserPolicy 不在で NotDefinedError ゆえ
  # policy_scope_class を明示（§R・§5 設計）。verify_policy_scoped も満たす
  def roster = policy_scope(User, policy_scope_class: ProxyClockingPolicy::Scope)

  # 本人への代理打刻通知（§9.1・設計 §13③ — 暫定バナーを置換する恒久解決）。
  # remedy は「その時点で実際に可能な操作」のみ約束する（§11③ 虚偽 remedy 禁止 —
  # CCR は clocked_out 記録が前提ゆえ、出勤直後は「退勤後に」と案内する）。
  # commit 後 best-effort（§9.5 — 通知失敗が打刻応答を覆さない）
  def notify_proxy_clocked(target, kind:, remedy:)
    Notifier.call(
      target_user: target, subject_user: current_user,
      priority: :informational, source_type: :proxy_clocked,
      title: "勤怠が代理で打刻されました",
      body: "#{current_user.name} さんがあなたの#{kind}を代理で打刻しました。" \
            "時刻が異なる場合は、#{remedy}。"
    )
  rescue StandardError => e
    Rails.logger.error(
      "[Notifier] producer 通知失敗 source_type=proxy_clocked user=#{target.id}: #{e.class}: #{e.message}"
    )
  end

  # 本人への通知（設計 §13② — 本人打刻時の「画面警告」の代替送達。flash は操作者にしか見えない）
  def notify_target_interval(target, record, interval)
    Notifier.call(
      target_user: target, subject_user: current_user,
      priority: :informational, source_type: :interval_shortage,
      title: "勤務間インターバル不足",
      body: "#{record.work_date} の出勤で勤務間インターバルが不足しています" \
            "（不足 #{interval.shortage_minutes} 分）。休息を確保してください。"
    )
  rescue StandardError => e
    Rails.logger.error(
      "[Notifier] producer 通知失敗 source_type=interval_shortage user=#{target.id}: #{e.class}: #{e.message}"
    )
  end

  def interval_warning(target, interval)
    return nil unless interval&.violation?

    t("proxy_clockings.interval_warning",
      name: target.name,
      threshold: current_user.organization.setting.rest_interval_hours,
      shortage: interval.shortage_minutes)
  end

  # 書込系 redirect は一律 see_other（Turbo 302 メソッド保持・RAILS_GOTCHAS）。
  # warning は成功時のみ alert に載せる（対象社員のインターバル警告 — 操作者向け）
  def redirect_with(result, success_message, warning: nil)
    if result.success?
      flash[:alert] = warning if warning
      redirect_to proxy_clockings_path, notice: success_message, status: :see_other
    else
      redirect_to proxy_clockings_path, alert: t("proxy_clockings.errors.#{result.error}"), status: :see_other
    end
  end
```

`config/locales/ja.yml` の `proxy_clockings:` 配下（`errors:` と同階層）に追加:

```yaml
    interval_warning: "%{name} さんの勤務間インターバルが不足しています（規定 %{threshold} 時間・不足 %{shortage} 分）"
```

- [ ] **Step 4: PASS を確認**

Run: `bundle exec rspec spec/requests/proxy_clockings_spec.rb spec/requests/clockings_spec.rb`
Expected: 全 examples PASS

- [ ] **Step 5: Commit**

```bash
git add app/controllers/proxy_clockings_controller.rb config/locales/ja.yml spec/requests/proxy_clockings_spec.rb
git commit -m "feat(4-2d): 代理打刻に proxy_clocked 通知とインターバル判定を配線（§13②・虚偽 remedy 回避の文言）"
```

---

### Task 5: `MonthlySummaries::Aggregate` の interval_violation_count 派生集計

**Files:**
- Modify: `app/services/monthly_summaries/aggregate.rb`
- Test: `spec/services/monthly_summaries/aggregate_spec.rb`（既存ファイルに describe 追加）

**Interfaces:**
- Consumes: `AttendanceHistory`（`event_type: :interval_shortage`・`event_date` = 違反日の work_date — Task 2 の `record_history` が保証）・既存 `@period.range`
- Produces: `MonthlyAttendanceSummary#interval_violation_count` が締め時集計で確定（SPEC §8.4）。Phase 4-3/5 の consumer が読む

- [ ] **Step 1: 失敗するテストを書く** — `aggregate_spec.rb` に describe 追加:

```ruby
  describe "interval_violation_count（§6.9/§8.4・4-2d = AH 派生集計・設計 §13①）" do
    def shortage_event(date)
      AttendanceHistory.create!(
        user:, actor: user, event_type: :interval_shortage, event_date: date,
        note: "勤務間インターバル不足：テスト", new_status: AttendanceRecord.statuses[:working]
      )
    end

    it "期間内の interval_shortage イベント数を count する（期間外は除外）" do
      org.setting.update!(closing_day: 25)
      shortage_event(Date.new(2026, 2, 26)) # 期首
      shortage_event(Date.new(2026, 3, 25)) # 期末
      shortage_event(Date.new(2026, 3, 26)) # 翌期 → 除外
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.interval_violation_count).to eq(2)
    end

    it "イベントが無ければ 0（既定値の再確認・再集計の冪等）" do
      org.setting.update!(closing_day: 31)
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.interval_violation_count).to eq(0)
    end

    it "他 user のイベントは count しない" do
      org.setting.update!(closing_day: 31)
      other = create(:user, organization: org)
      AttendanceHistory.create!(
        user: other, actor: other, event_type: :interval_shortage, event_date: Date.new(2026, 3, 10),
        note: "他人", new_status: AttendanceRecord.statuses[:working]
      )
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.interval_violation_count).to eq(0)
    end

    it "interval_shortage 以外のイベントは count しない（proxy_clock 等）" do
      org.setting.update!(closing_day: 31)
      AttendanceHistory.create!(
        user:, actor: user, event_type: :proxy_clock, event_date: Date.new(2026, 3, 10),
        note: "代理", new_status: AttendanceRecord.statuses[:working]
      )
      summary = described_class.call(user:, period: period("2026-03"))
      expect(summary.interval_violation_count).to eq(0)
    end
  end
```

- [ ] **Step 2: FAIL を確認**

Run: `bundle exec rspec spec/services/monthly_summaries/aggregate_spec.rb`
Expected: 新 4 examples 中、count を期待する 1 例が FAIL（0 のまま — MAS 列既定 0 ゆえ「2 を期待して 0」の形。0 期待の 3 例は最初から緑でも可）

- [ ] **Step 3: 実装** — `aggregate.rb` の `attributes` の `early_leave_days:` 行の直後に 1 行追加し、private に集計メソッドを追加:

```ruby
        early_leave_days:       in_period.count(&:is_early_leave),
        interval_violation_count: interval_violation_count
```

private（`sum_hours` の前あたり）:

```ruby
    # §6.9/§8.4: 違反回数の SSOT は AttendanceHistory(interval_shortage)（1 違反 = 1 イベント・
    # event_date = 当日 work_date）。締め時派生で月中の MAS 行生成・AttendancePeriod.label 再現を
    # 不要化する（設計 §13① — clock_in 経路は MAS に触れない）
    def interval_violation_count
      AttendanceHistory.where(user: @user, event_type: :interval_shortage,
                              event_date: @period.range).count
    end
```

- [ ] **Step 4: PASS を確認**

Run: `bundle exec rspec spec/services/monthly_summaries/`
Expected: 全 examples PASS（既存の Aggregate/Submit 系も回帰なし）

- [ ] **Step 5: Commit**

```bash
git add app/services/monthly_summaries/aggregate.rb spec/services/monthly_summaries/aggregate_spec.rb
git commit -m "feat(4-2d): interval_violation_count を締め時 Aggregate 派生に確定（AH count・§13① = §11⑨ 決着）"
```

---

### Task 6: 暫定代理打刻バナーの撤去（設計 §13③・ROADMAP バックログ「夜勤エッジ」消化）

**Files:**
- Modify: `app/controllers/home_controller.rb:18-26`（`@today_record` / `@proxy_clock_event` ブロックを削除）
- Modify: `app/views/home/show.html.erb`（バナー render の if ブロックを削除）
- Delete: `app/views/home/_proxy_clock_banner.html.erb`
- Modify: `spec/system/proxy_clocking_spec.rb`（バナー検証 → 通知検証へ）

**Interfaces:**
- Consumes: Task 4 の proxy_clocked 通知（置換先の恒久解決）・既存 `notifications_path`（通知一覧）
- Produces: なし（削除タスク）

- [ ] **Step 1: 失敗するテストを書く** — `spec/system/proxy_clocking_spec.rb` の example 「manager がロスターから部下に代理出勤でき、部下のホームにバナーが出る」を以下へ差し替え（バナーは撤去されるため通知で検証・設計 §13③）:

```ruby
  it "manager がロスターから部下に代理出勤でき、部下へ通知が届く（暫定バナーは撤去済み・§13③）" do
    login(manager)
    click_link "代理打刻"
    expect(page).to have_content(sub.name)
    within("tr", text: sub.name) do
      select "打刻忘れ", from: "proxy_clock_reason"
      click_button "代理出勤"
    end
    expect(page).to have_content("代理出勤を記録しました")

    # ログアウトボタンはホームにのみ存在（ロスター画面には無い）
    visit root_path
    click_button "ログアウト"
    login(sub)
    # 暫定バナーが無いこと（恒久解決 = 通知への一本化）
    expect(page).not_to have_content("代理打刻です")
    # 通知一覧に proxy_clocked 通知が届いていること
    visit notifications_path
    expect(page).to have_content("勤怠が代理で打刻されました")
    expect(page).to have_content(manager.name)
  end
```

- [ ] **Step 2: FAIL を確認**

Run: `bundle exec rspec spec/system/proxy_clocking_spec.rb`
Expected: 通知一覧の検証が PASS（Task 4 で配線済み）だが、`not_to have_content("代理打刻です")` が **FAIL**（バナーがまだ出る）

- [ ] **Step 3: バナーを撤去**

`app/controllers/home_controller.rb` — 以下の 9 行（`# 本人向け代理打刻バナー` コメントから `end` まで）を**削除**:

```ruby
    # 本人向け代理打刻バナー（§R-6・push は Phase 4）。当日レコードが代理打刻なら操作者を履歴から解決。
    # 当日行は State 経由（月非依存・メモ化済 — clocking partial と同一述語源）。@records は当月限定ロードゆえ
    # 非当月閲覧（?month=）で nil になりバナーが消える。State#today_record は同一リクエストで既出ゆえ追加クエリ無し
    @today_record = @state.today_record
    @proxy_clock_event =
      if @today_record&.proxy_clock_reason?
        AttendanceHistory.where(source: @today_record, event_type: :proxy_clock)
                         .order(:created_at).last
      end
```

`app/views/home/show.html.erb` — バナー render の if ブロック（`<% if @proxy_clock_event %>` 〜 `<% end %>` の 3 行）を**削除**。削除前に `grep -n "@today_record\|@proxy_clock_event" app/views/ -r` で他利用が無いことを確認（あれば削除範囲を再考して報告）。

```bash
rm app/views/home/_proxy_clock_banner.html.erb
```

- [ ] **Step 4: PASS を確認**

Run: `bundle exec rspec spec/system/proxy_clocking_spec.rb spec/requests/home_spec.rb`
Expected: 全 examples PASS（home_spec はバナー非依存 — 未割当/退勤忘れバナーのみ検証）

- [ ] **Step 5: Commit**

```bash
git add -A app/controllers/home_controller.rb app/views/home/ spec/system/proxy_clocking_spec.rb
git commit -m "feat(4-2d): 暫定代理打刻バナーを撤去し通知へ一本化（§13③・夜勤エッジの表示欠落もバナーごと解消）"
```

---

### Task 7: SPEC §6.9 改訂 + ROADMAP 更新 + 全体検証

**Files:**
- Modify: `docs/SPEC.md:892`（§6.9 本文）
- Modify: `docs/ROADMAP.md`（4-2 行・Phase 4-2 チェックボックス・バックログ「代理退勤バナーの夜勤エッジ」行）
- Test: なし（docs + 全体回帰）

**Interfaces:**
- Consumes: Task 1〜6 の実装事実
- Produces: SSOT の整合（SPEC ↔ 実装 ↔ ROADMAP）

- [ ] **Step 1: SPEC §6.9 を実装に合わせて改訂** — `docs/SPEC.md` 892 行の本文を以下へ差し替え（regen-spec-index フックが索引行番号を自動補正する）:

```markdown
出勤打刻時にリアルタイム判定（本人打刻・代理打刻の両経路）。直近の退勤（`clock_out` を持つ直近の記録 — 夜勤は自然に翌々日の出勤で判定される）と今回出勤の間隔が `rest_interval_hours`（既定 11）未満なら、本人へ画面警告（代理打刻時は操作者へ警告・本人へ通知）・管理者へ通知。`AttendanceRecord.note` に自動追記 + `AttendanceHistory`（interval_shortage）記録。`interval_violation_count` は月中に増分せず、締め時の集計エンジンが `interval_shortage` イベントを count して保存する（§8.4）。打刻はブロックしない。
```

`grep -n "バナー" docs/SPEC.md` を実行し、代理打刻の暫定バナーに言及する箇所があれば「Phase 4-2d で通知（§9.1）へ置換済み」と分かる形へ更新（無ければ何もしない）。

- [ ] **Step 2: ROADMAP を更新**

1. 行 65 冒頭の `- [ ] **4-2 日次バッチ**` を `- [x] **4-2 日次バッチ**` へ（4-2d で完了条件充足）
2. 同行末尾の「4-2d インターバル + 代理打刻通知。」の直後に `**4-2d ✅ PR [#NN](https://github.com/kei1110/Gatcha_on_RoR/pull/NN)**（IntervalShortageCalculator/IntervalCheck・代理経路でも判定〔§13②〕・proxy_clocked 通知 + 暫定バナー撤去〔§13③〕・interval_violation_count は Aggregate 派生に確定〔§13① = §11⑨ 決着・4-2a plan supersede〕）` を挿入（PR 番号は PR 作成後に確定）
3. バックログ「**代理退勤バナーの夜勤エッジ**」行を `- [x]` 化し、末尾に `→ **4-2d で消化**（バナー撤去・通知へ一本化）` を追記
4. Phase 4 見出しの「（進行中・次は 4-2d）」を「（進行中・次は 4-3）」へ

- [ ] **Step 3: 全体検証（サブエージェント 4 か条の完了条件）**

```bash
bundle exec rspec
git diff --name-only main...HEAD | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion
bin/brakeman --no-pager
```

Expected: rspec 全緑／rubocop `Inspecting N files`（N = 触った .rb 数・0 でないこと）で no offenses／brakeman 警告 0

- [ ] **Step 4: Commit**

```bash
git add docs/SPEC.md docs/ROADMAP.md
git commit -m "docs(4-2d): SPEC §6.9 を Aggregate 派生へ改訂・ROADMAP 4-2 完了化（Phase 4-2 = 候補→確定→取消 + 検知 + インターバルの一周）"
```

---

## マージ前レビュー（CLAUDE.md トリガー表 × 実 diff から導出）

想定 diff 面: `app/models/attendance_history.rb`（検証 1 行）+ `app/services/**` + `app/controllers/**` + views + docs。

- `tenant-isolation-reviewer` — **必須**（models・AH 書き込み・with_tenant 自己ラップ service 新設）
- `labor-law-compliance-reviewer` — **必須**（§8.4 勤務間インターバルの判定境界・11h 既定・Aggregate の月内回数）。`/legal-citation-audit` は §6.9/§8.4 の条文引用に変更が無ければ省略可（インターバルは努力義務・法定値でない）
- `approval-engine-reviewer` — 不要（状態 enum・Approvable・AASM・ApplyApproval に非接触）— 最終 diff で再確認すること
- レビュアーは**読み取り専用**（編集・rspec 実行禁止・判別性は静的読解で論証）。implementer には「衝突検出時は上書きせず即報告」を指示

## 実行後（PR）

`/preflight` → PR 作成（squash・ROADMAP の PR 番号 #NN を確定させる amend を含む）→ マージ前レビュー 2 本 → merge。
