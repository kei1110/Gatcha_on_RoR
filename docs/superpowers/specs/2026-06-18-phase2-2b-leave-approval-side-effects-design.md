# Phase 2-2b 承認 + 副作用（休暇承認の自動処理）— 設計

- 日付: 2026-06-18
- スライス: ROADMAP Phase 2-2 を 2-2a（申請側）/ **2-2b（承認 + 副作用）** に分割した後半
- 1 スライス = 1 ブランチ = 1 PR（`feat/phase2-2b-leave-approval`）
- 典拠: SPEC §6.2（休暇申請の承認後自動処理）・§7.1–7.3（承認エンジン）・§13.1（AttendanceRecord.status 遷移）・§13.6（イベント × `after` 副作用）・§14（連携の継ぎ目）・§4.8–4.10（AR / LeaveRequest / LeaveBalance）・§3.4–3.6（認可・テナント分離）
- 前提エンジン: Phase 2-1（`Approvals::Approve/Reject/Start`・`Approvable` concern・`SelfApproval`）+ Phase 2-2a（`LeaveRequest` / `LeaveBalance` / `LeaveRequests::Estimate/Create` / `Approvals::Cancel`）は据付済み
- **本設計のブレスト確定事項（2026-06-18・`superpowers:brainstorming`）**: 下記「設計判断ログ」D1–D6 をユーザー承認済み

## 0. スコープと前提

2-2a で「社員が休暇を申請・取消でき、hr_admin が残高を付与できる」までが縦に通り、`approval_status` は `applying` のまま積まれている。承認決裁の UI と、決裁が引き起こす**副作用一式**はすべて 2-2a で明示的に後置された。本スライス 2-2b は **「承認者がインボックスから承認/却下でき、承認が対象日の勤怠記録・残高・履歴へ atomic に反映される」** までを縦に通す。

完了条件（ROADMAP Phase 2 前文に整合）: 休暇申請が **申請 →（2-2a）→ 2 段承認 → 副作用（記録更新・残高・履歴）まで一周**する。撤回での復元は 2-5。

### 設計判断ログ

| # | 論点 | 決定 | 根拠 |
|---|------|------|------|
| D1 | 残高不足の承認時挙動（§4.10 の lock! 過剰チェック vs §6.2「承認者が最終判断」の調停） | **ハード拒否**。paid_leave で `used_days + days_requested > available` の承認は `lock!` 下で `OverBalanceError`。承認は不成立（pending 維持）。承認者は却下するか hr_admin が残高を増やしてから再承認 | §4.10 が明示。「承認者が最終判断」は申請を自動ブロックしない（申請時表示）の意で、残高整合は承認時に system が担保 |
| D2 | 副作用の配置アーキテクチャ | **B: エンジンから hook → service**。汎用 `Approvals::Approve` が最終承認時のみ host の `apply_approval_effects!(acting_user:)` を呼び `LeaveRequests::ApplyApproval` へ委譲。同一 `with_lock`/tx・内側 rescue なし | §13.6 のイベント束縛を service 層で実現（hook は approve 経路でのみ呼ばれ reject/cancel では呼ばれない）。エンジンは対象非依存のまま。CCR(2-3)/HWR(2-4) は hook 実装だけで拡張。既存 `Clockings::*`/`Approvals::*` の service 規約に整合 |
| D3 | `AttendanceRecord.status` の AASM 化（§13.1 注「2-2 で再判断」） | **plain enum 拡張で見送り**。`morning_half:2 / afternoon_half:3 / on_leave:4` を予約整数のまま追加。leave 系 status の唯一 writer は副作用 service | 遷移グラフは打刻変更(2-3)・欠勤(4-2)が揃うまで未完。半端 AASM 化は Phase 1 clocking への blast-radius 大。`Recalculate` が calc 列の唯一 writer なのと同型の規律で代替 |
| D4 | 全休 AR の `clock_in` NOT NULL 検証 | **条件付き presence へ緩和**。`validates :clock_in, presence: true, unless: :leave_status?`。working/clocked_out は従来必須 | 全休 AR は打刻が無い。§6.2「対象日の AR 作成」を満たす最小侵襲 |
| D5 | 半休日への後続打刻（§13.1 `morning_half → morning_half`「午後の出退勤打刻」） | **横断バックログへ退避**。2-2b は leave 承認が AR を作る/更新する側に集中。`Clockings::ClockIn` の既存半休 AR upsert 改修は Phase 1 clocking の blast-radius を避け backlog 化 + GOTCHAS 明記 | スライスを縦に細く保つ。承認→記録の一周は本退避でも成立 |
| D6 | 承認インボックスの型汎用性 | **型非依存 Scope + approvable_type 別描画**。`ApprovalAssignmentPolicy::Scope` は ApprovalAssignment 横断、row は type 別 partial/Component | エンジンが既に対象非依存。CCR/HWR は自分の row を足すだけ（前方互換・1 型のための過剰汎用化はしない） |

### 本スライスに含めない（明示的後置）

- **撤回フロー**（withdrawal_requested / withdrawn・復元処理）→ **2-5**。`reject_withdrawal` の「副作用を撃たない」イベント束縛は本設計の hook 構造（approve 経路でのみ発火）が既に下地。`withdrawal_reason` / `last_stale_notified_on` 列も 2-5 で追加
- **事後有給**（absent → on_leave・§6.2）→ **4-2**。`absent` status（整数 5）が 4-2 まで存在しないため、`ApplyApproval` は absent 起点の上書きを扱わない（§13.1 の `absent → on_leave` は 4-2 接続）
- **半休日への後続打刻**（D5）→ 横断バックログ
- **月跨ぎの締め済み月ブロック**（§6.2）→ **Phase 3 依存**。2-2b は per-day 月分割計上の構造（各 AR が自分の work_date を持つ）までで、`MonthlyAttendanceSummary` 締め状態チェックは Phase 3-2 接続
- **承認/却下/滞留の通知送信** → **Phase 4-1**（通知基盤確立まで全機能が送信を持たない・ROADMAP 横断ルール）
- **代理承認**（delegate・§7.5）→ 後続。本スライスの hook は `acting_user` を運ぶが pin（`acting_user == approver`）は 2-1 据置のまま

---

## 1. 副作用オーケストレーション（D2・approach B）

### 1.1 汎用エンジンへの最小侵襲（hook 1 点）

`Approvals::Approve#call` は対象非依存のまま、最終承認時に host の hook を呼ぶ 1 行のみ追加:

```ruby
# app/services/approvals/approve.rb（差分）
@approvable.with_lock do
  guard!
  assignment = current_assignment!
  assignment.update!(decision: :approved, acted_at: Time.current, comment: @comment)
  if @approvable.all_stages_approved?
    @approvable.approve!                                  # AASM applying→approved（既存）
    @approvable.apply_approval_effects!(acting_user: @acting_user)  # ★追加
  end
end
```

`Approvable` concern に **既定 no-op** を置き、2-1 のテスト専用 approvable と将来型を緑に保つ:

```ruby
# app/models/concerns/approvable.rb（追記）
# 承認確定時の副作用 hook（§13.6 のイベント束縛を service 層で実現）。
# 既定は no-op。副作用を持つ host（LeaveRequest 等）が override する。
def apply_approval_effects!(acting_user:) = nil
```

`LeaveRequest` が override し service へ委譲:

```ruby
# app/models/leave_request.rb（追記）
def apply_approval_effects!(acting_user:)
  LeaveRequests::ApplyApproval.call(leave_request: self, acting_user:)
end
```

### 1.2 トランザクション境界とエラー伝播（2-2a §10 の罠を構造で封じる）

- 副作用は **`Approve` の `with_lock` と同一 tx 内**で走る（hook が lock ブロック内で呼ばれる）。
- **内側で rescue しない**。`OverBalanceError`（D1）や検証失敗は raw に raise → tx 全体 rollback（`assignment.update!` ごと巻き戻る = 承認は不成立・pending のまま）→ **controller が rescue** して描画。
- これにより「assignment 承認 / 残高加算 / AR 生成 / 履歴記録」が**全か無か**になり、2-2a §10 の「`with_lock` 内 tx で SQL 例外を rescue → 偽 success + 更新消失」（1-2 で仕留めた罠）を**構造的に回避**。
- **1-2 ClockOut→Recalculate との対比（重要）**: あちらは「打刻だけは保全」したいので失敗し得る後続を commit 後/savepoint に逃がす。こちらは「残高違反なら承認ごと無効」が正なので**逃がさず巻き戻す**。同じ罠への、文脈で正反対の正解。GOTCHAS へ記録。

### 1.3 `LeaveRequests::ApplyApproval`（command・副作用の本体）

```ruby
# app/services/leave_requests/apply_approval.rb
# 入力: leave_request（approved 直後・applying→approved 済）, acting_user（承認者）
# 呼び出し元: LeaveRequest#apply_approval_effects!（Approve の with_lock 内・同一 tx）
# 前提: acts_as_tenant.current_tenant は request 文脈で設定済み（§3.6）。
#   ただし防御として ActsAsTenant.with_tenant(leave_request.organization) でラップ
#   （Recalculate 同型・バッチ化や文脈喪失時の fail-closed）。
module LeaveRequests
  class ApplyApproval
    def self.call(leave_request:, acting_user:) = new(leave_request:, acting_user:).call
    # ① 対象日解決 → ② 残高加算（paid のみ・lock!・over-balance 拒否）
    # → ③ per-day AR upsert（+ 半休 clocked は recalc）→ ④ AttendanceHistory(leave_approved)
  end
end
```

処理順（すべて同一 tx）:

1. **対象日解決**: `CompanyCalendarResolver#day_classifications(start_date..end_date)` → `LeaveDaysCalculator.counted?` と同基準で**計上日**を抽出（balance 消費日と一致）。除外日（土日祝・unpaid company_holiday）は AR を作らない。
2. **残高加算**（§1.4・paid_leave 種別のみ）。
3. **per-day AR upsert**（§1.5）。
4. **`AttendanceHistory(leave_approved)` 追記**（§1.6）。

### 1.4 残高加算（D1・§4.10 ハード拒否）

```ruby
# paid_leave 種別のみ。非 paid は残高加算なし（balance 行も触らない）
return unless leave_request.leave_type.paid_leave?

fiscal_year = leave_request.organization.fiscal_year_for(leave_request.start_date)  # §6.2 年度跨ぎ統一
# UNIQUE [org,user,type,fiscal_year] が単一行を保証。.lock で FOR UPDATE 行ロック（並行承認の二重加算防止）。
# 「行が無い」と「ロック取得」を 1 クエリに集約（行なしは nil → ロック対象なし）
balance = LeaveBalance
  .where(user_id: leave_request.requester_id,
         leave_type_id: leave_request.leave_type_id,
         fiscal_year:)
  .lock.first
# 残高行が無い paid 種別は available=0 扱い → over-balance（D1 の帰結・hr_admin が先に付与）
available = balance ? balance.granted_days + balance.carry_over_days : BigDecimal("0")
used = balance ? balance.used_days : BigDecimal("0")
raise OverBalanceError if used + leave_request.days_requested > available
balance.update!(used_days: used + leave_request.days_requested)
```

- **年度跨ぎ統一**: 加算先は `start_date` 年度の `LeaveBalance` 1 行。日割り分割しない（§6.2）。
- `days_requested > 0` は 2-2a の検証で保証（全除外申請は作成不可）ゆえ、残高行なし paid は常に over-balance（`0 + 正 > 0`）。
- `OverBalanceError` は `Approvals` 名前空間下の既存例外群（`SelfApprovalError` 等）と同所に定義（`app/services/approvals.rb`）。

### 1.5 per-day AR upsert（§13.1 の 2-2b 担当遷移のみ）

各計上日 `date` について `(user_id, work_date: date)` で upsert:

| ケース | status | 既存 AR | 処理 |
|---|---|---|---|
| 全休（`half_day_none?`） | `on_leave` | 無 | create（clock_in/out なし・D4 で検証緩和）。calc 8 列 NULL のまま（recalc 呼ばず） |
| 全休 | `on_leave` | 有（要審査） | **本スライスは create-only 経路を基線**。既存 AR ありの全休は §13.1 非掲載の競合 → `ApplyApproval` は冪等性のため status を on_leave に更新するが、clocked AR への全休上書きは運用上想定外（D5 と同系の後続課題として GOTCHAS 記録） |
| 半休（`morning`/`afternoon`） | `morning_half`/`afternoon_half` | 無 | create（clock_in/out なし）。後続の本人打刻は D5（backlog） |
| 半休 | `morning_half`/`afternoon_half` | 有（working/clocked_out） | update status。**clock_out 済なら `Clockings::Recalculate.call` で LateEarly 上書き**（§1.7） |

- `work_pattern_id`: leave-only AR（打刻無）は §5.4 の計算スキップ対象ゆえ NULL でよい。半休 update で既存 AR は打刻時スナップショットを保持済み（触らない）。
- 月跨ぎ: 各 AR が自分の `work_date` を持つため、月分割計上は構造的に成立（§6.2）。締め済み月ブロックは Phase 3-2 接続（本スライス対象外）。
- **冪等性**: 承認は §13.2 で applying→approved の一方向 + `Approve` の `all_stages_approved?` ゲートゆえ二重発火しない。AR upsert は `find_or_initialize_by(user, work_date)` で再実行安全に書く。

### 1.6 `AttendanceHistory(leave_approved)`

```ruby
AttendanceHistory.create!(
  user_id: leave_request.requester_id,
  actor: acting_user,                # §3.5 オーナー/操作者分離
  source: leave_request,             # polymorphic
  event_type: :leave_approved,       # 既存予約 enum（整数 2）
  event_date: leave_request.start_date  # 代表日（per-day AR とは別に申請単位 1 行）
)
```

- 追記専用（§4.14・3 段不変防御）。同一 tx で書くことが §14 の after_commit seam を v1 で兼ねる（Outbox は将来）。
- **`actor_id` 必須**: 既存 `attendance_history.rb` は `proxy_clock` のみ actor 必須検証。`leave_approved` も actor 必須を本スライスで追記（不変ゆえ事前防御・モデル §2.3）。

### 1.7 `Clockings::Recalculate` の day_part 導出（§B・§5.4 接続）

現状ハードコード `day_part = :full # Phase 2 で status（morning_half 等）から導出` を status 由来へ:

```ruby
day_part =
  case @record.status
  when "morning_half" then :morning_half
  when "afternoon_half" then :afternoon_half
  else :full   # working / clocked_out / on_leave（on_leave は clock 無で recalc 来ない）
  end
```

- `LateEarlyCalculator` は既に `day_part` を受け、`morning_half → 遅刻免除` / `afternoon_half → 早退免除` を実装済（1-2）。
- `WorkTimeCalculator` / `DeepNightCalculator` も `day_part` で休憩按分を切替（既存・1-2）。半休の実労働は半日分の所定で按分される。
- **Recalculate の前提**（「clock_out 設定済・working には呼ばない」）は維持。`ApplyApproval` は半休で `clock_out` 済の AR のみ recalc を呼ぶ。

---

## 2. モデル / スキーマ変更

### 2.1 `AttendanceRecord`（§4.8・enum 拡張 + 条件付き検証）

```ruby
# enum 拡張（整数は §4.8 列挙順の予約どおり。absent:5 は 4-2）
enum :status, { working: 0, clocked_out: 1,
                morning_half: 2, afternoon_half: 3, on_leave: 4 }, validate: true

# D4: 全休/半休 AR は打刻が無いため clock_in を条件付き presence へ
LEAVE_STATUSES = %w[morning_half afternoon_half on_leave].freeze
validates :clock_in, presence: true, unless: :leave_status?
def leave_status? = LEAVE_STATUSES.include?(status)
```

- **マイグレーション（必須・1 点／schema 実機確認済）**: `change_column_null :attendance_records, :clock_in, true`。**DB は現状 `clock_in NOT NULL`** ゆえ、全休/半休 AR（打刻無）の `create!` が DB 層で弾かれる。NOT NULL を外し、モデルの条件付き presence（D4）が working/clocked_out の必須を引き継ぐ二層構成にする。
- status の enum 値追加（2–4）は**アプリ層のみ・migration 不要**（`status` に **CHECK 制約は無い**ことを schema で実機確認・列は integer 既存）。
- `clock_out_not_before_clock_in` は clock_in nil で early return 済ゆえ leave AR でも安全。`Clockings::ClockIn` は常に clock_in を設定するため working AR の不変は条件付き検証で保たれる。
- `calculated` scope（`where.not(actual_work_hours: nil)`）は leave AR（calc NULL）を自然に除外 — 集計が leave-only 日を「未計算」と誤認しない（NULL = 未計算 = 実労働なし、で整合）。

### 2.2 `Approvable` concern（hook + 導出ヘルパ）

```ruby
# 副作用 hook（§1.1）
def apply_approval_effects!(acting_user:) = nil

# 表示用導出（2-2a 後置・§7.2 縮約の可視化）
def single_stage? = approval_assignments.count == 1
def pending_approver
  pos = current_approval_position
  pos && approval_assignments.find_by(position: pos)&.approver
end
```

### 2.3 `AttendanceHistory`（leave_approved の actor 必須）

```ruby
validates :actor_id, presence: true, if: :proxy_clock?    # 既存
validates :actor_id, presence: true, if: :leave_approved? # ★追記（不変ゆえ事前防御）
```

### 2.4 `LeaveRequest`（hook 実装のみ）

§1.1 の `apply_approval_effects!` を追記。他は 2-2a 据置。

---

## 3. 認可（Pundit・D6）

| Policy | 要点 |
|---|---|
| `ApprovalAssignmentPolicy`（追記） | `approve?`/`reject?` は 2-1 実装済（`actionable?`）。**`index? = user.present?`**・**`Scope` を追加**（`scope.where(approver_id: user.id, decision: :pending)`） |

```ruby
class Scope < ApplicationPolicy::Scope
  def resolve = scope.where(approver_id: user.id, decision: :pending)
end
```

- Scope は候補集合（自分が approver の pending）。**actionable 判定（現段階・applying?・自己承認除外）は controller が既存 `policy(assignment).approve?` で絞る** — 段階導出ロジックを SQL に再発明せず authz 単一ソースを保つ。
- 他テナントは `acts_as_tenant` default_scope が遮断。負例: 他者 approver・他テナント・第 2 段階が第 1 未承認で actionable 外・terminal。
- `index` は `policy_scope` + `authorize ApprovalAssignment`（class・既存規約）の両方を呼ぶ。

---

## 4. インボックス + 承認/却下 UI（§E）

### 4.1 ルート / コントローラ

```ruby
# config/routes.rb（追記）
resources :approval_assignments, only: %i[index] do
  member { patch :approve; patch :reject }
end
```

`ApprovalAssignmentsController`:

- **`index`**: `assignments = policy_scope(ApprovalAssignment).includes(:approvable)` → `select { |a| policy(a).approve? }` で actionable のみ。approvable preload で N+1 回避（§16.1 小規模前提）。
- **`approve`**: member 取得は `policy_scope(ApprovalAssignment).find(params[:id])`（他人の assignment を 403 に持ち込まず 404）→ `authorize @assignment, :approve?` → `Approvals::Approve.call(approvable: @assignment.approvable, approver: current_user, comment: params[:comment])`。**`Approvals::OverBalanceError` を rescue → flash「残高不足で承認できません」+ インボックス再描画**（atomic rollback 済ゆえ DB 無変化）。`AASM::InvalidTransition`/`NotCurrentApprover` 等も rescue し「他の承認者が処理済み」を案内。
- **`reject`**: `authorize @assignment, :reject?` → `Approvals::Reject.call(approvable:, approver: current_user, comment: params[:comment])`。comment 必須は service が強制（blank → `ArgumentError` を rescue し再描画）。

### 4.2 描画（approvable_type 別・前方互換）

- インボックス index は actionable assignment を一覧。各 row は **`approvable_type` 別 partial/Component**（`app/components/approvals/leave_request_row_component.*` 等）。CCR(2-3)/HWR(2-4) は自分の row を足すだけ。
- LeaveRequest row 表示: 申請者・休暇種別・期間・`days_requested`・（paid なら残高への影響）・理由・**段階表示**（`single_stage?` なら「単段（独立性なし）」/ 多段なら「第 N 段階」）・承認/却下ボタン。
- 却下は comment textarea 付きフォーム（理由テンプレートチップは申請理由用で却下理由は §6.2 未規定 — YAGNI で見送り）。
- ナビ: 承認待ち件数バッジは Phase 4-1 通知基盤の領分 — 本スライスは静的リンクのみ（送信系を持たない原則）。

---

## 5. テスト戦略（テナント文脈下・`gen-spec` 準拠・★は敵対/負例）

| 種別 | ファイル | 主眼 |
|---|---|---|
| service | `spec/services/leave_requests/apply_approval_spec.rb` | per-day AR upsert（全休 on_leave / 半休 morning/afternoon）・**★除外日は AR 作らない**・**★月跨ぎ＝各 AR が正しい月の work_date**・**★複数日全休の AR 件数 = 計上日数**・残高 lock!+加算・**★over-balance ハード拒否（`OverBalanceError` raise + rollback: AR/balance/history 不変・assignment pending 維持）**・**★残高行なし paid 種別 → over-balance**・**★打刻済半休 clocked_out の recalc（午前半休→is_late=false へ上書き・午後半休→is_early_leave=false）**・**★working（clock_out 未）半休は recalc 呼ばず status のみ**・全休は recalc 呼ばず calc 8 列 NULL・history(leave_approved)（actor=承認者 / source=申請）・**★年度跨ぎ＝start_date 年度の残高に加算（end_date 年度は不変）**・**★非 paid 種別は残高加算なし・balance 行を触らない**・**★冪等（再実行で二重加算なし）** |
| engine | `spec/services/approvals/approve_spec.rb`（追記） | **★hook は最終承認時のみ発火**（2 段の第 1 段階承認では呼ばれない）・**★no-op 既定（テスト専用 approvable が緑）**・単段は発火・**★over-balance で hook が raise → assignment.update! ごと rollback（assignment 再 reload で pending）** |
| model | `spec/models/attendance_record_spec.rb`（追記） | **★clock_in 条件付き検証**（on_leave/morning_half/afternoon_half は nil 可 / working・clocked_out は必須）・新 enum 値 3 種が valid・毒入力 422 |
| model | `spec/models/attendance_history_spec.rb`（追記） | **★leave_approved の actor_id 必須**（nil → 422・不変前防御） |
| model | `spec/models/leave_request_spec.rb`（追記） | `apply_approval_effects!` が `ApplyApproval` へ委譲（薄い・受け渡し検証） |
| service | `spec/services/clockings/recalculate_spec.rb`（追記） | **★day_part が status 由来導出**（morning_half→遅刻免除 / afternoon_half→早退免除 / on_leave・working は full） |
| policy | `spec/policies/approval_assignment_policy_spec.rb`（追記 Scope） | **★Scope = 自分の pending のみ**（他者 approver / 他テナント / terminal=approved・rejected を除外）・index? |
| request | `spec/requests/approval_assignments_spec.rb` | actionable のみ列挙・**承認の一周（approve→AR 生成→残高消費→history・status=approved）**・却下（comment 必須・blank→再描画）・**★over-balance 承認→flash + DB 無変化（AR/balance/history/assignment 全不変）**・**★非承認者 403 / 他テナント assignment 404**・**★第 2 段階が第 1 未承認で承認不可**・**★自己承認 assignment は index に出ない・直接 approve も 403**・**★mass-assignment（approval_status を POST しても無視）** |
| system | `spec/system/leave_approval_spec.rb` | 申請（2-2a）→ 承認者ログイン → インボックス表示 → 承認 → 申請者の勤怠カレンダーに on_leave/半休 反映・残高 2 段階表示の確定残高減（任意・薄く） |

### 完了条件（CLAUDE.md サブエージェント 3 か条）

- `bin/rails db:test:prepare` ／ `bundle exec rspec` 緑 ／ `bundle exec rubocop --force-exclusion <files>` ／ app/ 変更ゆえ `bin/brakeman --no-pager`
- `tenant-isolation-reviewer`（models/services/migration 該当）+ `labor-law-compliance-reviewer`（残高加算・半休 0.5・年度帰属が §8.6/§5.5 と整合か）を merge 前に。フェーズ完了ではないが §6.2 副作用に触れるため `labor-law-compliance-reviewer` は推奨
- PR 前に `/preflight`、**ROADMAP の 2-2b 行を更新（チェック + PR 番号）して PR に含める**

---

## 6. 新規 / 変更ファイル（manifest）

| ファイル | 役割 |
|---|---|
| `app/services/leave_requests/apply_approval.rb` | **新規**。副作用本体（対象日解決・残高 lock!加算・per-day AR upsert・半休 recalc・history） |
| `app/services/approvals.rb`（追記） | `OverBalanceError` 例外を既存例外群へ追加 |
| `app/services/approvals/approve.rb`（追記） | `apply_approval_effects!` hook 呼び出し 1 行 |
| `app/services/clockings/recalculate.rb`（追記） | `day_part` を status 由来導出へ |
| `app/models/concerns/approvable.rb`（追記） | no-op hook・`single_stage?`・`pending_approver` |
| `app/models/leave_request.rb`（追記） | `apply_approval_effects!` 実装 |
| `app/models/attendance_record.rb`（追記） | enum 拡張（3 値）・clock_in 条件付き検証・`leave_status?` |
| `app/models/attendance_history.rb`（追記） | `leave_approved` の actor_id 必須 |
| `app/policies/approval_assignment_policy.rb`（追記） | `Scope`・`index?` |
| `app/controllers/approval_assignments_controller.rb` | **新規**。index/approve/reject（OverBalanceError 等を rescue） |
| `app/components/approvals/**` | **新規**。インボックス + approvable_type 別 row（LeaveRequest） |
| `config/routes.rb`（追記） | `resources :approval_assignments`（index + member approve/reject） |
| `db/migrate/*_allow_null_clock_in_on_attendance_records.rb` | **新規（必須）**。`change_column_null :attendance_records, :clock_in, true`（全休/半休 AR は打刻無・schema 実機確認）。status enum 拡張は CHECK 無しゆえ migration 不要 |
| `spec/**/*_spec.rb` | §5 のカバレッジ |
| `docs/ROADMAP.md`（追記） | 2-2b 行更新 + 横断バックログ（半休打刻連携 D5） |
| `docs/RAILS_GOTCHAS.md`（追記） | with_lock + rescue の文脈別正解（§1.2）・recalc day_part 導出 |

**新規 gem 不要**（aasm/Hotwire/ViewComponent/Pundit/acts_as_tenant は基盤既存）。

---

## 7. RAILS_GOTCHAS 留意（計画・レビューのプロンプトへ注入）

- **with_lock + rescue の文脈別正解（§1.2・最重要）**: 2-2b は副作用を `with_lock` 内・rescue なしで raise 伝播させ承認ごと atomic に巻き戻す（over-balance ハード拒否が正）。1-2 ClockOut→Recalculate は逆に「打刻だけ保全」で失敗後続を隔離。**同じ罠への文脈で正反対の正解** — 機械的コピーを禁ず。
- **acts_as_tenant の fail-closed**: `ApplyApproval` は request 文脈前提だが `ActsAsTenant.with_tenant(organization)` でラップ（`Recalculate` 同型・将来のバッチ化/文脈喪失に fail-closed）。残高・AR・history クエリが他テナントを掴まない。
- **enum `validate: true`**: 新 status 毒入力は 422。
- **AASM 迂回禁止**: `approval_status` は `approve!`（AASM イベント）でのみ遷移。副作用 hook は遷移**後**に呼ぶ（§13.6）。
- **`used_days` writer の単一性**: 2-2a で「2-2b approve 副作用のみ」と宣言済。`ApplyApproval` 以外から `used_days` を書かない（負例テストで pin）。strong params は 2-2a で恒久ブロック済。
- **AttendanceHistory 不変**: `leave_approved` も追記のみ。`create!` のみ・update/destroy は層①②③が拒否。
- **console / rake**: `ActsAsTenant.current_tenant = Organization.find_by!(subdomain: "...")` を先に。
- **rubocop**: ファイル明示渡し時 `--force-exclusion`。
- **schema 手編集禁止**: migration 経由（`block-schema-edit` フック）。status CHECK 拡張が要る場合も migration で。

---

## 8. 後続フェーズ・バックログへの申し送り

1. **半休日への後続打刻（D5・横断バックログ）**: `Clockings::ClockIn` が既存半休 AR（leave 承認で先に作成）へ status を壊さず clock_in を埋める upsert に未対応。現状は半休承認 → 本人が午後を打刻すると `(user, work_date)` unique index 衝突 or 別経路。§13.1 `morning_half → morning_half` 完結は Phase 1 clocking 改修 PR で。ROADMAP 横断バックログ + GOTCHAS に記録。
2. **clocked AR への全休上書き（§1.5）**: 既存打刻ありの日に全休が承認される運用上想定外ケース。§13.1 非掲載。`ApplyApproval` は冪等更新するが、競合検出（打刻済 → 却下推奨）は後続課題。
3. **締め済み月ブロック（§6.2）**: per-day 月分割計上の構造は本スライスで成立。締め状態チェック（`MonthlyAttendanceSummary.finalized` の日付ブロック + 他月正常進行）は Phase 3-2 接続。
4. **撤回の副作用反転（2-5）**: 本設計の hook は approve 経路でのみ発火 = §13.6「`reject_withdrawal` は副作用を撃たない」の下地。2-5 は `withdraw` イベント側に逆操作（used_days 減算・AR 復元・leave_withdrawn）を別 hook で。
5. **承認/却下通知（Phase 4-1）**: 本スライスは送信を持たない。インボックスのバッジ・滞留アラート（§7.5）は通知基盤確立後。
6. **年度帰属 vs 個人基準日（労務・2-2a §11-1 継続）**: `fiscal_year` は管理バケツ。繰越・失効は `granted_on` / 2 年時効基準（Phase 4-4）。本スライスの加算は `start_date` 年度統一で §6.2 準拠・実害なし。
