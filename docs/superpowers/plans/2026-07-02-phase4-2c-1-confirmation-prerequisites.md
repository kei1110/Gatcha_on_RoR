# Phase 4-2c-1 欠勤確定の前提整備（merge-blocker）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 4-2c 欠勤確定 UI が absent AR を作れるようにする前提を先に固める — 欠勤日への事後有給承認（absent→on_leave 上書き）が 4-2a の `absence_reason_only_on_absent` 検証で承認 tx ごと rollback する merge-blocker（§11①/§12②）を、随伴列クリア + `absence_to_paid` 監査 + DB CHECK backstop で解消する。

**Architecture:** 3 層で固める — ① `AttendanceHistory` の actor 必須検証を absence_confirmed/absence_to_paid に拡張（監査の穴埋め）② `absence_reason` の DB CHECK 制約（`leave_type` 対称の二層防御・§3.6）③ `LeaveRequests::ApplyApproval` の absent→on_leave 上書きで**遷移前 status を捕捉**してから随伴列クリア + `absence_to_paid` 記録。UI・controller は 4-2c-2。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / acts_as_tenant / RSpec。

**設計 SSOT:** `docs/superpowers/specs/2026-06-28-phase4-2-daily-batch-design.md` の **§11①②⑤ + §12②⑥**（§10/§11/§12 は §2〜§9 を上書き）。SPEC は §6.2 L808（absent→on_leave は absence_to_paid 記録）/ §13.1（absent 非終端）。

## Global Constraints（§11/§12 binding・全タスクに適用）

- **§12②（最重要・silent no-op の罠）**: `ApplyApproval#upsert_attendance_records` は `record.status = leave_status` を**代入する前**に `was_absent = record.absent?` を捕捉せよ。代入後に `absent?` を見ると常に false → クリアも absence_to_paid も無言 no-op → RecordInvalid 依然で「fix したのに承認 rollback」になる。
- **§11①/§12⑥**: `was_absent` 時のみ `record.absence_reason = nil` / `record.note = nil` をクリアしてから `save!`。かつ `AttendanceHistory(absence_to_paid)` を `previous_status: <absent 整数>` 保持で記録。**`was_absent` が false の upsert は note/absence_reason を触らない**（半休を打刻済日に上書きする既存経路の legit な note を消さない・§12⑤）。
- **§12⑥ DB backstop**: `absence_reason` の DB CHECK `absence_reason IS NULL OR status = 5`（`leave_type_id IS NULL OR status IN (2,3,4)` と対称・名 `attendance_records_absence_reason_only_on_absent`）。`AttendanceHistory` に `validates :actor_id, presence: true, if: :absence_confirmed?` と `if: :absence_to_paid?`（既存 leave_approved 等と同型・append 位置）。
- **absent の enum 整数 = 5**（`app/models/attendance_record.rb:17`・凍結予約）。`absence_to_paid` = event_type 6・`absence_confirmed` = 5（既存 taxonomy・追加不要）。
- **回帰は実 ApplyApproval.call（stub 不可・§12②）**: `save!`/検証を stub せず、実の absent AR を作って `LeaveRequests::ApplyApproval.call` を呼ぶ（これが Approvals::Approve の with_lock 内で実行される実効果コード）。
- schema は migration 経由のみ（`block-schema-edit` フック）。`bin/rails db:migrate && db:test:prepare`。`db/queue_schema.rb` の mtime ノイズは `git add` しない。
- **検証**: 各タスク完了条件に `bundle exec rspec <該当>` / `bundle exec rubocop --force-exclusion <files>`。**マージ前レビュアー（§11 P2 導出規則）**: models/migration ゆえ `tenant-isolation-reviewer`・**ApplyApproval（承認副作用）に触れるゆえ `approval-engine-reviewer`**。app/ 変更ゆえ仕上げで `bin/brakeman --no-pager`。
- 到達面なし（§1.4 行なし・データ/サービス層）。

## File Structure

| ファイル | 責務 | タスク |
|----------|------|--------|
| `app/models/attendance_history.rb`（変更） | actor 必須検証を absence_confirmed/absence_to_paid に拡張 | 1 |
| `db/migrate/*_add_absence_reason_check_to_attendance_records.rb` | `absence_reason` DB CHECK（leave_type 対称） | 2 |
| `app/services/leave_requests/apply_approval.rb`（変更） | absent→on_leave の exit クリア + absence_to_paid（遷移前 status 捕捉） | 3 |

---

## Task 1: AttendanceHistory の actor 必須検証を absence_confirmed / absence_to_paid に拡張

**Files:**
- Modify: `app/models/attendance_history.rb`
- Test: `spec/models/attendance_history_spec.rb`

**Interfaces:**
- Consumes: 既存 `AttendanceHistory`（event_type enum に absence_confirmed:5 / absence_to_paid:6 既存・actor optional）。
- Produces: absence_confirmed / absence_to_paid の history は `actor_id` 必須（Task 3 の absence_to_paid 記録・4-2c-2 の absence_confirmed 記録が満たす）。

> §12⑥: 監査の穴埋め。既存は proxy_clock/leave_approved/clock_change_approved/leave_withdrawn/clock_change_withdrawn に actor 必須（`attendance_history.rb:24-28`）。absence_confirmed/absence_to_paid は actor 抜けを許していた（§3.5 操作者記録の欠落）。

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/attendance_history_spec.rb` に追加（テナント文脈・既存 describe 群の末尾）:

```ruby
  describe "actor 必須（absence_confirmed / absence_to_paid・§12⑥）" do
    let(:org) { create(:organization) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "absence_confirmed は actor 無しで無効" do
      h = build(:attendance_history, user: create(:user), actor: nil,
                                     event_type: :absence_confirmed, event_date: Date.new(2026, 5, 1))
      expect(h).to be_invalid
      expect(h.errors[:actor_id]).to be_present
    end

    it "absence_to_paid は actor 無しで無効" do
      h = build(:attendance_history, user: create(:user), actor: nil,
                                     event_type: :absence_to_paid, event_date: Date.new(2026, 5, 1))
      expect(h).to be_invalid
      expect(h.errors[:actor_id]).to be_present
    end

    it "actor があれば有効（absence_to_paid）" do
      u = create(:user)
      h = build(:attendance_history, user: u, actor: create(:user),
                                     event_type: :absence_to_paid, event_date: Date.new(2026, 5, 1),
                                     previous_status: AttendanceRecord.statuses[:absent],
                                     new_status: AttendanceRecord.statuses[:on_leave])
      expect(h).to be_valid
    end
  end
```

Run: `bundle exec rspec spec/models/attendance_history_spec.rb -e "actor 必須（absence_confirmed"`
Expected: FAIL（検証未追加ゆえ actor nil でも valid）。

> factory 前提: `spec/factories/attendance_histories.rb` は `organization`（tenant 既定）/ `user` / `event_type`（既定 proxy_clock 等）/ `event_date` を持つ。無ければ本タスクで最小 factory を足す（`actor { nil }` 既定・上書き可）。実行して factory 不足が出たら BLOCKED でなく factory を補ってから進める。

- [ ] **Step 2: 検証を追加**

`app/models/attendance_history.rb` の actor 必須検証群（`clock_change_withdrawn?` の行の直後）に追加:

```ruby
  validates :actor_id, presence: true, if: :absence_confirmed?  # 4-2c 欠勤確定（§12⑥・不変ゆえ事前防御）
  validates :actor_id, presence: true, if: :absence_to_paid?    # 4-2c 事後有給振替（§12⑥）
```

- [ ] **Step 3: テストを通す**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb`
Expected: 全 PASS（新規 3 例 + 既存回帰なし）。

- [ ] **Step 4: rubocop**

Run: `bundle exec rubocop --force-exclusion app/models/attendance_history.rb spec/models/attendance_history_spec.rb`
Expected: 0 offenses。

- [ ] **Step 5: Commit**

```bash
git add app/models/attendance_history.rb spec/models/attendance_history_spec.rb spec/factories/attendance_histories.rb
git commit -m "feat: AttendanceHistory actor 必須を absence_confirmed/absence_to_paid に拡張（§12⑥ 監査）"
```

---

## Task 2: absence_reason の DB CHECK 制約（leave_type 対称・§12⑥）

**Files:**
- Create: `db/migrate/<ts>_add_absence_reason_check_to_attendance_records.rb`
- Test: `spec/models/attendance_record_spec.rb`

**Interfaces:**
- Consumes: 既存 `attendance_records`（`absence_reason` 列・model 検証 `absence_reason_only_on_absent`）。
- Produces: DB CHECK `absence_reason IS NULL OR status = 5` — Task 3 の exit クリアを DB が強制（clear 忘れ時 raise = backstop）。4-2c-2 の一括確定が仮に検証 skip 経路を通っても DB が防ぐ。

> §12⑥: `leave_type` は model + DB CHECK の二層。`absence_reason` は model-only だった（`schema.rb:115` に leave_type CHECK・absence_reason CHECK 無し）。対称化して二層防御。既存の absent AR は存在しない（4-2c-2 まで writer なし）ゆえ制約追加は既存行を壊さない。

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/attendance_record_spec.rb` の absent describe 群に追加（DB CHECK ゆえ検証を skip して DB を突く）:

```ruby
    it "非 absent status に absence_reason 残置は DB CHECK が拒否（model 検証を貫通・§12⑥）" do
      user = create(:user)
      ar = build(:attendance_record, user:, status: :on_leave, clock_in: nil,
                                     leave_type: create(:leave_type))
      ar.absence_reason = :unauthorized # 本来 model 検証で invalid だが save(validate:false) で DB を突く
      expect { ar.save!(validate: false) }.to raise_error(ActiveRecord::StatementInvalid, /absence_reason/)
    end

    it "absent + absence_reason は DB CHECK を通る" do
      user = create(:user)
      ar = build(:attendance_record, user:, status: :absent, absence_reason: :illness, clock_in: nil)
      expect { ar.save!(validate: false) }.not_to raise_error
    end
```

Run: `bundle exec rspec spec/models/attendance_record_spec.rb -e "DB CHECK"`
Expected: FAIL（CHECK 未追加ゆえ save 成功・raise しない）。

- [ ] **Step 2: migration を生成して body を差し替え**

```bash
bin/rails generate migration AddAbsenceReasonCheckToAttendanceRecords
```
body を全置換（`leave_type` CHECK と対称・§3.6 DB 最終防衛）:

```ruby
# frozen_string_literal: true

class AddAbsenceReasonCheckToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    # §12⑥ leave_type CHECK 対称の二層防御。absence_reason は status=absent(5) の時のみ非 null。
    # 既存 absent AR は無い（4-2c-2 まで writer なし）ゆえ validate なしでも既存行に非違反。
    add_check_constraint :attendance_records,
                         "absence_reason IS NULL OR status = 5",
                         name: "attendance_records_absence_reason_only_on_absent"
  end
end
```

- [ ] **Step 3: migrate**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `db/schema.rb` に `attendance_records_absence_reason_only_on_absent` の check_constraint が追記される。

- [ ] **Step 4: テストを通す**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb`
Expected: 全 PASS（新規 DB CHECK 2 例 + 既存回帰なし）。

- [ ] **Step 5: rubocop**

Run: `bundle exec rubocop --force-exclusion db/migrate spec/models/attendance_record_spec.rb`
Expected: 0 offenses。

- [ ] **Step 6: Commit**

```bash
git add db/migrate db/schema.rb spec/models/attendance_record_spec.rb
git commit -m "feat: absence_reason DB CHECK（leave_type 対称の二層防御・§12⑥ backstop）"
```

---

## Task 3: ApplyApproval の absent→on_leave exit クリア + absence_to_paid（§11①/§12②⑥）

**Files:**
- Modify: `app/services/leave_requests/apply_approval.rb`
- Test: `spec/services/leave_requests/apply_approval_spec.rb`

**Interfaces:**
- Consumes: `AttendanceHistory` actor 必須（Task 1）/ `absence_reason` DB CHECK（Task 2）/ 既存 `LeaveDaysCalculator.counted_dates` / `CompanyCalendarResolver#day_classifications`。
- Produces: absent AR を覆う休暇承認が `RecordInvalid` を起こさず on_leave へ昇格し `absence_reason=nil`・`AttendanceHistory(absence_to_paid)` を記録（4-2c-2 欠勤確定 → 事後有給の実動線を成立させる）。

> **§12②（最重要）**: `record.status = leave_status` の**前**に `was_absent = record.absent?` を捕捉。代入後だと常に false で silent no-op。**§12⑤**: `was_absent` false の upsert は note を触らない（半休打刻済上書きの legit note を保全）。

- [ ] **Step 1: 失敗する回帰テストを書く**

`spec/services/leave_requests/apply_approval_spec.rb` に describe 追加（既存の `apply`/`leave`/`unpaid_type`/`start_date` ヘルパを流用）:

```ruby
  describe "absent→on_leave 事後有給の上書き（§11①/§12②⑥）" do
    it "既存 absent AR を覆う承認は on_leave へ昇格し absence_reason をクリア（RecordInvalid を起こさない）" do
      create(:attendance_record, user:, work_date: start_date, status: :absent,
                                 absence_reason: :unauthorized, clock_in: nil, note: "調査中")

      expect { apply(leave(type: unpaid_type, sd: start_date, ed: start_date)) }.not_to raise_error

      ar = AttendanceRecord.find_by(user_id: user.id, work_date: start_date)
      expect(ar.status).to eq("on_leave")
      expect(ar.absence_reason).to be_nil
      expect(ar.note).to be_nil
    end

    it "absent→on_leave 時に AttendanceHistory(absence_to_paid) を previous_status: absent で記録" do
      create(:attendance_record, user:, work_date: start_date, status: :absent,
                                 absence_reason: :illness, clock_in: nil)

      apply(leave(type: unpaid_type, sd: start_date, ed: start_date))

      h = AttendanceHistory.find_by(user_id: user.id, event_type: :absence_to_paid, event_date: start_date)
      expect(h).to be_present
      expect(h.actor_id).to eq(approver.id)
      expect(h.previous_status).to eq(AttendanceRecord.statuses[:absent])
      expect(h.new_status).to eq(AttendanceRecord.statuses[:on_leave])
    end

    it "absent でない日（新規 on_leave 作成）は absence_to_paid を記録しない" do
      apply(leave(type: unpaid_type, sd: start_date, ed: start_date))

      expect(AttendanceHistory.where(event_type: :absence_to_paid).count).to eq(0)
    end
  end
```

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb -e "absent→on_leave"`
Expected: FAIL（1 例目が `ActiveRecord::RecordInvalid`＝absence_reason 残置で `absence_reason_only_on_absent` 発火・2 例目は absence_to_paid 未記録）。

- [ ] **Step 2: `upsert_attendance_records` を修正し `record_absence_to_paid` を追加**

`app/services/leave_requests/apply_approval.rb` の `upsert_attendance_records` を差し替え、private に `record_absence_to_paid` を追加:

```ruby
    def upsert_attendance_records
      classifications = CompanyCalendarResolver.new(organization: @leave_request.organization)
                                               .day_classifications(@leave_request.start_date,
                                                                    @leave_request.end_date)
      LeaveDaysCalculator.counted_dates(classifications).each do |date|
        record = AttendanceRecord.find_or_initialize_by(
          user_id: @leave_request.requester_id, work_date: date
        )
        was_absent = record.absent? # §12② 遷移前 status を代入前に捕捉（silent no-op 回避）
        record.status = leave_status
        record.leave_type_id = @leave_request.leave_type_id
        if was_absent
          record.absence_reason = nil # §11① 随伴列クリア（DB CHECK と整合）
          record.note = nil
        end
        record.save!
        record_absence_to_paid(record, date) if was_absent # §12⑥ 監査（absent→on_leave の痕跡）
        recalculate(record)
      end
    end
```

private に追加（`record_history` の直後）:

```ruby
    # absent→on_leave（事後有給）の監査（SPEC §6.2 L808・§12⑥）。actor 必須（Task 1）。
    def record_absence_to_paid(record, date)
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id,
        actor: @acting_user,
        source: @leave_request,
        event_type: :absence_to_paid,
        event_date: date,
        previous_status: AttendanceRecord.statuses[:absent],
        new_status: AttendanceRecord.statuses[record.status]
      )
    end
```

- [ ] **Step 3: 回帰テストを通す**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb`
Expected: 全 PASS（新規 3 例 + 既存回帰なし）。

- [ ] **Step 4: rubocop**

Run: `bundle exec rubocop --force-exclusion app/services/leave_requests/apply_approval.rb spec/services/leave_requests/apply_approval_spec.rb`
Expected: 0 offenses。

- [ ] **Step 5: Commit**

```bash
git add app/services/leave_requests/apply_approval.rb spec/services/leave_requests/apply_approval_spec.rb
git commit -m "fix: absent→on_leave 承認の exit クリア + absence_to_paid 記録（§11①/§12② merge-blocker 解消）"
```

---

## 仕上げ（全タスク後）

1. **全スイート + 静的検証**:
   - `bundle exec rspec`（全緑・既存 pending は Approvals 自己承認 #2 のみ）
   - `bundle exec rubocop --force-exclusion $(git diff --name-only main...HEAD | grep '\.rb$')`
   - `bin/brakeman --no-pager`（app/ 変更ゆえ）
2. **マージ前レビュアー**: `tenant-isolation-reviewer`（AttendanceHistory/AR の検証・migration）+ **`approval-engine-reviewer`**（ApplyApproval の承認副作用 tx・absent→on_leave 遷移の随伴列整合・§11①）。
3. **設計書に本ブランチを含める**: `docs/superpowers/plans/2026-07-02-phase4-2c-1-confirmation-prerequisites.md` を本 PR に同梱。§12 は既に main（4-2c ブランチ起点に含む）。
4. **ROADMAP**: 4-2 行に「4-2c-1 確定前提整備 ✅ PR #<番号>」を追記（4-2c-2 が後続）。
5. **RAILS_GOTCHAS 還流**: §12② の罠（enum 排他検証の随伴列クリアは**遷移前 status を代入前に捕捉**せよ・代入後は述語が silent no-op）を既存「enum 排他検証 × 遷移随伴列クリア漏れ」項に追記（実装で実踏したため）。

## Self-Review（writing-plans 規約）

- **Spec coverage（§11①②⑤ + §12②⑤⑥）**: AttendanceHistory actor 検証（absence_confirmed/absence_to_paid）=Task1 / absence_reason DB CHECK（leave_type 対称）=Task2 / ApplyApproval exit クリア（遷移前 status 捕捉・§12②）+ note 保全（§12⑤）+ absence_to_paid（previous_status 保持・§12⑥）=Task3。§11①③④⑥⑦⑧⑨⑩・§12①③④⑤⑦⑧⑨⑩ は 4-2c-2（confirm UI）。
- **Placeholder scan**: 全コードは実コード。PR 番号のみ後埋め（明示）。`<ts>` は generate が確定。factory 不足時の補填を Task1 に明記。
- **Type consistency**: `was_absent`（Task3・代入前捕捉）/ `record_absence_to_paid(record, date)`（Task3 定義）/ `AttendanceHistory.statuses`… は `AttendanceRecord.statuses[:absent]`=5・`[record.status]`（Task3・Task1 factory 例と一致）/ DB CHECK `status = 5`（absent 整数・Task2）/ actor 必須検証 `if: :absence_to_paid?`（Task1 → Task3 の create! が満たす）— 整合確認済。
- **依存順**: Task1（actor 検証）→ Task2（DB CHECK）→ Task3（absence_to_paid は Task1 の actor 必須を満たし・exit クリアは Task2 の CHECK を満たす）。順序が正しく回る。
- **回帰の実効性**: Task3 の 1 例目は fix 前に実 `ActiveRecord::RecordInvalid` を出す（stub なし・実 save!）。fix がクリアを status 代入後に置く silent no-op 実装だと 1 例目が依然 RecordInvalid で落ちる＝§12② の罠を検出できる判別テスト。
