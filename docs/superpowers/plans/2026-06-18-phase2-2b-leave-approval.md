# Phase 2-2b 承認 + 副作用 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 休暇申請の承認が、対象日の勤怠記録・残高・監査履歴へ atomic に反映され、承認者がインボックスから承認/却下できるようにする。

**Architecture:** 汎用 `Approvals::Approve` エンジンが最終承認時に host の `apply_approval_effects!` hook を呼び、`LeaveRequests::ApplyApproval` が同一トランザクション内で「残高 `lock!` 加算（不足はハード拒否）→ per-day AttendanceRecord upsert（on_leave / 半休）→ LateEarly 再計算 → AttendanceHistory 記録」を実行する。内側で rescue せず、残高不足は raise 伝播させ承認ごと巻き戻す（all-or-nothing）。承認インボックスは型非依存 `ApprovalAssignmentPolicy::Scope` + approvable_type 別描画で CCR/HWR(2-3/2-4) に前方互換。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / acts_as_tenant / Pundit / AASM / ViewComponent / Hotwire / RSpec + FactoryBot / rubocop / brakeman

**設計典拠:** `docs/superpowers/specs/2026-06-18-phase2-2b-leave-approval-side-effects-design.md`（D1–D6・§1–§8）

## Global Constraints

- **Git identity:** コミットは `kei1110 <eoh2145@gmail.com>`（local config 済）。ステップ完了ごとに即コミット。コミットメッセージ末尾に `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。
- **検証コマンド:** 各タスク完了時 `bundle exec rspec <該当 spec>` 緑 → `bundle exec rubocop --force-exclusion <触れたファイル>`（**ファイル明示時は必ず `--force-exclusion`**・偽 FAIL 回避）。app/ 変更タスクは `bin/brakeman --no-pager`。
- **テナント文脈:** `acts_as_tenant` 越境ガードは **ID 基点 fail-closed**（`*_id.nil?` early return → association 比較）。`record.nil?` early return は fail-open ゆえ禁止。console/rake は先頭で `ActsAsTenant.current_tenant = Organization.find_by!(subdomain: "...")`。
- **スキーマ:** `db/schema.rb` を手編集しない（`block-schema-edit` フック）。変更は migration 経由のみ。
- **AASM:** `approval_status` は AASM イベント（`approve!` 等）でのみ遷移。`update_column`/`update_all` で直接代入しない。
- **`used_days` の唯一 writer = `LeaveRequests::ApplyApproval`**（2-2a 宣言）。他経路から書かない。
- **`AttendanceHistory` は追記専用**（`create!` のみ・update/destroy は不変防御が拒否）。
- **副作用は同一 tx・内側 rescue なし**（残高不足は raise 伝播 → atomic rollback。2-2a §10 の「rescue 握り潰し → 偽 success + 更新消失」罠を構造回避）。

---

## File Structure

| ファイル | 責務 |
|---|---|
| `db/migrate/*_allow_null_clock_in_on_attendance_records.rb` | `clock_in` の DB NOT NULL を解除（leave AR は打刻無） |
| `app/models/attendance_record.rb` | status enum 拡張（on_leave/morning_half/afternoon_half）+ clock_in 条件付き検証 |
| `app/models/attendance_history.rb` | `leave_approved` の actor_id 必須 |
| `app/models/concerns/approvable.rb` | no-op hook `apply_approval_effects!` + `single_stage?` + `pending_approver` |
| `app/models/leave_request.rb` | `apply_approval_effects!` 実装（ApplyApproval へ委譲） |
| `app/services/approvals.rb` | `OverBalanceError` 追加 |
| `app/services/approvals/approve.rb` | 最終承認時に hook 呼び出し（1 行） |
| `app/services/clockings/recalculate.rb` | `day_part` を status 由来導出 |
| `app/calculators/leave_days_calculator.rb` | `counted_dates` 公開抽出（DRY・ApplyApproval と共有） |
| `app/services/leave_requests/apply_approval.rb` | 副作用本体（残高・AR upsert・recalc・history） |
| `app/policies/approval_assignment_policy.rb` | `Scope` + `index?` |
| `app/controllers/approval_assignments_controller.rb` | インボックス index/approve/reject |
| `app/components/approvals/leave_request_row_component.{rb,html.erb}` | LeaveRequest 行の描画 |
| `app/views/approval_assignments/index.html.erb` | 型別 dispatch の一覧 |
| `config/routes.rb` | `resources :approval_assignments`（index + member approve/reject） |
| `docs/ROADMAP.md` / `docs/RAILS_GOTCHAS.md` | 2-2b 行更新・バックログ・罠台帳 |

---

## Task 1: AttendanceRecord に leave status を表現可能にする

**Files:**
- Create: `db/migrate/<timestamp>_allow_null_clock_in_on_attendance_records.rb`
- Modify: `app/models/attendance_record.rb`
- Test: `spec/models/attendance_record_spec.rb`

**Interfaces:**
- Produces: `AttendanceRecord` の `status` enum に `morning_half:2 / afternoon_half:3 / on_leave:4`、述語 `leave_status?`、定数 `LEAVE_STATUSES`。leave status の AR は `clock_in` nil 可、working/clocked_out は必須。

- [ ] **Step 1: 失敗するモデル spec を追記**

`spec/models/attendance_record_spec.rb` の末尾（最後の `end` の前）に追加:

```ruby
  describe "leave status（2-2b）" do
    around { |ex| ActsAsTenant.with_tenant(create(:organization)) { ex.run } }

    it "on_leave / morning_half / afternoon_half は clock_in nil でも valid" do
      %i[on_leave morning_half afternoon_half].each do |st|
        record = build(:attendance_record, status: st, clock_in: nil)
        expect(record).to be_valid, "#{st} は clock_in nil で valid のはず: #{record.errors.full_messages}"
      end
    end

    it "working / clocked_out は clock_in nil なら invalid（条件付き presence 維持）" do
      record = build(:attendance_record, status: :working, clock_in: nil)
      expect(record).to be_invalid
      expect(record.errors[:clock_in]).to be_present
    end

    it "新 enum 3 値が登録済み" do
      expect(AttendanceRecord.statuses).to include(
        "morning_half" => 2, "afternoon_half" => 3, "on_leave" => 4
      )
    end
  end
```

- [ ] **Step 2: spec を実行して fail を確認**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb -e "leave status"`
Expected: FAIL（`on_leave` が未知 enum で invalid＝1 例目が落ちる／`statuses` に 2-4 が無い／clock_in NOT NULL）

- [ ] **Step 3: マイグレーションを生成して clock_in の NOT NULL を解除**

Run: `bin/rails g migration allow_null_clock_in_on_attendance_records`

生成ファイルを以下に編集:

```ruby
# frozen_string_literal: true

# 全休/半休の AttendanceRecord は打刻が無いため clock_in の DB NOT NULL を解除（2-2b 設計 §2.1）。
# working/clocked_out の必須はモデルの条件付き presence が引き継ぐ二層構成。
class AllowNullClockInOnAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    change_column_null :attendance_records, :clock_in, true
  end
end
```

- [ ] **Step 4: マイグレーション適用**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: 成功。`db/schema.rb` の `clock_in` から `null: false` が消える。

- [ ] **Step 5: モデルを編集（enum 拡張 + 条件付き検証）**

`app/models/attendance_record.rb`:

`enum :status, { working: 0, clocked_out: 1 }, validate: true` を置換:

```ruby
  # 整数は §4.8 列挙順の予約どおり（absent:5 は 4-2）。
  enum :status, { working: 0, clocked_out: 1,
                  morning_half: 2, afternoon_half: 3, on_leave: 4 }, validate: true

  # 全休/半休 AR は打刻が無い（休暇承認の副作用が作成・2-2b）。working/clocked_out は従来必須。
  LEAVE_STATUSES = %w[morning_half afternoon_half on_leave].freeze
```

そして `validates :clock_in, presence: true` を以下に置換:

```ruby
  validates :clock_in, presence: true, unless: :leave_status?
```

`private` 直後に述語を追加:

```ruby
  def leave_status? = LEAVE_STATUSES.include?(status)
```

- [ ] **Step 6: spec を実行して pass を確認**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb`
Expected: PASS（既存 example も含め緑）

- [ ] **Step 7: rubocop + コミット**

```bash
bundle exec rubocop --force-exclusion app/models/attendance_record.rb db/migrate
git add app/models/attendance_record.rb db/migrate spec/models/attendance_record_spec.rb db/schema.rb
git commit -m "$(cat <<'EOF'
feat: AttendanceRecord に leave status（on_leave/半休）+ clock_in 条件付き検証

休暇承認の副作用が作る打刻無 AR を表現可能にする。clock_in の DB NOT NULL を
解除し、working/clocked_out のみモデルで必須に。status enum を予約整数 2-4 へ拡張。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: AttendanceHistory の leave_approved に actor を必須化

**Files:**
- Modify: `app/models/attendance_history.rb`
- Test: `spec/models/attendance_history_spec.rb`

**Interfaces:**
- Produces: `event_type: :leave_approved` の `AttendanceHistory` は `actor_id` 必須（不変ゆえ事前防御）。

- [ ] **Step 1: 失敗する spec を追記**

`spec/models/attendance_history_spec.rb` の末尾の `end` 前に:

```ruby
  describe "leave_approved の actor 必須（2-2b）" do
    around { |ex| ActsAsTenant.with_tenant(create(:organization)) { ex.run } }

    it "actor 無しの leave_approved は invalid" do
      record = build(:attendance_history, event_type: :leave_approved, actor: nil)
      expect(record).to be_invalid
      expect(record.errors[:actor_id]).to be_present
    end

    it "actor ありの leave_approved は valid" do
      record = build(:attendance_history, event_type: :leave_approved,
                                          actor: create(:user, :manager_role))
      expect(record).to be_valid
    end
  end
```

- [ ] **Step 2: fail を確認**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb -e "leave_approved"`
Expected: FAIL（actor 無しでも valid のため 1 例目が落ちる）

- [ ] **Step 3: モデルに検証を追記**

`app/models/attendance_history.rb` の `validates :actor_id, presence: true, if: :proxy_clock?` の直後:

```ruby
  validates :actor_id, presence: true, if: :leave_approved?  # 2-2b（不変ゆえ事前防御）
```

- [ ] **Step 4: pass を確認**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + コミット**

```bash
bundle exec rubocop --force-exclusion app/models/attendance_history.rb
git add app/models/attendance_history.rb spec/models/attendance_history_spec.rb
git commit -m "$(cat <<'EOF'
feat: AttendanceHistory の leave_approved に actor を必須化（2-2b）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Approvable concern に no-op hook と導出ヘルパを追加

**Files:**
- Modify: `app/models/concerns/approvable.rb`
- Test: `spec/models/concerns/approvable_spec.rb`

**Interfaces:**
- Produces: `Approvable#apply_approval_effects!(acting_user:)`（既定 no-op・nil 返し）、`#single_stage?`（assignment 1 件で true）、`#pending_approver`（現段階 approver・無ければ nil）。

- [ ] **Step 1: 失敗する spec を追記**

`spec/models/concerns/approvable_spec.rb` の末尾 `end` 前に:

```ruby
  describe "副作用 hook と導出ヘルパ（2-2b）" do
    it "apply_approval_effects! は既定 no-op（nil 返し）" do
      expect(host.apply_approval_effects!(acting_user: approver1)).to be_nil
    end

    it "single_stage? は assignment 1 件で true / 2 件で false" do
      add_assignment(position: 1, approver: approver1)
      expect(host.single_stage?).to be true
      add_assignment(position: 2, approver: approver2)
      expect(host.single_stage?).to be false
    end

    it "pending_approver は現段階の approver（stage1 approved 後は stage2）" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      add_assignment(position: 2, approver: approver2)
      expect(host.pending_approver).to eq(approver2)
    end

    it "pending_approver は pending 皆無なら nil" do
      add_assignment(position: 1, approver: approver1, decision: :approved, acted_at: Time.current)
      expect(host.pending_approver).to be_nil
    end
  end
```

- [ ] **Step 2: fail を確認**

Run: `bundle exec rspec spec/models/concerns/approvable_spec.rb -e "副作用 hook"`
Expected: FAIL（`apply_approval_effects!` 等が未定義 = `NoMethodError`）

- [ ] **Step 3: concern にメソッドを追加**

`app/models/concerns/approvable.rb` の `all_stages_approved?` メソッド定義の直後（`end`（module 終端）の前）に:

```ruby
  # 承認確定時の副作用 hook（§13.6 のイベント束縛を service 層で実現）。
  # 既定は no-op。副作用を持つ host（LeaveRequest 等）が override する。
  def apply_approval_effects!(acting_user:) = nil

  # 表示用導出（2-2a 後置・§7.2 縮約の可視化）。assignment 1 件 = 単段縮約。
  def single_stage? = approval_assignments.count == 1

  # 現段階（最小 pending position）の approver。pending 皆無なら nil。
  def pending_approver
    position = current_approval_position
    position && approval_assignments.find_by(position:)&.approver
  end
```

- [ ] **Step 4: pass を確認**

Run: `bundle exec rspec spec/models/concerns/approvable_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + コミット**

```bash
bundle exec rubocop --force-exclusion app/models/concerns/approvable.rb
git add app/models/concerns/approvable.rb spec/models/concerns/approvable_spec.rb
git commit -m "$(cat <<'EOF'
feat: Approvable に副作用 hook（no-op 既定）と single_stage?/pending_approver

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Approve エンジンが最終承認時に hook を呼ぶ

**Files:**
- Modify: `app/services/approvals/approve.rb`
- Test: `spec/services/approvals/approve_spec.rb`

**Interfaces:**
- Consumes: `Approvable#apply_approval_effects!(acting_user:)`（Task 3）、`#all_stages_approved?`。
- Produces: `Approvals::Approve` は最終承認時のみ `approvable.apply_approval_effects!(acting_user: <acting_user>)` を呼ぶ。非最終段階では呼ばない。

- [ ] **Step 1: 失敗する spec を追記**

`spec/services/approvals/approve_spec.rb` の最後の `describe`（"terminal / 残 pending バイパス防止"）の後、最終 `end` の前に:

```ruby
  describe "副作用 hook（2-2b）" do
    it "最終承認時のみ apply_approval_effects! を撃つ（acting_user 付き）" do
      approve(approver: boss) # stage1（非最終）— 撃たない
      expect(host).to receive(:apply_approval_effects!).with(acting_user: dept).once
      approve(approver: dept) # stage2（最終）
    end

    it "非最終段階（stage1）では撃たない" do
      expect(host).not_to receive(:apply_approval_effects!)
      approve(approver: boss)
    end

    it "単段ルートは 1 回の承認で撃つ" do
      top = create(:user, :manager_role, organization: org)
      solo = create(:user, organization: org, manager: top)
      h = ApprovalTestRecord.create!(requester: solo).tap { |x| Approvals::Start.call(x) }
      expect(h).to receive(:apply_approval_effects!).with(acting_user: top).once
      described_class.call(approvable: h, approver: top)
    end
  end
```

- [ ] **Step 2: fail を確認**

Run: `bundle exec rspec spec/services/approvals/approve_spec.rb -e "副作用 hook"`
Expected: FAIL（hook 未呼び出しで `receive(...).once` が満たされない）

- [ ] **Step 3: エンジンに hook 呼び出しを追加**

`app/services/approvals/approve.rb` の `@approvable.approve! if @approvable.all_stages_approved?` を以下に置換:

```ruby
        if @approvable.all_stages_approved?
          @approvable.approve!                                  # AASM applying→approved
          @approvable.apply_approval_effects!(acting_user: @acting_user)  # 副作用（§13.6・2-2b）
        end
```

- [ ] **Step 4: pass を確認**

Run: `bundle exec rspec spec/services/approvals/approve_spec.rb`
Expected: PASS（既存の段階進行 example も緑）

- [ ] **Step 5: rubocop + brakeman + コミット**

```bash
bundle exec rubocop --force-exclusion app/services/approvals/approve.rb
bin/brakeman --no-pager
git add app/services/approvals/approve.rb spec/services/approvals/approve_spec.rb
git commit -m "$(cat <<'EOF'
feat: Approve エンジンが最終承認時に apply_approval_effects! を撃つ（2-2b）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Recalculate が status から day_part を導出

**Files:**
- Modify: `app/services/clockings/recalculate.rb`
- Test: `spec/services/clockings/recalculate_spec.rb`

**Interfaces:**
- Consumes: `AttendanceRecord#status`（Task 1 の enum）。
- Produces: `Clockings::Recalculate` は `morning_half → day_part :morning_half`（遅刻免除）、`afternoon_half → :afternoon_half`（早退免除）、その他 → `:full` を `LateEarlyCalculator` 等へ渡す。

- [ ] **Step 1: 失敗する spec を追記**

`spec/services/clockings/recalculate_spec.rb` の末尾 `end` 前に追加（既存の `org` / `with_tenant` / pattern 生成イディオムに合わせる。下記は自己完結セットアップ）:

```ruby
  describe "day_part を status から導出（2-2b）" do
    let(:org) { create(:organization) }
    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    # 固定時間制 09:00-18:00。遅刻判定が効くよう 10:00 出勤（= 遅刻）
    let(:pattern) do
      create(:work_pattern, start_time: "09:00", end_time: "18:00", break_minutes: 60)
    end
    let(:user) { create(:user, organization: org) }

    def record_with(status:)
      create(:attendance_record, user:, work_pattern: pattern, status:,
             work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 1),    # JST 10:00（遅刻）
             clock_out: Time.utc(2026, 6, 1, 9))   # JST 18:00
    end

    it "morning_half は遅刻を免除（is_late=false）" do
      record = record_with(status: :morning_half)
      Clockings::Recalculate.call(record:)
      expect(record.reload.is_late).to be false
    end

    it "full（clocked_out）は遅刻を計上（is_late=true）" do
      record = record_with(status: :clocked_out)
      Clockings::Recalculate.call(record:)
      expect(record.reload.is_late).to be true
    end
  end
```

> 注: `work_pattern` factory の既定は start_time "09:00" / end_time "18:00" / break_minutes 60（実機確認済）。`organization` factory は time_zone 既定を持つ（既存 recalculate_spec が JST 前提で緑）。

- [ ] **Step 2: fail を確認**

Run: `bundle exec rspec spec/services/clockings/recalculate_spec.rb -e "day_part を status"`
Expected: FAIL（morning_half でも `day_part = :full` 固定ゆえ is_late=true になる）

- [ ] **Step 3: Recalculate を編集**

`app/services/clockings/recalculate.rb` の `day_part = :full # Phase 2 で status（morning_half 等）から導出` を置換:

```ruby
        day_part =
          case @record.status
          when "morning_half" then :morning_half
          when "afternoon_half" then :afternoon_half
          else :full   # working / clocked_out / on_leave
          end
```

- [ ] **Step 4: pass を確認**

Run: `bundle exec rspec spec/services/clockings/recalculate_spec.rb`
Expected: PASS（既存の退勤再計算 example も緑）

- [ ] **Step 5: rubocop + コミット**

```bash
bundle exec rubocop --force-exclusion app/services/clockings/recalculate.rb
git add app/services/clockings/recalculate.rb spec/services/clockings/recalculate_spec.rb
git commit -m "$(cat <<'EOF'
feat: Recalculate が status から day_part を導出（半休の遅刻早退免除・2-2b）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: LeaveRequests::ApplyApproval（副作用本体）

**Files:**
- Create: `app/services/leave_requests/apply_approval.rb`
- Modify: `app/services/approvals.rb`（`OverBalanceError`）、`app/models/leave_request.rb`（hook 実装）、`app/calculators/leave_days_calculator.rb`（`counted_dates` 抽出）
- Test: `spec/services/leave_requests/apply_approval_spec.rb`、`spec/calculators/leave_days_calculator_spec.rb`（追記）

**Interfaces:**
- Consumes: `CompanyCalendarResolver#day_classifications`、`LeaveDaysCalculator.counted_dates`、`Clockings::Recalculate.call`、`Organization#fiscal_year_for`、`LeaveBalance`（`.lock`）、`AttendanceRecord`（leave status）、`AttendanceHistory`（leave_approved・Task 2）。
- Produces: `LeaveRequests::ApplyApproval.call(leave_request:, acting_user:)`。`Approvals::OverBalanceError < Approvals::Error`。`LeaveDaysCalculator.counted_dates(classifications) → [Date]`。`LeaveRequest#apply_approval_effects!(acting_user:)`。

### 6a. LeaveDaysCalculator.counted_dates 抽出（DRY 前処理）

- [ ] **Step 1: 失敗する calculator spec を追記**

`spec/calculators/leave_days_calculator_spec.rb` の末尾 `end` 前に:

```ruby
  describe ".counted_dates（2-2b・計上日抽出の共有 API）" do
    it "weekday と paid company_holiday を計上日として返す" do
      classifications = {
        Date.new(2026, 5, 1) => { day_type: :weekday, counts_as_paid_leave: false },        # 計上
        Date.new(2026, 5, 2) => { day_type: :saturday, counts_as_paid_leave: false },        # 除外
        Date.new(2026, 5, 4) => { day_type: :company_holiday, counts_as_paid_leave: true },  # 計上
        Date.new(2026, 5, 5) => { day_type: :company_holiday, counts_as_paid_leave: false }  # 除外
      }
      expect(described_class.counted_dates(classifications))
        .to contain_exactly(Date.new(2026, 5, 1), Date.new(2026, 5, 4))
    end
  end
```

- [ ] **Step 2: fail を確認**

Run: `bundle exec rspec spec/calculators/leave_days_calculator_spec.rb -e counted_dates`
Expected: FAIL（`counted_dates` 未定義）

- [ ] **Step 3: calculator をリファクタ（counted_dates を公開・call は再利用）**

`app/calculators/leave_days_calculator.rb` を以下に置換:

```ruby
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

    counted = counted_dates(classifications).size
    factor = half_day_type == :none ? 1 : 0.5
    BigDecimal(counted.to_s) * BigDecimal(factor.to_s)
  end

  # 計上日の Date 配列（2-2b・ApplyApproval と call が共有 = 計上基準の単一ソース）。
  def self.counted_dates(classifications)
    classifications.select { |_date, info| counted?(info) }.keys
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

- [ ] **Step 4: calculator spec を緑に**

Run: `bundle exec rspec spec/calculators/leave_days_calculator_spec.rb`
Expected: PASS（既存の取得日数 example も緑）

- [ ] **Step 5: コミット**

```bash
bundle exec rubocop --force-exclusion app/calculators/leave_days_calculator.rb
git add app/calculators/leave_days_calculator.rb spec/calculators/leave_days_calculator_spec.rb
git commit -m "$(cat <<'EOF'
refactor: LeaveDaysCalculator.counted_dates を公開（計上基準の単一ソース・2-2b）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

### 6b. ApplyApproval の残高加算（paid・lock!・over-balance ハード拒否）

- [ ] **Step 6: OverBalanceError を定義**

`app/services/approvals.rb` の `class ProxyNotSupported < Error; end` の直後に:

```ruby
  class OverBalanceError < Error; end     # 承認時の残高不足（D1 ハード拒否・2-2b）
```

- [ ] **Step 7: 失敗する service spec を作成（残高グループ）**

Create `spec/services/leave_requests/apply_approval_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::ApplyApproval do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org) }
  let(:paid_type) { create(:leave_type, system_type: :annual, paid_leave: true) }
  let(:unpaid_type) { create(:leave_type, system_type: :other, paid_leave: false) }

  # start_date の年度（決算月に依らず robust に算出）
  let(:start_date) { Date.new(2026, 5, 1) }   # 金曜（fallback weekday）
  let(:fiscal_year) { org.fiscal_year_for(start_date) }

  def leave(type:, sd: start_date, ed: start_date, half: :none, days: 1)
    create(:leave_request, requester: user, leave_type: type,
           start_date: sd, end_date: ed, half_day_type: half, days_requested: days)
  end

  def apply(lr) = described_class.call(leave_request: lr, acting_user: approver)

  describe "残高加算（paid・§4.10 ハード拒否）" do
    it "paid 種別は used_days に days_requested を加算" do
      balance = create(:leave_balance, user:, leave_type: paid_type,
                       fiscal_year:, granted_days: 20, used_days: 3)
      apply(leave(type: paid_type, days: 1))
      expect(balance.reload.used_days).to eq(BigDecimal("4"))
    end

    it "残高超過は OverBalanceError で拒否し used_days を変えない" do
      balance = create(:leave_balance, user:, leave_type: paid_type,
                       fiscal_year:, granted_days: 5, carry_over_days: 0, used_days: 5)
      expect { apply(leave(type: paid_type, days: 1)) }
        .to raise_error(Approvals::OverBalanceError)
      expect(balance.reload.used_days).to eq(BigDecimal("5"))
    end

    it "残高行が無い paid 種別は over-balance（available=0）" do
      expect { apply(leave(type: paid_type, days: 1)) }
        .to raise_error(Approvals::OverBalanceError)
    end

    it "非 paid 種別は残高を一切触らない（balance 行が無くても成功）" do
      expect { apply(leave(type: unpaid_type, days: 1)) }.not_to raise_error
    end

    it "over-balance では AR も history も作られない（残高→AR→history の順序契約を固定）" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, granted_days: 0, used_days: 0)
      expect { apply(leave(type: paid_type, days: 1)) }.to raise_error(Approvals::OverBalanceError)
      expect(AttendanceRecord.count).to eq(0)
      expect(AttendanceHistory.count).to eq(0)
    end
  end
end
```

> 注: ApplyApproval の処理順は「残高 → AR → history」。残高で raise すれば AR/history は未到達 = atomic rollback の前提。上記 example はこの順序契約を固定する。

- [ ] **Step 8: fail を確認**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb`
Expected: FAIL（`LeaveRequests::ApplyApproval` 未定義 = `NameError`）

- [ ] **Step 9: ApplyApproval を作成（残高 + AR + history・フル実装）**

Create `app/services/leave_requests/apply_approval.rb`:

```ruby
# frozen_string_literal: true

module LeaveRequests
  # 休暇承認の副作用本体（SPEC §6.2・§13.6・2-2b 設計 §1.3–1.7）。
  # 呼び出し元: LeaveRequest#apply_approval_effects!（Approvals::Approve の with_lock 内・同一 tx）。
  # 内側で rescue しない — OverBalanceError 等は raise 伝播し承認ごと atomic に rollback（§1.2）。
  # 処理順: ① 残高加算（paid のみ・lock!・over-balance 拒否）→ ② per-day AR upsert（+ 半休 clocked は recalc）
  #         → ③ AttendanceHistory(leave_approved)。
  class ApplyApproval
    def self.call(leave_request:, acting_user:) = new(leave_request:, acting_user:).call

    def initialize(leave_request:, acting_user:)
      @leave_request = leave_request
      @acting_user = acting_user
    end

    def call
      # request 文脈前提だが Recalculate 同型で明示ラップ（文脈喪失・将来バッチ化に fail-closed）
      ActsAsTenant.with_tenant(@leave_request.organization) do
        add_to_balance
        upsert_attendance_records
        record_history
      end
      @leave_request
    end

    private

    def add_to_balance
      return unless @leave_request.leave_type.paid_leave?

      fiscal_year = @leave_request.organization.fiscal_year_for(@leave_request.start_date)  # §6.2 年度跨ぎ統一
      # UNIQUE [org,user,type,fiscal_year] が単一行を保証。.lock で FOR UPDATE（並行承認の二重加算防止）
      balance = LeaveBalance
                .where(user_id: @leave_request.requester_id,
                       leave_type_id: @leave_request.leave_type_id, fiscal_year:)
                .lock.first
      available = balance ? balance.granted_days + balance.carry_over_days : BigDecimal("0")
      used = balance ? balance.used_days : BigDecimal("0")
      # 残高行が無い paid 種別は available=0 → over-balance（D1・hr_admin が先に付与）
      raise Approvals::OverBalanceError if used + @leave_request.days_requested > available

      balance.update!(used_days: used + @leave_request.days_requested)
    end

    def upsert_attendance_records
      classifications = CompanyCalendarResolver.new(organization: @leave_request.organization)
                                               .day_classifications(@leave_request.start_date,
                                                                    @leave_request.end_date)
      LeaveDaysCalculator.counted_dates(classifications).each do |date|
        record = AttendanceRecord.find_or_initialize_by(
          user_id: @leave_request.requester_id, work_date: date
        )
        record.status = leave_status
        record.save!
        recalculate(record)
      end
    end

    def record_history
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id,
        actor: @acting_user,             # §3.5 オーナー/操作者分離
        source: @leave_request,          # polymorphic
        event_type: :leave_approved,     # 既存予約 enum（整数 2）
        event_date: @leave_request.start_date   # 申請単位 1 行（per-day AR とは別粒度）
      )
    end

    # 半休で clock_out 済の AR のみ LateEarly を上書き。全休（打刻無）・working 中は呼ばない。
    def recalculate(record)
      return if record.on_leave?
      return if record.clock_out.blank?

      Clockings::Recalculate.call(record:)
    end

    def leave_status
      case @leave_request.half_day_type
      when "none" then :on_leave
      when "morning" then :morning_half
      when "afternoon" then :afternoon_half
      end
    end
  end
end
```

- [ ] **Step 10: 残高グループの pass を確認**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb`
Expected: PASS（残高 example 群が緑。AR/history は次グループで検証）

- [ ] **Step 11: コミット（残高 + 本体）**

```bash
bundle exec rubocop --force-exclusion app/services/leave_requests/apply_approval.rb app/services/approvals.rb
git add app/services/leave_requests/apply_approval.rb app/services/approvals.rb spec/services/leave_requests/apply_approval_spec.rb
git commit -m "$(cat <<'EOF'
feat: LeaveRequests::ApplyApproval — 残高 lock!加算 + over-balance ハード拒否（2-2b）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

### 6c. ApplyApproval の AR upsert / recalc / history を検証

- [ ] **Step 12: AR/history グループの spec を追記**

`spec/services/leave_requests/apply_approval_spec.rb` の最後の `end`（describe ブロック）の前に:

```ruby
  describe "AttendanceRecord upsert（§13.1 の 2-2b 担当遷移）" do
    it "全休は計上日ごとに on_leave AR を作成（打刻無・calc NULL）" do
      apply(leave(type: unpaid_type, days: 1))   # 2026-05-01（金）単日
      record = AttendanceRecord.find_by(user:, work_date: start_date)
      expect(record).to have_attributes(status: "on_leave", clock_in: nil)
      expect(record.actual_work_hours).to be_nil
    end

    it "除外日（土日）には AR を作らない" do
      # 2026-05-01(金)〜2026-05-04(月): 土(2)/日(3) 除外、金・月のみ計上
      apply(leave(type: unpaid_type, sd: Date.new(2026, 5, 1), ed: Date.new(2026, 5, 4), days: 2))
      expect(AttendanceRecord.where(user:).pluck(:work_date))
        .to contain_exactly(Date.new(2026, 5, 1), Date.new(2026, 5, 4))
    end

    it "月跨ぎは各 AR が自分の月の work_date を持つ" do
      # 2026-05-29(金)〜2026-06-01(月): 5/29 金・6/1 月が計上（5/30 土・5/31 日 除外）
      apply(leave(type: unpaid_type, sd: Date.new(2026, 5, 29), ed: Date.new(2026, 6, 1), days: 2))
      dates = AttendanceRecord.where(user:).pluck(:work_date)
      expect(dates).to contain_exactly(Date.new(2026, 5, 29), Date.new(2026, 6, 1))
    end

    it "打刻済（clocked_out）の日に午前半休が承認されると status 更新 + 遅刻免除" do
      pattern = create(:work_pattern, start_time: "09:00", end_time: "18:00", break_minutes: 60)
      existing = create(:attendance_record, user:, work_pattern: pattern, status: :clocked_out,
                        work_date: start_date,
                        clock_in: Time.utc(2026, 5, 1, 1),    # JST 10:00（本来遅刻）
                        clock_out: Time.utc(2026, 5, 1, 9))   # JST 18:00
      apply(leave(type: unpaid_type, half: :morning))
      expect(existing.reload).to have_attributes(status: "morning_half", is_late: false)
    end

    it "AttendanceHistory(leave_approved) を actor=承認者・source=申請で 1 行記録" do
      expect { apply(leave(type: unpaid_type, days: 1)) }
        .to change { AttendanceHistory.where(event_type: :leave_approved).count }.by(1)
      history = AttendanceHistory.find_by(event_type: :leave_approved)
      expect(history).to have_attributes(actor_id: approver.id, source: have_attributes(id: anything),
                                         user_id: user.id)
    end
  end

  describe "年度跨ぎ（§6.2 start_date 年度に統一）" do
    it "start_date の年度の残高にのみ加算する" do
      # 3月決算（4月開始）想定でも robust に: start_date 年度の残高だけ動く
      fy_start = org.fiscal_year_for(Date.new(2026, 5, 1))
      this_year = create(:leave_balance, user:, leave_type: paid_type, fiscal_year: fy_start,
                         granted_days: 20, used_days: 0)
      apply(leave(type: paid_type, sd: Date.new(2026, 5, 1), ed: Date.new(2026, 5, 1), days: 1))
      expect(this_year.reload.used_days).to eq(BigDecimal("1"))
    end
  end
```

- [ ] **Step 13: 全 example の pass を確認**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb`
Expected: PASS（実装は Step 9 で完了済 — AR/recalc/history は同じ本体が処理する）

> もし `org.fiscal_year_for(Date.new(2026,5,1))` と `factory の organization 既定 fiscal_year_end_month` の組合せで balance の fiscal_year が一致せず残高テストが落ちる場合、balance 作成の `fiscal_year:` を `org.fiscal_year_for(start_date)` に合わせていること（本 spec はそうしている）を再確認。

- [ ] **Step 14: LeaveRequest に hook 実装を追加 + spec**

`spec/models/leave_request_spec.rb` の末尾 `end` 前に:

```ruby
  describe "#apply_approval_effects!（2-2b・委譲）" do
    around { |ex| ActsAsTenant.with_tenant(create(:organization)) { ex.run } }

    it "ApplyApproval へ委譲する" do
      lr = build(:leave_request)
      actor = build(:user, :manager_role)
      expect(LeaveRequests::ApplyApproval).to receive(:call).with(leave_request: lr, acting_user: actor)
      lr.apply_approval_effects!(acting_user: actor)
    end
  end
```

`app/models/leave_request.rb` の `private` の直前（public メソッドとして）に:

```ruby
  # 承認確定時の副作用（§6.2・§13.6）。Approve エンジンの with_lock 内・同一 tx で呼ばれる。
  def apply_approval_effects!(acting_user:)
    LeaveRequests::ApplyApproval.call(leave_request: self, acting_user:)
  end
```

- [ ] **Step 15: 全 spec の pass を確認**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb spec/models/leave_request_spec.rb`
Expected: PASS

- [ ] **Step 16: rubocop + brakeman + コミット**

```bash
bundle exec rubocop --force-exclusion app/services/leave_requests/apply_approval.rb app/models/leave_request.rb
bin/brakeman --no-pager
git add app/services/leave_requests/apply_approval.rb app/models/leave_request.rb spec/services/leave_requests/apply_approval_spec.rb spec/models/leave_request_spec.rb
git commit -m "$(cat <<'EOF'
feat: ApplyApproval の AR upsert/recalc/history + LeaveRequest hook 委譲（2-2b）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 7: ApprovalAssignmentPolicy に Scope と index?

**Files:**
- Modify: `app/policies/approval_assignment_policy.rb`
- Test: `spec/policies/approval_assignment_policy_spec.rb`

**Interfaces:**
- Consumes: 既存 `ApprovalAssignmentPolicy#approve?`（actionable?）。
- Produces: `ApprovalAssignmentPolicy::Scope`（自分が approver の pending のみ返す）、`#index? = user.present?`。

- [ ] **Step 1: 失敗する Scope spec を追記**

`spec/policies/approval_assignment_policy_spec.rb` の最終 `end` の前に:

```ruby
  describe "Scope" do
    def resolved_for(actor) = ApprovalAssignmentPolicy::Scope.new(actor, ApprovalAssignment).resolve

    it "自分が approver の pending のみ返す" do
      host # stage1=boss(pending), stage2=dept(pending)
      expect(resolved_for(boss)).to contain_exactly(host.approval_assignments.find_by(position: 1))
    end

    it "決裁済（approved）は除外する" do
      Approvals::Approve.call(approvable: host, approver: boss)
      expect(resolved_for(boss)).to be_empty
    end

    it "他者の pending は含めない" do
      host
      expect(resolved_for(dept)).to contain_exactly(host.approval_assignments.find_by(position: 2))
      expect(resolved_for(dept)).not_to include(host.approval_assignments.find_by(position: 1))
    end

    it "他テナントの pending を漏らさない" do
      host
      other_org = create(:organization)
      other_assignment = ActsAsTenant.with_tenant(other_org) do
        oemp = create(:user, organization: other_org)
        oboss = create(:user, :manager_role, organization: other_org)
        oemp.update!(manager: oboss)
        h = ApprovalTestRecord.create!(requester: oemp).tap { |x| Approvals::Start.call(x) }
        h.approval_assignments.find_by(position: 1)
      end
      expect(resolved_for(boss)).not_to include(other_assignment)
    end
  end

  describe "#index?" do
    it "ログインユーザーに許可" do
      expect(described_class.new(boss, ApprovalAssignment).index?).to be true
    end
  end
```

- [ ] **Step 2: fail を確認**

Run: `bundle exec rspec spec/policies/approval_assignment_policy_spec.rb -e "Scope"`
Expected: FAIL（`ApprovalAssignmentPolicy::Scope` 未定義）

- [ ] **Step 3: Policy に Scope と index? を追加**

`app/policies/approval_assignment_policy.rb` の `def approve? = actionable?` の上に:

```ruby
  def index? = user.present?
```

そして `actionable?` を含む `private` ブロックの後、クラス終端 `end` の前に:

```ruby
  # 承認インボックスの候補集合（2-2b 設計 §3・D6）。「現段階で actionable か」（applying?・段階順序・
  # 自己承認除外）は controller が既存 approve? で絞る — 段階導出を SQL に再発明せず authz 単一ソースを保つ。
  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(approver_id: user.id, decision: :pending)
  end
```

- [ ] **Step 4: pass を確認**

Run: `bundle exec rspec spec/policies/approval_assignment_policy_spec.rb`
Expected: PASS（既存 approve?/reject? example も緑）

- [ ] **Step 5: rubocop + コミット**

```bash
bundle exec rubocop --force-exclusion app/policies/approval_assignment_policy.rb
git add app/policies/approval_assignment_policy.rb spec/policies/approval_assignment_policy_spec.rb
git commit -m "$(cat <<'EOF'
feat: ApprovalAssignmentPolicy に Scope（自分の pending）と index?（2-2b）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 8: 承認インボックス UI（ルート + コントローラ + 描画）

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/approval_assignments_controller.rb`
- Create: `app/views/approval_assignments/index.html.erb`
- Create: `app/components/approvals/leave_request_row_component.rb`、`app/components/approvals/leave_request_row_component.html.erb`
- Test: `spec/requests/approval_assignments_spec.rb`

**Interfaces:**
- Consumes: `Approvals::Approve`/`Reject`（comment 付き）、`Approvals::OverBalanceError`（Task 6）、`ApprovalAssignmentPolicy`（Task 7）、`Approvable#single_stage?`（Task 3）。
- Produces: `GET /approval_assignments`（インボックス）、`PATCH /approval_assignments/:id/approve`、`PATCH /approval_assignments/:id/reject`。

- [ ] **Step 1: ルートを追加**

`config/routes.rb` の `resources :leave_requests do ... end` ブロックの直後（`root` の前）に:

```ruby
  resources :approval_assignments, only: %i[index] do
    member do
      patch :approve
      patch :reject
    end
  end
```

- [ ] **Step 2: 失敗する request spec を作成**

Create `spec/requests/approval_assignments_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ApprovalAssignments", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:hr)      { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:dept)    { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: hr) } }
  let!(:boss)    { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: dept) } }
  let!(:emp)     { ActsAsTenant.with_tenant(org) { create(:user, manager: boss) } }   # route: [boss, dept]
  let!(:leave_type) { ActsAsTenant.with_tenant(org) { create(:leave_type, paid_leave: false) } }

  # emp の休暇申請を 1 件起票（承認エンジン起動済）
  let!(:leave) do
    ActsAsTenant.with_tenant(org) do
      LeaveRequests::Create.call(requester: emp, leave_type:, start_date: Date.new(2026, 5, 1),
                                 end_date: Date.new(2026, 5, 1), half_day_type: "none", reason: "私用")
    end
  end
  def assignment_for(position) = ActsAsTenant.with_tenant(org) { leave.approval_assignments.find_by(position:) }

  describe "GET index" do
    it "現段階の担当者には actionable な assignment を表示" do
      sign_in boss
      get approval_assignments_url(host: tenant_host(org))
      expect(response.body).to include(emp.name)
    end

    it "現段階でない担当者（dept）には何も出さない" do
      sign_in dept
      get approval_assignments_url(host: tenant_host(org))
      expect(response.body).not_to include(emp.name)
    end
  end

  describe "PATCH approve（一周）" do
    it "承認で AR 作成・残高消費なし（非 paid）・履歴記録・status approved" do
      sign_in boss
      patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org))
      sign_in dept
      patch approve_approval_assignment_url(assignment_for(2), host: tenant_host(org))

      ActsAsTenant.with_tenant(org) do
        expect(leave.reload.approval_status).to eq("approved")
        expect(AttendanceRecord.find_by(user: emp, work_date: Date.new(2026, 5, 1)).status).to eq("on_leave")
        expect(AttendanceHistory.where(event_type: :leave_approved).count).to eq(1)
      end
    end

    it "他テナント/他人の assignment は 404" do
      sign_in dept
      patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org))  # stage1 は boss 担当
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH approve（over-balance ハード拒否）" do
    let!(:paid_type) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :annual, paid_leave: true) } }
    let!(:paid_leave) do
      ActsAsTenant.with_tenant(org) do
        LeaveRequests::Create.call(requester: emp, leave_type: paid_type, start_date: Date.new(2026, 5, 1),
                                   end_date: Date.new(2026, 5, 1), half_day_type: "none", reason: "有給")
      end
    end
    def paid_assignment(pos) = ActsAsTenant.with_tenant(org) { paid_leave.approval_assignments.find_by(position: pos) }

    it "残高ゼロの paid を最終承認すると alert + DB 無変化（status は applying のまま）" do
      sign_in boss
      patch approve_approval_assignment_url(paid_assignment(1), host: tenant_host(org))
      sign_in dept
      patch approve_approval_assignment_url(paid_assignment(2), host: tenant_host(org))

      ActsAsTenant.with_tenant(org) do
        expect(paid_leave.reload.approval_status).to eq("applying")   # rollback で未確定
        expect(AttendanceRecord.where(user: emp).count).to eq(0)
        expect(AttendanceHistory.where(event_type: :leave_approved).count).to eq(0)
        expect(paid_assignment(2).decision).to eq("pending")          # assignment も巻き戻る
      end
      follow_redirect!
      expect(response.body).to include("残高不足")
    end
  end

  describe "PATCH reject" do
    it "理由付き却下で rejected" do
      sign_in boss
      patch reject_approval_assignment_url(assignment_for(1), host: tenant_host(org)),
            params: { comment: "今回は見送り" }
      ActsAsTenant.with_tenant(org) { expect(leave.reload.approval_status).to eq("rejected") }
    end

    it "理由無しの却下は alert（rejected にしない）" do
      sign_in boss
      patch reject_approval_assignment_url(assignment_for(1), host: tenant_host(org)), params: { comment: "" }
      ActsAsTenant.with_tenant(org) { expect(leave.reload.approval_status).to eq("applying") }
    end
  end
end
```

- [ ] **Step 3: fail を確認**

Run: `bundle exec rspec spec/requests/approval_assignments_spec.rb`
Expected: FAIL（コントローラ/ビュー未定義 = ルーティング or テンプレートエラー）

- [ ] **Step 4: コントローラを作成**

Create `app/controllers/approval_assignments_controller.rb`:

```ruby
# frozen_string_literal: true

# 承認インボックス（SPEC §6.2・§7・2-2b 設計 §4）。actionable な ApprovalAssignment を一覧し、
# 承認/却下を Approvals::Approve / Reject へ委譲。over-balance 等は rescue して flash 再描画。
class ApprovalAssignmentsController < ApplicationController
  before_action :set_assignment, only: %i[approve reject]

  def index
    authorize ApprovalAssignment
    @assignments = policy_scope(ApprovalAssignment)
                   .includes(:approvable)
                   .select { |assignment| policy(assignment).approve? }   # 現段階の actionable のみ
  end

  def approve
    authorize @assignment, :approve?
    Approvals::Approve.call(approvable: @assignment.approvable, approver: current_user,
                            comment: params[:comment])
    redirect_to approval_assignments_path, status: :see_other, notice: "承認しました"
  rescue Approvals::OverBalanceError
    redirect_to approval_assignments_path, status: :see_other,
                alert: "残高不足で承認できません（人事へ残高の付与をご依頼ください）"
  rescue AASM::InvalidTransition, Approvals::NotCurrentApprover
    redirect_to approval_assignments_path, status: :see_other, alert: "この申請は既に処理されています"
  end

  def reject
    authorize @assignment, :reject?
    Approvals::Reject.call(approvable: @assignment.approvable, approver: current_user,
                           comment: params[:comment])
    redirect_to approval_assignments_path, status: :see_other, notice: "却下しました"
  rescue ArgumentError
    redirect_to approval_assignments_path, status: :see_other, alert: "却下理由を入力してください"
  rescue AASM::InvalidTransition, Approvals::NotCurrentApprover
    redirect_to approval_assignments_path, status: :see_other, alert: "この申請は既に処理されています"
  end

  private

  # 他人/他テナントの assignment は policy_scope 経由 find で 404（scope + policy の二層）
  def set_assignment
    @assignment = policy_scope(ApprovalAssignment).find(params[:id])
  end
end
```

- [ ] **Step 5: 行コンポーネントを作成**

Create `app/components/approvals/leave_request_row_component.rb`:

```ruby
# frozen_string_literal: true

module Approvals
  # 承認インボックスの LeaveRequest 行（2-2b 設計 §4.2）。approvable_type 別描画の最初の型。
  class LeaveRequestRowComponent < ViewComponent::Base
    def initialize(assignment:)
      @assignment = assignment
      @leave = assignment.approvable
    end

    def stage_label
      @leave.single_stage? ? "単段（独立性なし）" : "第 #{@assignment.position} 段階"
    end

    def half_day_label
      return nil if @leave.half_day_none?

      @leave.half_day_morning? ? "午前半休" : "午後半休"
    end
  end
end
```

Create `app/components/approvals/leave_request_row_component.html.erb`:

```erb
<div class="border rounded p-4 mb-3" data-approval-row>
  <div class="font-medium"><%= @leave.requester.name %> ／ <%= @leave.leave_type.name %></div>
  <div class="text-sm text-gray-600">
    <%= @leave.start_date %> 〜 <%= @leave.end_date %>
    （<%= @leave.days_requested.to_s("F") %> 日<%= "・#{half_day_label}" if half_day_label %>）
    <span class="ml-2"><%= stage_label %></span>
  </div>
  <% if @leave.reason.present? %>
    <div class="text-sm text-gray-500 mt-1"><%= @leave.reason %></div>
  <% end %>
  <div class="mt-2 flex flex-wrap items-center gap-2">
    <%= button_to "承認", approve_approval_assignment_path(@assignment), method: :patch,
          class: "bg-blue-600 text-white px-3 py-1 rounded text-sm",
          data: { turbo_confirm: "承認しますか？" } %>
    <%= form_with url: reject_approval_assignment_path(@assignment), method: :patch,
          class: "flex items-center gap-1" do |f| %>
      <%= f.text_field :comment, placeholder: "却下理由（必須）",
            class: "border rounded px-2 py-1 text-sm" %>
      <%= f.submit "却下", class: "bg-gray-200 px-3 py-1 rounded text-sm" %>
    <% end %>
  </div>
</div>
```

- [ ] **Step 6: index ビューを作成（型別 dispatch）**

Create `app/views/approval_assignments/index.html.erb`:

```erb
<% content_for :title, "承認インボックス" %>
<div class="max-w-3xl mx-auto p-4">
  <h1 class="text-xl font-bold mb-4">承認インボックス</h1>

  <% if @assignments.empty? %>
    <p class="text-gray-500">承認待ちの申請はありません。</p>
  <% else %>
    <% @assignments.each do |assignment| %>
      <% case assignment.approvable %>
      <% when LeaveRequest %>
        <%= render Approvals::LeaveRequestRowComponent.new(assignment:) %>
      <% end %>
    <% end %>
  <% end %>
</div>
```

- [ ] **Step 7: pass を確認**

Run: `bundle exec rspec spec/requests/approval_assignments_spec.rb`
Expected: PASS

- [ ] **Step 8: rubocop + brakeman + コミット**

```bash
bundle exec rubocop --force-exclusion app/controllers/approval_assignments_controller.rb app/components/approvals
bin/brakeman --no-pager
git add config/routes.rb app/controllers/approval_assignments_controller.rb app/components/approvals app/views/approval_assignments spec/requests/approval_assignments_spec.rb
git commit -m "$(cat <<'EOF'
feat: 承認インボックス UI（index/approve/reject・型別描画・over-balance rescue・2-2b）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 9（任意）: 薄い system spec（設計 §5・request が一周を網羅済ゆえ optional）**

ブラウザ層の確認が欲しい場合のみ。Create `spec/system/leave_approval_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

# rack_test（JS なし）。turbo_confirm は無視され button_to が直接 POST される。
RSpec.describe "休暇承認の一周", type: :system do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:dept) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role) } }
  let!(:boss) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: dept) } }
  let!(:emp)  { ActsAsTenant.with_tenant(org) { create(:user, manager: boss) } }
  let!(:type) { ActsAsTenant.with_tenant(org) { create(:leave_type, paid_leave: false) } }
  let!(:leave) do
    ActsAsTenant.with_tenant(org) do
      LeaveRequests::Create.call(requester: emp, leave_type: type, start_date: Date.new(2026, 5, 1),
                                 end_date: Date.new(2026, 5, 1), half_day_type: "none", reason: "私用")
    end
  end

  it "承認者がインボックスから承認すると on_leave AR ができる" do
    switch_tenant(org)
    sign_in boss
    visit approval_assignments_path
    expect(page).to have_content(emp.name)
    click_button "承認"
    ActsAsTenant.with_tenant(org) do
      expect(AttendanceRecord.find_by(user: emp, work_date: Date.new(2026, 5, 1)).status).to eq("on_leave")
    end
  end
end
```

> 注: 認証（`sign_in`）は既存 `spec/system/leave_request_form_spec.rb` のログイン手順に合わせること（system 型の Devise helper 設定に依存）。

Run: `bundle exec rspec spec/system/leave_approval_spec.rb` → PASS。緑なら `git add` して上記コミットに含める。

---

## Task 9: ドキュメント更新（ROADMAP・バックログ・GOTCHAS）

**Files:**
- Modify: `docs/ROADMAP.md`、`docs/RAILS_GOTCHAS.md`

**Interfaces:** なし（docs only）。

- [ ] **Step 1: ROADMAP の 2-2b 行を完了に更新**

`docs/ROADMAP.md` の 2-2b 行を以下に置換（`<PR番号>` は PR 作成後に確定値へ。PR 本文で確定）:

```markdown
- [x] **2-2b 承認 + 副作用**: 承認インボックス UI・`ApprovalAssignmentPolicy::Scope`・`approve` 副作用サービス（`LeaveRequests::ApplyApproval`＝残高 `lock!`加算/over-balance ハード拒否・AR upsert on_leave/半休・`LateEarly` 再計算・`AttendanceHistory(leave_approved)`）・月跨ぎ per-day 計上・年度跨ぎ start_date 統一・`AttendanceRecord.status` enum 拡張（PR #<PR番号>）
```

- [ ] **Step 2: 横断バックログに半休打刻連携（D5）を追記**

`docs/ROADMAP.md` の「横断バックログ」セクションに 1 項目追加:

```markdown
- [ ] **半休日への後続打刻連携（§13.1 `morning_half → morning_half`）**: 先に半休休暇が承認され半休 status の AR が存在する日に、本人が残り半日を打刻する経路が未対応（`Clockings::ClockIn` は `(user, work_date)` unique index に衝突し得る）。2-2b は leave 承認が AR を作る側に集中し本連携を退避（2-2b 設計 D5）。`ClockIn` を「既存 AR があれば status を壊さず clock_in を埋める upsert」へ改修する Phase 1 clocking PR で回収
```

- [ ] **Step 3: GOTCHAS に with_lock + rescue の文脈別正解を追記**

`docs/RAILS_GOTCHAS.md` の適切なセクション（トランザクション/サービス関連）に追記:

```markdown
### with_lock 内の副作用 — rescue するか伝播させるかは「巻き戻したいか」で決まる（2-2b・verified 2026-06-18）

- **WHAT:** `with_lock` 内の tx で失敗し得る副作用を `rescue` して握り潰すと、ロールバック済みの更新が消えたまま「成功」を返す（偽 success + 更新消失）。
- **WHY:** 2 つの正反対の正解が文脈で決まる。
  - **1-2 ClockOut→Recalculate:** 「打刻だけは保全したい」→ 失敗し得る後続（再計算）を **commit 後/savepoint に隔離**し、打刻本体を守る。
  - **2-2b Approve→ApplyApproval:** 「残高違反なら承認ごと無効が正」→ `OverBalanceError` を **rescue せず raise 伝播**させ、assignment 承認・残高加算・AR 生成・履歴を atomic に巻き戻す。controller 層で rescue して flash 再描画。
- **HOW:** 「この副作用が失敗したら主操作も無かったことにすべきか？」を先に問う。Yes → 同一 tx で raise 伝播。No → savepoint/commit 後へ隔離。機械的コピー厳禁。
```

- [ ] **Step 4: docs のみコミット**

```bash
git add docs/ROADMAP.md docs/RAILS_GOTCHAS.md
git commit -m "$(cat <<'EOF'
docs: ROADMAP 2-2b 完了マーク + 半休打刻バックログ + GOTCHAS（with_lock 文脈別正解）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## 最終検証（PR 前・`/preflight` 相当）

- [ ] **全 spec 緑:** `bin/rails db:test:prepare && bundle exec rspec`
- [ ] **rubocop 全体:** `bundle exec rubocop`
- [ ] **brakeman:** `bin/brakeman --no-pager`
- [ ] **`/preflight`** スキルを実行（CI 等価の静的検証）
- [ ] **レビュー:** `tenant-isolation-reviewer`（migration/models/services 該当）+ `labor-law-compliance-reviewer`（残高加算・半休 0.5・年度帰属が §8.6/§5.5 と整合か）を merge 前に
- [ ] **PR 作成:** ROADMAP の `<PR番号>` を確定値に差し替え、PR 本文に含める。`gh auth switch -u kei1110` を先に確認（collaborator エラー回避）
