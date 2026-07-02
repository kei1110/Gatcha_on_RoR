# Phase 4-2b 打刻漏れ検知バッチ Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 日次バッチで前日分の打刻漏れ（退勤忘れ・無打刻）を検知し、欠勤候補を永続化・本人/管理者へ通知する。ディスパッチャ→子ジョブのテナント反復（§3.6）と、純粋判定 PORO / 副作用 Service の分離（§10③）で実装する。

**Architecture:** `DailyAttendanceJob`（ディスパッチャ・`current_tenant=nil` で `Organization.active` をスコープ外列挙）→ `DailyAttendanceTenantJob`（子・`with_tenant(org)`）→ `AttendanceAnomalies::Detect`（Service・2 パス）。分類は `AttendanceAnomalies::Detector`（PORO・DB なし）へ委譲。通知は既存 `Notifier`（tx 後発火・§9③）。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / acts_as_tenant / SolidQueue(recurring) / RSpec。

**設計 SSOT:** `docs/superpowers/specs/2026-06-28-phase4-2-daily-batch-design.md` の **§4（検知バッチ）+ §10（1st pass binding）+ §11（2nd pass binding）**。§10/§11 は §2〜§9 を上書きする。本計画の各タスク要件は暗黙に §10/§11 を含む。

## Global Constraints（§4/§10/§11 binding・全タスクに適用）

- **テナント安全（§3.6）**: ディスパッチャは `current_tenant=nil` 前提で `Organization.active` を列挙し org_id だけ子へ渡す。子は perform 冒頭で `ActsAsTenant.with_tenant(org)` 必須（`check-job-tenant-wrap` フック対象）。`Detect` は `current_tenant` 前提で、nil なら `ActsAsTenant::Errors::NoTenant` を raise（fail-closed）。規範は既存 `NotificationDispatchJob`/`NotificationDispatchTenantJob`。
- **§11⑤ insert_all は organization_id を明示**: `AbsenceCandidate.insert_all` は validation・callback・acts_as_tenant の org_id 自動注入を**全 skip**。各 row に `organization_id: @org.id` を明示（怠ると NOT NULL 違反で検知が丸ごと落ちる）。二層防御は insert_all 経路では **DB 複合 FK の 1 層に縮退**する（越境拒否テストは DB 層で・model 検証は console/factory 経路の防御）。
- **§11⑧ notify-once の順序**: 候補通知は「**本人宛 Notifier 成功 → `notified_on = org.today` 確定**」の順（`notified_on` は §10⑤ 猶予期限の起算アンカーゆえ先行させない）。管理者宛は best-effort（`notified_on` の条件にしない）。
- **§11⑪ 子ジョブ nil-guard**: `org = Organization.find_by(id:); return if org.nil?`（dispatch→実行間の org 削除レース耐性）。
- **§10① 退勤忘れは即時通知**: `clock_out_missing` は検知 run（前日分）で即時発火（**次稼働日ゲートを通さない**・reference/ベルのみ）。次稼働日 deferral は**欠勤候補のみ**（`notified_on` + 本人稼働日ゲート）。
- **§10⑦ per-user rescue**: `User.active.find_each` / `AbsenceCandidate.find_each` の各ブロックで rescue + `Rails.logger.error` + `Rails.error.report(e, handled: true)`（Sentry 連携前提の repo idiom）。1 ユーザーの例外でテナント全体の検知/通知を落とさない。
- **§10⑨ upsert**: 欠勤候補は `insert_all(rows, unique_by: %i[organization_id user_id target_date])`（atomic・冪等・競合で ON CONFLICT DO NOTHING）。
- **§10⑪ 夜勤除外**: `work_pattern.night_shift?` の AR はバッチ時点で勤務中の可能性 → `clock_out_missing` 対象外（翌 run で検出）。
- **§10③ PORO/Service 分離**: 純粋判定は `AttendanceAnomalies::Detector`（DB なし単体テスト）。`Detect` は DB ロード + upsert + Notifier の副作用オーケストレーターに専念。
- **§11 corrigenda**: 母集合 `User.active` は未実在ゆえ本スライスで新設（Task 1）。
- **休日集合の正**: `Notifier::HOLIDAY_DAY_TYPES = %i[saturday sunday holiday legal_holiday company_holiday]`。稼働日 = `day_type ∉ HOLIDAY_DAY_TYPES`（唯一の稼働 day_type は `weekday`）。
- **検証**: 各タスク完了条件に `bundle exec rspec <該当>` / `bundle exec rubocop --force-exclusion <files>`。app/ に触れるゆえ仕上げで `bin/brakeman --no-pager`。models/jobs に触れるゆえ**マージ前 `tenant-isolation-reviewer`**。
- **到達性**: 4-2b は §1.4 行を持たない（内部バッチ・caller は recurring）。

## File Structure

| ファイル | 責務 | タスク |
|----------|------|--------|
| `app/models/user.rb`（変更） | `scope :active`（§11 corrigenda） | 1 |
| `app/services/attendance_anomalies/detector.rb`（新規） | 純粋判定 PORO（clock_out_missing? / no_clock_anomaly） | 2 |
| `app/services/attendance_anomalies/detect.rb`（新規） | 検知 Service（2 パス・upsert・通知・resolve・per-user rescue） | 3 |
| `app/jobs/daily_attendance_job.rb`（新規） | ディスパッチャ（Organization.active 列挙） | 4 |
| `app/jobs/daily_attendance_tenant_job.rb`（新規） | 子（with_tenant + nil-guard → Detect.call） | 4 |
| `config/recurring.yml`（変更） | `daily_attendance`（at 2am every day） | 4 |
| `spec/services/attendance_anomalies/detector_spec.rb`（新規） | PORO 全分岐 | 2 |
| `spec/services/attendance_anomalies/detect_spec.rb`（新規） | 検知/通知/resolve/次稼働日/越境ゼロ/per-user rescue | 3 |
| `spec/jobs/daily_attendance_job_spec.rb`（新規） | active のみ enqueue | 4 |
| `spec/jobs/daily_attendance_tenant_job_spec.rb`（新規） | with_tenant ラップ・nil-guard | 4 |

---

## Task 1: `User.active` スコープ（§11 corrigenda）

**Files:**
- Modify: `app/models/user.rb`
- Test: `spec/models/user_spec.rb`

**Interfaces:**
- Consumes: `users.active`（boolean・default true・既存列）。
- Produces: `User.active`（= `where(active: true)`。4-2b の Detect / ディスパッチャ母集合が消費）。

> 設計 §4.2 は母集合を `User.active` と記すが scope は未実在（`active?` 述語のみ）。`Organization.active` と同型で新設する。

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/user_spec.rb` に追加（テナント文脈で・既存の describe 群の末尾）:

```ruby
  describe ".active スコープ（4-2b・§11 corrigenda）" do
    let(:org) { create(:organization) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "active: true のみ返す" do
      active_user = create(:user, active: true)
      inactive_user = create(:user, active: false)
      expect(User.active).to include(active_user)
      expect(User.active).not_to include(inactive_user)
    end
  end
```

Run: `bundle exec rspec spec/models/user_spec.rb -e "active スコープ"`
Expected: FAIL（`User.active` 未定義 → NoMethodError）。

- [ ] **Step 2: scope を追加**

`app/models/user.rb` の関連宣言（`belongs_to :manager` 群）の直後に追加:

```ruby
  # 在籍者の母集合（§4.2 日次バッチ・Organization.active と同型）
  scope :active, -> { where(active: true) }
```

- [ ] **Step 3: テストを通す**

Run: `bundle exec rspec spec/models/user_spec.rb`
Expected: 全 PASS（新 scope + 既存例が回帰なし）。

- [ ] **Step 4: rubocop**

Run: `bundle exec rubocop --force-exclusion app/models/user.rb spec/models/user_spec.rb`
Expected: 0 offenses。

- [ ] **Step 5: Commit**

```bash
git add app/models/user.rb spec/models/user_spec.rb
git commit -m "feat: User.active スコープ（4-2b 母集合・§11 corrigenda）"
```

---

## Task 2: `AttendanceAnomalies::Detector`（純粋判定 PORO・§10③）

**Files:**
- Create: `app/services/attendance_anomalies/detector.rb`
- Test: `spec/services/attendance_anomalies/detector_spec.rb`

**Interfaces:**
- Consumes: なし（DB を引かない純関数・事実だけ受け取る）。
- Produces:
  - `AttendanceAnomalies::Detector.clock_out_missing?(status:, clock_in_present:, clock_out_present:, night_shift:) → Boolean`
  - `AttendanceAnomalies::Detector.no_clock_anomaly(covering_leave_applying:, has_covering_leave_request:, working_day:) → :leave_pending_no_clock | :absence_candidate | nil`
  - 消費は `AttendanceAnomalies::Detect`（Task 3）。

> §10③: 純粋判定を PORO に切り出し DB なし単体テスト。§10⑪ 夜勤除外は `clock_out_missing?` が担う。§4.2② の分類（申請中 LR / 欠勤候補 / なし）は `no_clock_anomaly` が担う。

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/attendance_anomalies/detector_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

# 純関数ゆえ DB もテナント文脈も不要（§10③）
RSpec.describe AttendanceAnomalies::Detector do
  describe ".clock_out_missing?" do
    def call(**overrides)
      described_class.clock_out_missing?(
        **{ status: "working", clock_in_present: true, clock_out_present: false, night_shift: false }.merge(overrides)
      )
    end

    it "working・打刻あり・退勤なし・非夜勤 → true" do
      expect(call).to be(true)
    end

    it "morning_half / afternoon_half も対象" do
      expect(call(status: "morning_half")).to be(true)
      expect(call(status: "afternoon_half")).to be(true)
    end

    it "退勤済（clock_out あり）→ false" do
      expect(call(clock_out_present: true)).to be(false)
    end

    it "出勤打刻なし（clock_in なし）→ false（休暇承認のみ等の誤検知防止）" do
      expect(call(clock_in_present: false)).to be(false)
    end

    it "夜勤 → false（勤務中の可能性・翌 run へ deferral・§10⑪）" do
      expect(call(night_shift: true)).to be(false)
    end

    it "clock 対象外 status（clocked_out / on_leave / absent）→ false" do
      expect(call(status: "clocked_out")).to be(false)
      expect(call(status: "on_leave")).to be(false)
      expect(call(status: "absent")).to be(false)
    end
  end

  describe ".no_clock_anomaly" do
    def call(**overrides)
      described_class.no_clock_anomaly(
        **{ covering_leave_applying: false, has_covering_leave_request: false, working_day: true }.merge(overrides)
      )
    end

    it "申請中 LR 有 → :leave_pending_no_clock" do
      expect(call(covering_leave_applying: true, has_covering_leave_request: true)).to eq(:leave_pending_no_clock)
    end

    it "LR 皆無 ∧ 稼働日 → :absence_candidate" do
      expect(call).to eq(:absence_candidate)
    end

    it "非稼働日 → nil（LR 皆無でも候補にしない・判断 E）" do
      expect(call(working_day: false)).to be_nil
    end

    it "LR 有（申請中でない・承認/却下/取消等）∧ 稼働日 → nil（LR 全 status 除外・§10 是認）" do
      expect(call(covering_leave_applying: false, has_covering_leave_request: true)).to be_nil
    end

    it "申請中 LR は非稼働日でも管理者通知（申請中判定が稼働日に優先）" do
      expect(call(covering_leave_applying: true, has_covering_leave_request: true, working_day: false))
        .to eq(:leave_pending_no_clock)
    end
  end
end
```

Run: `bundle exec rspec spec/services/attendance_anomalies/detector_spec.rb`
Expected: FAIL（クラス未定義）。

- [ ] **Step 2: PORO を実装**

`app/services/attendance_anomalies/detector.rb`:

```ruby
# frozen_string_literal: true

module AttendanceAnomalies
  # 前日分の単一 (user, date) を分類する純関数（設計 §4.2・§10③）。
  # DB を引かず事実だけ受け取る（Detect が DB から解決して渡す）→ DB なし単体テスト可。
  class Detector
    # 退勤打刻忘れの対象 status（§4.2①）。clocked_out/on_leave/absent は対象外。
    CLOCK_STATUSES = %w[working morning_half afternoon_half].freeze

    # AR あり: 退勤打刻忘れか（§4.2①）。夜勤は勤務中の可能性ゆえ false（翌 run へ deferral・§10⑪）。
    def self.clock_out_missing?(status:, clock_in_present:, clock_out_present:, night_shift:)
      return false unless CLOCK_STATUSES.include?(status)
      return false unless clock_in_present
      return false if clock_out_present
      return false if night_shift

      true
    end

    # AR なし: 無打刻の分類（§4.2②）。
    # 申請中 LR 有 → :leave_pending_no_clock（管理者情報提供）
    # LR 皆無（全 status）∧ 稼働日 → :absence_candidate（欠勤候補 upsert）
    # それ以外（非稼働日 / LR 有だが申請中でない）→ nil
    def self.no_clock_anomaly(covering_leave_applying:, has_covering_leave_request:, working_day:)
      return :leave_pending_no_clock if covering_leave_applying
      return :absence_candidate if working_day && !has_covering_leave_request

      nil
    end
  end
end
```

- [ ] **Step 3: テストを通す**

Run: `bundle exec rspec spec/services/attendance_anomalies/detector_spec.rb`
Expected: 全 PASS。

- [ ] **Step 4: rubocop**

Run: `bundle exec rubocop --force-exclusion app/services/attendance_anomalies/detector.rb spec/services/attendance_anomalies/detector_spec.rb`
Expected: 0 offenses。

- [ ] **Step 5: Commit**

```bash
git add app/services/attendance_anomalies/detector.rb spec/services/attendance_anomalies/detector_spec.rb
git commit -m "feat: AttendanceAnomalies::Detector（純粋判定 PORO・夜勤除外/無打刻分類）"
```

---

## Task 3: `AttendanceAnomalies::Detect`（検知 Service・2 パス）

**Files:**
- Create: `app/services/attendance_anomalies/detect.rb`
- Test: `spec/services/attendance_anomalies/detect_spec.rb`

**Interfaces:**
- Consumes: `AttendanceAnomalies::Detector`（Task 2）/ `User.active`（Task 1）/ `Notifier.call(target_user:, title:, body:, priority:, source_type:, subject_user:)`（既存）/ `CompanyCalendarResolver#day_type`（既存）/ `AbsenceCandidate`（4-2a）/ `LeaveRequest`（start_date..end_date・approval_status）/ `AttendanceRecord`。
- Produces: `AttendanceAnomalies::Detect.call(date:)`（date = 前日 `org.today.prev_day`。`with_tenant` 前提。戻り値 nil）。消費は `DailyAttendanceTenantJob`（Task 4）。

> **2 パス構造（設計 §4.2/§4.3/§4.4）**:
> - pass 1（`detect_prev_day`）= 前日分を検知。退勤忘れ（本人・即時・§10①）/ 休暇申請中無打刻（管理者・即時）/ 欠勤候補（`insert_all` upsert・§10⑨⑪⑤）。
> - pass 2（`process_candidates`）= 既存候補を全走査。AR/LR 出現で resolve（destroy）/ 本人稼働日（org.today）∧ notified_on 未設定で notify-once（§11⑧）。
> - per-user/per-candidate rescue（§10⑦）。

- [ ] **Step 1: 失敗するテスト（pass 1 検知）を書く**

`spec/services/attendance_anomalies/detect_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe AttendanceAnomalies::Detect, type: :service do
  let(:org) { create(:organization, time_zone: "UTC") } # travel_to 決定化のため UTC 固定

  # 対象日（前日）を稼働日として登録
  def working_calendar(date)
    create(:company_calendar, date:, day_type: :weekday, name: "平日")
  end

  def holiday_calendar(date)
    create(:company_calendar, date:, day_type: :company_holiday, name: "休業")
  end

  def notifications_for(user, source_type)
    Notification.where(target_user: user, source_type:)
  end

  describe "#call pass 1: 前日検知" do
    let(:prev_day) { Date.new(2026, 5, 1) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    before { working_calendar(prev_day) }

    it "退勤打刻忘れ（working・clock_in 有・clock_out 無・非夜勤）→ 本人へ clock_out_missing を 1 件通知" do
      user = create(:user)
      create(:attendance_record, user:, work_date: prev_day, status: :working,
                                 clock_in: Time.utc(2026, 5, 1, 0), clock_out: nil)

      expect { described_class.call(date: prev_day) }
        .to change { notifications_for(user, :clock_out_missing).count }.by(1)
    end

    it "夜勤の退勤忘れは検知しない（§10⑪）" do
      user = create(:user)
      night = create(:work_pattern, night_shift: true, start_time: "22:00", end_time: "06:00")
      create(:attendance_record, user:, work_date: prev_day, status: :working,
                                 clock_in: Time.utc(2026, 5, 1, 13), clock_out: nil, work_pattern: night)

      expect { described_class.call(date: prev_day) }
        .not_to change { notifications_for(user, :clock_out_missing).count }
    end

    it "無打刻 ∧ 稼働日 ∧ LR 皆無 → 欠勤候補を作成（notified_on nil）" do
      user = create(:user)

      expect { described_class.call(date: prev_day) }
        .to change { AbsenceCandidate.where(user:, target_date: prev_day).count }.by(1)
      expect(AbsenceCandidate.find_by(user:, target_date: prev_day).notified_on).to be_nil
    end

    it "無打刻でも休日は欠勤候補を作らない（判断 E）" do
      other_day = Date.new(2026, 5, 2)
      holiday_calendar(other_day)
      user = create(:user)

      expect { described_class.call(date: other_day) }
        .not_to change { AbsenceCandidate.count }
    end

    it "AR 有（on_leave 等）の日は欠勤候補を作らない" do
      user = create(:user)
      create(:attendance_record, user:, work_date: prev_day, status: :on_leave, clock_in: nil)

      expect { described_class.call(date: prev_day) }.not_to change { AbsenceCandidate.count }
    end

    it "申請中 LR を覆う無打刻 → 管理者へ leave_pending_no_clock、欠勤候補は作らない" do
      manager = create(:user)
      user = create(:user, manager:)
      lt = create(:leave_type)
      create(:leave_request, requester: user, leave_type: lt,
                             start_date: prev_day, end_date: prev_day, approval_status: :applying)

      expect { described_class.call(date: prev_day) }
        .to change { notifications_for(manager, :leave_pending_no_clock).count }.by(1)
      expect(AbsenceCandidate.where(user:).count).to eq(0)
    end

    it "退勤忘れは非稼働日（前日が休日）でも即時発火する（稼働日ゲートを通さない・§10①/§11⑩）" do
      holiday = Date.new(2026, 5, 3)
      holiday_calendar(holiday)
      user = create(:user)
      create(:attendance_record, user:, work_date: holiday, status: :working,
                                 clock_in: Time.utc(2026, 5, 3, 0), clock_out: nil)

      expect { described_class.call(date: holiday) }
        .to change { notifications_for(user, :clock_out_missing).count }.by(1)
    end
  end
end
```

Run: `bundle exec rspec spec/services/attendance_anomalies/detect_spec.rb`
Expected: FAIL（`AttendanceAnomalies::Detect` 未定義）。

- [ ] **Step 2: Detect Service を実装（pass 1 + pass 2 両方）**

`app/services/attendance_anomalies/detect.rb`:

```ruby
# frozen_string_literal: true

module AttendanceAnomalies
  # 日次バッチの検知オーケストレーター（設計 §4・§10・§11）。with_tenant 前提（fail-closed）。
  # pass 1: 前日分を検知（退勤忘れ即時通知 / 休暇申請中無打刻 即時通知 / 欠勤候補 upsert）
  # pass 2: 既存候補を走査（AR/LR 出現で resolve・本人稼働日 run で notify-once）
  # 純粋判定は Detector（PORO）へ委譲（§10③）。副作用オーケストレーションに専念。
  class Detect
    # 休日集合の正（= Notifier::HOLIDAY_DAY_TYPES）。稼働日 = day_type ∉ この集合。
    HOLIDAY_DAY_TYPES = Notifier::HOLIDAY_DAY_TYPES

    def self.call(date:) = new(date:).call

    def initialize(date:)
      @date = date                      # 検知対象日（前日・org.today.prev_day）
      @org = ActsAsTenant.current_tenant # with_tenant 前提
    end

    def call
      raise ActsAsTenant::Errors::NoTenant, "Detect は with_tenant 内で呼ぶこと（§3.6）" if @org.nil?

      detect_prev_day
      process_candidates
      nil
    end

    private

    # ---- pass 1: 前日分の検知（§4.2） ----
    def detect_prev_day
      working = working_day?(@date)
      rows = []
      User.active.find_each do |user|
        ar = AttendanceRecord.find_by(user_id: user.id, work_date: @date)
        if ar
          notify_clock_out_missing(user) if clock_out_missing?(ar)
        else
          case no_clock_anomaly(user, working)
          when :leave_pending_no_clock then notify_leave_pending(user)
          when :absence_candidate then rows << candidate_row(user)
          end
        end
      rescue StandardError => e
        report(e, "detect_prev_day user_id=#{user.id}")
      end
      upsert_candidates(rows)
    end

    def clock_out_missing?(attendance_record)
      Detector.clock_out_missing?(
        status: attendance_record.status,
        clock_in_present: attendance_record.clock_in.present?,
        clock_out_present: attendance_record.clock_out.present?,
        night_shift: attendance_record.work_pattern&.night_shift? || false
      )
    end

    def no_clock_anomaly(user, working)
      lrs = covering_leave_requests(user.id, @date)
      Detector.no_clock_anomaly(
        covering_leave_applying: lrs.where(approval_status: :applying).exists?,
        has_covering_leave_request: lrs.exists?,
        working_day: working
      )
    end

    def upsert_candidates(rows)
      return if rows.empty?

      # §10⑨ atomic upsert / §11⑤ organization_id 明示（insert_all は acts_as_tenant 注入・検証を bypass）
      AbsenceCandidate.insert_all(rows, unique_by: %i[organization_id user_id target_date])
    end

    def candidate_row(user)
      now = Time.current
      { organization_id: @org.id, user_id: user.id, target_date: @date,
        notified_on: nil, created_at: now, updated_at: now }
    end

    # ---- pass 2: 既存候補の resolve / notify（§4.3/§4.4） ----
    def process_candidates
      today = @org.today
      today_working = working_day?(today)
      AbsenceCandidate.find_each do |candidate|
        if covered?(candidate)
          candidate.destroy
        elsif candidate.notified_on.nil? && today_working
          notify_candidate(candidate, today)
        end
      rescue StandardError => e
        report(e, "process_candidates candidate_id=#{candidate.id}")
      end
    end

    def covered?(candidate)
      AttendanceRecord.exists?(user_id: candidate.user_id, work_date: candidate.target_date) ||
        covering_leave_requests(candidate.user_id, candidate.target_date).exists?
    end

    def notify_candidate(candidate, today)
      user = candidate.user
      Notifier.call(
        target_user: user, priority: :informational, source_type: :absence_candidate,
        title: "出勤記録がありません",
        body: "#{candidate.target_date} の出勤記録がありません。打刻漏れの場合は打刻変更申請を提出してください。"
      )
      candidate.update!(notified_on: today) # §11⑧ 本人 Notifier 成功後に確定（猶予起算アンカー保護）
      notify_candidate_manager(user, candidate.target_date) # 管理者は best-effort（notified_on の条件にしない）
    end

    def notify_candidate_manager(user, target_date)
      manager = user.manager
      return if manager.nil?

      Notifier.call(
        target_user: manager, subject_user: user,
        priority: :informational, source_type: :absence_candidate,
        title: "部下の出勤記録がありません",
        body: "#{user.name} さんの #{target_date} の出勤記録がありません。"
      )
    end

    # ---- pass 1 の即時通知 ----
    def notify_clock_out_missing(user)
      Notifier.call(
        target_user: user, priority: :reference, source_type: :clock_out_missing,
        title: "退勤打刻がありません",
        body: "#{@date} の退勤打刻が記録されていません。退勤時刻の打刻変更申請をご確認ください。"
      )
    end

    def notify_leave_pending(user)
      manager = user.manager
      return if manager.nil?

      Notifier.call(
        target_user: manager, subject_user: user,
        priority: :informational, source_type: :leave_pending_no_clock,
        title: "部下の打刻がありません（休暇申請中）",
        body: "#{user.name} さんの #{@date} の出勤記録がありません（休暇申請が承認待ちです）。"
      )
    end

    # ---- 共通 ----
    # 対象日を覆う LR（start_date <= date <= end_date・status 不問）
    def covering_leave_requests(user_id, date)
      LeaveRequest.where(requester_id: user_id).where(start_date: ..date).where(end_date: date..)
    end

    def working_day?(date)
      !CompanyCalendarResolver.new(organization: @org).day_type(date).in?(HOLIDAY_DAY_TYPES)
    end

    def report(error, context)
      Rails.logger.error("[AttendanceAnomalies::Detect] #{context}: #{error.class} #{error.message}")
      Rails.error.report(error, handled: true) # 運用可視化（Sentry 連携前提・§10⑦）
    end
  end
end
```

- [ ] **Step 3: pass 1 テストを通す**

Run: `bundle exec rspec spec/services/attendance_anomalies/detect_spec.rb -e "pass 1"`
Expected: 全 PASS。

- [ ] **Step 4: pass 2（resolve / notify / 次稼働日 / notify-once）テストを追記**

`spec/services/attendance_anomalies/detect_spec.rb` の `RSpec.describe` 末尾（pass 1 describe の後）に追加:

```ruby
  describe "#call pass 2: 候補の resolve / notify" do
    let(:target) { Date.new(2026, 5, 1) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "AR 出現で候補を resolve（destroy）" do
      user = create(:user)
      candidate = create(:absence_candidate, user:, target_date: target)
      create(:attendance_record, user:, work_date: target, status: :clocked_out,
                                 clock_in: Time.utc(2026, 5, 1, 0), clock_out: Time.utc(2026, 5, 1, 9))

      expect { described_class.call(date: Date.new(2026, 4, 30)) }
        .to change { AbsenceCandidate.exists?(candidate.id) }.from(true).to(false)
    end

    it "LR 出現（事後申請・status 不問）で候補を resolve" do
      user = create(:user)
      lt = create(:leave_type)
      candidate = create(:absence_candidate, user:, target_date: target)
      create(:leave_request, requester: user, leave_type: lt,
                             start_date: target, end_date: target, approval_status: :applying)

      expect { described_class.call(date: Date.new(2026, 4, 30)) }
        .to change { AbsenceCandidate.exists?(candidate.id) }.from(true).to(false)
    end

    it "本人の今日が稼働日 ∧ notified_on 未設定 → 本人+管理者に通知し notified_on を設定" do
      working_calendar(org.today)
      manager = create(:user)
      user = create(:user, manager:)
      candidate = create(:absence_candidate, user:, target_date: target, notified_on: nil)

      described_class.call(date: Date.new(2026, 4, 30))

      expect(candidate.reload.notified_on).to eq(org.today)
      expect(notifications_for(user, :absence_candidate).count).to eq(1)
      expect(notifications_for(manager, :absence_candidate).count).to eq(1)
    end

    it "本人の今日が非稼働日 → 通知せず notified_on は nil のまま（次稼働日 deferral）" do
      holiday_calendar(org.today)
      user = create(:user)
      candidate = create(:absence_candidate, user:, target_date: target, notified_on: nil)

      described_class.call(date: Date.new(2026, 4, 30))

      expect(candidate.reload.notified_on).to be_nil
      expect(notifications_for(user, :absence_candidate).count).to eq(0)
    end

    it "notify-once: notified_on 済の候補は再通知しない" do
      working_calendar(org.today)
      user = create(:user)
      create(:absence_candidate, user:, target_date: target, notified_on: org.today - 3)

      expect { described_class.call(date: Date.new(2026, 4, 30)) }
        .not_to change { notifications_for(user, :absence_candidate).count }
    end
  end

  describe "#call 次稼働日送達（travel_to 多段・§10⑧）" do
    let(:target) { Date.new(2026, 6, 5) } # 検知済み候補の対象日

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "休日 run では notify されず、次の稼働日 run で初めて notified_on が入る" do
      user = create(:user)
      candidate = create(:absence_candidate, user:, target_date: target, notified_on: nil)
      holiday_calendar(Date.new(2026, 6, 6)) # 土曜相当（org TZ=UTC ゆえ org.today = この日）
      working_calendar(Date.new(2026, 6, 8)) # 月曜相当

      # run 1: 休日 → notify されない
      travel_to(Time.utc(2026, 6, 6, 2)) do
        described_class.call(date: Date.new(2026, 6, 5))
      end
      expect(candidate.reload.notified_on).to be_nil

      # run 2: 稼働日 → notified_on 設定
      travel_to(Time.utc(2026, 6, 8, 2)) do
        described_class.call(date: Date.new(2026, 6, 7))
      end
      expect(candidate.reload.notified_on).to eq(Date.new(2026, 6, 8))
    end
  end
```

- [ ] **Step 5: per-user rescue + テナント越境ゼロのテストを追記**

同 spec の末尾に追加:

```ruby
  describe "#call 堅牢性・分離" do
    let(:prev_day) { Date.new(2026, 5, 1) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    before { create(:company_calendar, date: prev_day, day_type: :weekday, name: "平日") }

    it "1 ユーザーの例外でテナント全体の検知を落とさない（§10⑦ per-user rescue）" do
      good = create(:user)
      bad = create(:user)
      # bad の候補生成時のみ Notifier ではなく候補 upsert 前段で例外化するため、
      # AttendanceRecord.find_by を bad のみ raise させる
      allow(AttendanceRecord).to receive(:find_by).and_call_original
      allow(AttendanceRecord).to receive(:find_by)
        .with(user_id: bad.id, work_date: prev_day).and_raise(StandardError, "boom")

      expect { described_class.call(date: prev_day) }.not_to raise_error
      # good の欠勤候補は生成される（bad は skip）
      expect(AbsenceCandidate.where(user: good, target_date: prev_day).count).to eq(1)
    end

    it "テナント越境ゼロ: 他社の候補/通知に触れない（§10⑧）" do
      org_b = create(:organization, time_zone: "UTC")
      b_user = nil
      b_candidate = nil
      ActsAsTenant.with_tenant(org_b) do
        b_user = create(:user)
        b_candidate = create(:absence_candidate, user: b_user, target_date: prev_day, notified_on: nil)
        create(:company_calendar, date: org_b.today, day_type: :weekday, name: "平日")
      end

      # org（A）文脈で検知を実行
      described_class.call(date: prev_day)

      # B の候補は notified_on nil のまま・B ユーザー宛通知は 0（with_tenant 除去で落ちる向き）
      ActsAsTenant.with_tenant(org_b) do
        expect(b_candidate.reload.notified_on).to be_nil
        expect(Notification.where(target_user: b_user).count).to eq(0)
      end
    end
  end
```

- [ ] **Step 6: 全テストを通す**

Run: `bundle exec rspec spec/services/attendance_anomalies/detect_spec.rb`
Expected: 全 PASS（pass 1 / pass 2 / 次稼働日 / 堅牢性・分離）。

- [ ] **Step 7: rubocop**

Run: `bundle exec rubocop --force-exclusion app/services/attendance_anomalies/detect.rb spec/services/attendance_anomalies/detect_spec.rb`
Expected: 0 offenses。

- [ ] **Step 8: Commit**

```bash
git add app/services/attendance_anomalies/detect.rb spec/services/attendance_anomalies/detect_spec.rb
git commit -m "feat: AttendanceAnomalies::Detect（前日検知/欠勤候補upsert/次稼働日notify・per-user rescue・越境ゼロ）"
```

---

## Task 4: ディスパッチャ + 子ジョブ + recurring.yml

**Files:**
- Create: `app/jobs/daily_attendance_job.rb`
- Create: `app/jobs/daily_attendance_tenant_job.rb`
- Modify: `config/recurring.yml`
- Test: `spec/jobs/daily_attendance_job_spec.rb`
- Test: `spec/jobs/daily_attendance_tenant_job_spec.rb`

**Interfaces:**
- Consumes: `AttendanceAnomalies::Detect.call(date:)`（Task 3）/ `Organization.active`（既存）/ `org.today`（既存）。
- Produces: `DailyAttendanceJob`（recurring・引数なし）/ `DailyAttendanceTenantJob.perform_later(organization_id)`。

> 規範は既存 `NotificationDispatchJob`/`NotificationDispatchTenantJob`（§3.6・§9⑪）。子は §11⑪ nil-guard + §3.6 with_tenant。子が渡す検知対象日 = `org.today.prev_day`。

- [ ] **Step 1: ディスパッチャの失敗するテストを書く**

`spec/jobs/daily_attendance_job_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe DailyAttendanceJob, type: :job do
  include ActiveJob::TestHelper

  it "active org ごとに子ジョブを 1 件 enqueue（inactive は除外・§3.6）" do
    org_a = create(:organization)
    org_b = create(:organization)
    inactive = create(:organization, active: false)

    # spec/support/tenant.rb の before が test_tenant を追加するため期待数は動的取得
    expected_count = Organization.active.count

    expect { described_class.perform_now }
      .to have_enqueued_job(DailyAttendanceTenantJob).exactly(expected_count).times

    expect(DailyAttendanceTenantJob).to have_been_enqueued.with(org_a.id)
    expect(DailyAttendanceTenantJob).to have_been_enqueued.with(org_b.id)
    expect(DailyAttendanceTenantJob).not_to have_been_enqueued.with(inactive.id)
  end
end
```

Run: `bundle exec rspec spec/jobs/daily_attendance_job_spec.rb`
Expected: FAIL（`DailyAttendanceJob` 未定義）。

- [ ] **Step 2: ディスパッチャを実装**

`app/jobs/daily_attendance_job.rb`:

```ruby
# frozen_string_literal: true

# 日次バッチのディスパッチャ（設計 §4.1・§3.6）。current_tenant = nil 前提で
# Organization をスコープ外列挙し、子に org_id だけ渡す。既存 NotificationDispatchJob の規範に踏襲。
class DailyAttendanceJob < ApplicationJob
  def perform
    Organization.active.find_each do |org|
      DailyAttendanceTenantJob.perform_later(org.id)
    end
  end
end
```

- [ ] **Step 3: ディスパッチャのテストを通す**

Run: `bundle exec rspec spec/jobs/daily_attendance_job_spec.rb`
Expected: PASS。

- [ ] **Step 4: 子ジョブの失敗するテストを書く**

`spec/jobs/daily_attendance_tenant_job_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe DailyAttendanceTenantJob, type: :job do
  it "with_tenant(org) 内で Detect.call(date: org.today.prev_day) を呼ぶ" do
    org = create(:organization)

    expect(AttendanceAnomalies::Detect).to receive(:call) do |date:|
      expect(date).to eq(org.today.prev_day)
      expect(ActsAsTenant.current_tenant).to eq(org) # §3.6 テナント文脈内
    end

    described_class.perform_now(org.id)
  end

  it "org 削除済み（nil）なら何もしない（§11⑪ 削除レース耐性）" do
    expect(AttendanceAnomalies::Detect).not_to receive(:call)
    expect { described_class.perform_now(-1) }.not_to raise_error
  end
end
```

Run: `bundle exec rspec spec/jobs/daily_attendance_tenant_job_spec.rb`
Expected: FAIL（`DailyAttendanceTenantJob` 未定義）。

- [ ] **Step 5: 子ジョブを実装**

`app/jobs/daily_attendance_tenant_job.rb`:

```ruby
# frozen_string_literal: true

# ディスパッチャの子（設計 §4.1・§3.6・§11⑪）。with_tenant で当該テナントの前日分を検知する。
class DailyAttendanceTenantJob < ApplicationJob
  def perform(organization_id)
    org = Organization.find_by(id: organization_id)
    return if org.nil? # §11⑪ dispatch→実行間の org 削除レース耐性

    ActsAsTenant.with_tenant(org) do # §3.6 必須（リクエスト文脈なし）
      AttendanceAnomalies::Detect.call(date: org.today.prev_day)
    end
  end
end
```

- [ ] **Step 6: 子ジョブのテストを通す**

Run: `bundle exec rspec spec/jobs/daily_attendance_tenant_job_spec.rb`
Expected: 全 PASS。

- [ ] **Step 7: recurring.yml に登録**

`config/recurring.yml` の `production:` ブロック（既存 `notification_dispatch` の下）に追加:

```yaml
  daily_attendance:
    class: DailyAttendanceJob
    schedule: "at 2am every day"
```

> `daily_batch_hour` は §10④ で削除済ゆえ固定 "2am"。動的スケジュールは将来 Phase。

- [ ] **Step 8: rubocop + ジョブ全テスト**

Run: `bundle exec rubocop --force-exclusion app/jobs/daily_attendance_job.rb app/jobs/daily_attendance_tenant_job.rb spec/jobs/daily_attendance_job_spec.rb spec/jobs/daily_attendance_tenant_job_spec.rb`
Run: `bundle exec rspec spec/jobs/daily_attendance_job_spec.rb spec/jobs/daily_attendance_tenant_job_spec.rb`
Expected: 0 offenses / 全 PASS。

- [ ] **Step 9: Commit**

```bash
git add app/jobs/daily_attendance_job.rb app/jobs/daily_attendance_tenant_job.rb config/recurring.yml spec/jobs/daily_attendance_job_spec.rb spec/jobs/daily_attendance_tenant_job_spec.rb
git commit -m "feat: DailyAttendanceJob ディスパッチャ→子（with_tenant・nil-guard）+ recurring daily_attendance"
```

---

## 仕上げ（全タスク後）

1. **全スイート + 静的検証**:
   - `bundle exec rspec`（全緑・既存 pending は Approvals 自己承認 #2 のみ）
   - `bundle exec rubocop --force-exclusion $(git diff --name-only main...HEAD | grep '\.rb$')`
   - `bin/brakeman --no-pager`（app/ 変更ゆえ）
2. **マージ前レビュアー**: `tenant-isolation-reviewer`（ディスパッチャ→子のテナント反復・insert_all の org_id 明示・Detect のテナント scoping）。※本スライスは ApplyApproval / 状態 enum に触れないため approval-engine は不要（§11 P2 の導出規則: touch 面から判定）。
3. **ROADMAP**: 4-2 行に「4-2b 検知バッチ ✅ PR #<番号>」を追記。
4. **RAILS_GOTCHAS 還流**: 新たに踏んだ罠（例: insert_all の timestamps 明示要・travel_to × org TZ の today 決定化）があれば本 PR で追記。

## Self-Review（writing-plans 規約）

- **Spec coverage（設計 §4 + §10 + §11）**:
  - §4.1 ジョブ構造（ディスパッチャ→子）= Task 4 / recurring.yml = Task 4。
  - §4.2① 退勤忘れ（本人・即時・夜勤除外）= Detector.clock_out_missing?(Task 2) + Detect notify_clock_out_missing(Task 3)。
  - §4.2② 欠勤候補 / 休暇申請中無打刻 = Detector.no_clock_anomaly(Task 2) + Detect(Task 3)。
  - §4.3 候補 resolve = Detect#covered?(Task 3)。§4.4 次稼働日 notify-once = Detect#process_candidates(Task 3・travel_to テスト)。
  - §10① 即時通知（稼働日ゲート無）= Task 3「非稼働日でも即時発火」テスト。§10③ PORO/Service 分離 = Task 2/3。§10⑦ per-user rescue = Task 3 テスト。§10⑨ insert_all = Task 3。§10⑪ 夜勤除外 = Task 2/3。
  - §11⑤ insert_all org_id 明示 = candidate_row。§11⑧ notify-once 順序 = notify_candidate（本人→notified_on→管理者）。§11⑪ nil-guard = Task 4 子ジョブ。corrigenda User.active = Task 1。
  - §10⑤ 猶予・§10②IDOR・§5 欠勤確定・§6 インターバルは 4-2c/4-2d（本スライス対象外）。
- **Placeholder scan**: 全コードは実コード。PR 番号のみ後埋め（明示）。
- **Type consistency**: `Detector.clock_out_missing?`/`no_clock_anomaly`（Task2 定義 → Task3 が同名・同引数で呼ぶ）/ `Detect.call(date:)`（Task3 定義 → Task4 が呼ぶ）/ `User.active`（Task1 → Task4 ディスパッチャ）/ `covering_leave_requests`（Detect 内・start_date..date & end_date..date）/ `Notifier.call` 引数（既存 signature と一致：target_user/title/body/priority/source_type/subject_user）/ source_type 値（clock_out_missing・absence_candidate・leave_pending_no_clock は 4-2a で append 済）/ `Notifier::HOLIDAY_DAY_TYPES`（既存定数参照）— 整合確認済。
- **既知の非対象（設計の意図どおり・非バグ）**: AR 無 ∧ LR が却下/取消/撤回のみの日は候補にも管理者通知にもならない（§4.2 の 2 分類 + §10 是認「LR 全 status 除外」の帰結）。将来 Phase で必要なら再検討。
