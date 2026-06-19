# Phase 2-3 ClockChangeRequest（打刻変更申請）— 設計

- 日付: 2026-06-18
- スライス: ROADMAP Phase 2-3（1 スライス = 1 ブランチ = 1 PR・`feat/phase2-3-clock-change-request`）
- 典拠: SPEC §4.11（ClockChangeRequest）・§6.3（打刻時刻変更依頼）・§7.4（競合チェック）・§13.1（AttendanceRecord.status）・§13.2（approval_status AASM）・§13.5/§13.6（連携・イベント副作用）・§4.14（AttendanceHistory 前後値）・§3.4–3.6（認可・テナント分離）
- 前提エンジン: Phase 2-1（承認エンジン）+ 2-2a/2-2b（`Approvable` hook・`Approvals::Approve/Reject/Start/Cancel`・`ApplyApproval` パターン・承認インボックス・`Clockings::Recalculate`）はすべて据付・merge 済（main = 2-2b 完了）
- **本設計のブレスト確定事項（2026-06-18・`superpowers:brainstorming`）**: 下記 D1–D7 をユーザー承認済み

## 0. スコープと前提

2-2b で承認の副作用パターン（汎用エンジン hook → host 別 `ApplyApproval` service・同一 tx・atomic rollback）と承認インボックスが確立した。2-3 は **2 つ目の承認対象 `ClockChangeRequest`（CCR）** を投入し、「社員が既存打刻の時刻変更を申請 → 2 段承認 → 競合チェック付きで記録更新・再計算・履歴まで一周」させる。

CCR 固有の新ロジックは **§7.4 競合チェック**（申請時 snapshot と承認時の現記録の照合）に局所化される。残高・年度・並行加算が無いため 2-2b より低リスク。承認エンジン（Start/Approve/Reject/**Cancel**）は対象非依存ゆえ**全面再利用**（CCR は model + hook + 側作用 + 申請 UI + インボックス行のみ追加）。

完了条件: 打刻変更が **申請 → 2 段承認 → 競合チェック → 記録時刻更新 + §5 再計算 + 前後値つき AttendanceHistory まで一周**する。撤回での復元は 2-5。

### 設計判断ログ

| # | 論点 | 決定 | 根拠 |
|---|------|------|------|
| D1 | `new_entry`（欠勤日への打刻追加）の扱い | **4-2 へ後置**。2-3 は clock_in / clock_out / both（既存記録の時刻変更）に集中 | new_entry の対象は `status=absent` 日（§4.11）だが `absent`（整数 5）は 4-2 まで不在。2-2a/2-2b の事後有給後置と同型。change_type に new_entry を予約値として置きつつ Create/側作用は 3 型のみ処理 |
| D2 | スライス構造 | **1 スライス = 1 PR**（a/b 分割しない） | 残高・並行制御が無く側作用が単純。エンジン/hook→service/Recalculate/インボックス基盤が既存ゆえ 2-2 より低リスク。肥大したら request/approve に割れるが縦一本で十分 |
| D3 | 側作用の配置 | **2-2b approach B 踏襲**: 汎用エンジンが最終承認時に host hook `apply_approval_effects!` → `ClockChangeRequests::ApplyApproval` へ委譲。同一 `with_lock`/tx・内側 rescue なし | §13.6 イベント束縛を service 層で実現。CCR の hook は ClockChangeRequest が override |
| D4 | §7.4 競合チェック | **Create が `original_clock_in/out` を記録から snapshot（サーバ権威）→ 承認時に `FOR UPDATE` ロック下で現記録と両フィールド厳密照合・不一致なら `ConflictError`** | §7.4。楽観ロック的。ConflictError は raise 伝播で承認ごと atomic rollback（2-2b OverBalanceError 同型） |
| D5 | CCR が status を変えるか | **不変**（時刻のみ修正） | §13.1 が CCR を `clocked_out → clocked_out`（時刻修正・status 維持）と定義。new_entry の absent→working/clocked_out は 4-2 |
| D6 | AttendanceHistory の前後値 | **`clock_change_approved` は前後値カラムを埋める**（previous/new の clock_in/out・status・is_late/late_minutes・is_early_leave/early_leave_minutes） | schema に前後値カラム完備（§4.14）。完全な監査証跡 + 2-5 撤回復元の土台。2-2b leave_approved は未充填（別途バックログ・§8） |
| D7 | エンジン再利用 | **Start/Approve/Reject/Cancel を全面再利用**（対象非依存） | `Approvals::Cancel` は `by==requester` + `cancel!`、`Start` は `requester.manager` 遡行ゆえ CCR でそのまま動く。CCR 専用の承認/取消サービスを作らない（YAGNI） |

### 本スライスに含めない（明示的後置）

- **`new_entry`**（欠勤日への打刻追加）→ **4-2**（absent 依存・D1）
- **撤回フロー**（withdrawal_requested / withdrawn・履歴参照復元）→ **2-5**。D6 の前後値充填が復元の土台。`withdrawal_reason` / `last_stale_notified_on` 列は本スライスで置くが消費は 2-5
- **承認/却下/滞留の通知送信**（§7.4 の承認者通知含む）→ **Phase 4-1**（通知基盤確立まで・ROADMAP 横断ルール）。本スライスは flash で代替
- **leave_approved 履歴の前後値遡及充填** → バックログ（§8・2-2b の under-fill・scope 外）
- **型別 preload 最適化**（インボックス表示 N+1）→ バックログ継続（§16.1 許容）

---

## 1. モデル / スキーマ

### 1.1 `ClockChangeRequest`（§4.11・`include Approvable`）

#### マイグレーション `clock_change_requests`

| カラム | 型 | 制約 | 説明 |
|---|---|---|---|
| `organization_id` | bigint | NOT NULL | テナント（§3.6） |
| `requester_id` | bigint | NOT NULL | 申請者（User） |
| `attendance_record_id` | bigint | NULL 可 | 対象記録（new_entry は null・本スライスは常に非 null） |
| `change_type` | integer (enum) | NOT NULL | `clock_in:0 / clock_out:1 / both:2 / new_entry:3`（3 は予約・4-2 消費） |
| `target_date` | date | NULL | new_entry 必須（本スライス未使用・予約） |
| `original_clock_in` / `original_clock_out` | timestamptz | NULL 可 | Create が記録から snapshot（競合チェック用・サーバ権威） |
| `new_clock_in` / `new_clock_out` | timestamptz | NULL 可 | 変更後（change_type に応じ必須） |
| `reason` | text | NULL（モデルで presence） | 変更理由（§6.3 必須） |
| `approval_status` | integer (enum) | NOT NULL default 0 | `Approvable`（applying:0 … canceled:3） |
| `withdrawal_reason` | text | NULL | 撤回理由（2-5 消費・予約） |
| `last_stale_notified_on` | date | NULL | 滞留アラート重複防止（Phase 4 消費・予約） |

#### インデックス & 参照整合（§3.6 二層防御）

- **複合 FK** `(organization_id, requester_id) → users(organization_id, id)`
- **複合 FK** `(organization_id, attendance_record_id) → attendance_records(organization_id, id)`（`attendance_records` の `[organization_id, id]` unique index は既存）
- **UNIQUE** `[organization_id, id]`（org-scoped find・他モデル同型）
- **INDEX** `[organization_id, requester_id, approval_status]`（自分の申請一覧）

#### モデル

```ruby
class ClockChangeRequest < ApplicationRecord
  acts_as_tenant(:organization)
  belongs_to :requester, class_name: "User"
  belongs_to :attendance_record, optional: true   # new_entry は null（本スライスは非 null）
  include Approvable   # approval_status AASM + has_many :approval_assignments

  enum :change_type, { clock_in: 0, clock_out: 1, both: 2, new_entry: 3 },
       validate: true, prefix: :change   # 述語 change_clock_in? 等（none 衝突回避と同思想）

  validates :reason, presence: true
  validate :new_times_present_for_change_type   # change_type 別 new_clock_* presence
  validate :new_clock_out_after_in              # both 時 new_out > new_in
  validate :target_record_not_on_leave          # §4.11 全休日への変更禁止
  validate :target_record_clocked_out           # clock_out 済記録に限定（working 除外）
  validate :requester_owns_target_record        # requester == record.user
  validate :requester_must_belong_to_same_organization   # ID 基点 fail-closed
  validate :attendance_record_must_belong_to_same_organization
end
```

- **change_type 別 new_clock_* presence**（本スライスは 3 型）:
  - `change_clock_in?` → `new_clock_in` 必須
  - `change_clock_out?` → `new_clock_out` 必須
  - `change_both?` → 両方必須
  - `change_new_entry?` は本スライス未到達（Create が弾く・4-2 で実装）
- **both で `new_clock_out > new_clock_in`**（同日内の整合）。
- **全休日への変更禁止**（§4.11）: `attendance_record&.on_leave?` なら拒否。
- **clock_out 済記録に限定**: `attendance_record && attendance_record.clock_out.nil?` を拒否（working＝勤務中・打刻未完を除外）。CCR は clocked_out / 打刻済半休の時刻補正に限る（§13.1 `clocked_out → clocked_out`・calc 8 列が NULL のまま埋まる §4.8 不変条件抵触を防ぐ）。working 記録の clock_in 補正は退勤後に申請（§8-6）。
- **requester 所有**: `attendance_record && attendance_record.user_id != requester_id` を拒否（他人の記録への申請を構造ブロック・IDOR 防御の一層）。
- **テナント越境ガードは ID 基点で fail-closed**（`requester` / `attendance_record` 両方・`leave_request.rb` 同型）。
- `original_*` / `new_*` / `approval_status` は **strong params 恒久ブロック**（writer は `ClockChangeRequests::Create` のみ＝サーバ権威。AASM 迂回防止）。

### 1.2 `AttendanceHistory`（clock_change_approved の actor 必須・追記）

```ruby
validates :actor_id, presence: true, if: :clock_change_approved?   # 2-3（不変ゆえ事前防御・proxy_clock/leave_approved 同型）
```

---

## 2. 側作用 ── `ClockChangeRequests::ApplyApproval`（D3・approach B）

`ClockChangeRequest#apply_approval_effects!(acting_user:)` が委譲。**`Approvals::Approve` の `with_lock` 内・同一 tx・内側 rescue なし**（`ConflictError` は raise 伝播 → assignment 承認ごと atomic rollback → controller rescue）。

```ruby
# app/services/clock_change_requests/apply_approval.rb
module ClockChangeRequests
  class ApplyApproval
    def self.call(clock_change_request:, acting_user:) = new(...).call

    def call
      ActsAsTenant.with_tenant(@ccr.organization) do
        record = AttendanceRecord.lock.find(@ccr.attendance_record_id)   # FOR UPDATE（並行変更の直列化）
        check_conflict!(record)        # §7.4
        before = snapshot(record)      # 前後値の「前」
        apply_times!(record)           # change_type 別に clock_in/out 更新（status 不変）
        record.save!
        Clockings::Recalculate.call(record:) if record.clock_out.present?   # §5 再計算
        record_history(record, before) # clock_change_approved（前後値つき・D6）
      end
      @ccr
    end

    private

    # §7.4: snapshot（Create 時の original_*）と現記録を厳密照合。不一致 = 申請後に誰かが変更 → 承認不可
    def check_conflict!(record)
      return if record.clock_in == @ccr.original_clock_in &&
                record.clock_out == @ccr.original_clock_out

      raise Approvals::ConflictError
    end

    def apply_times!(record)
      record.clock_in  = @ccr.new_clock_in  if @ccr.change_clock_in? || @ccr.change_both?
      record.clock_out = @ccr.new_clock_out if @ccr.change_clock_out? || @ccr.change_both?
    end

    def snapshot(record)
      record.slice(:clock_in, :clock_out, :status,
                   :is_late, :late_minutes, :is_early_leave, :early_leave_minutes)
    end

    def record_history(record, before)
      record.reload   # recalc 後の確定値（after）
      AttendanceHistory.create!(
        user_id: record.user_id, actor: @acting_user, source: @ccr,
        event_type: :clock_change_approved, event_date: record.work_date,
        previous_clock_in: before["clock_in"], new_clock_in: record.clock_in,
        previous_clock_out: before["clock_out"], new_clock_out: record.clock_out,
        previous_status: before["status"], new_status: record.status,
        previous_is_late: before["is_late"], new_is_late: record.is_late,
        previous_late_minutes: before["late_minutes"], new_late_minutes: record.late_minutes,
        previous_is_early_leave: before["is_early_leave"], new_is_early_leave: record.is_early_leave,
        previous_early_leave_minutes: before["early_leave_minutes"],
        new_early_leave_minutes: record.early_leave_minutes
      )
    end
  end
end
```

- **`Approvals::ConflictError < Approvals::Error`**（`approvals.rb` の `OverBalanceError` 同所）。controller rescue → flash「変更前時刻が現在の記録と一致しません」（§7.4・承認者通知は Phase 4-1）。
- **timestamptz 厳密比較の罠（設計注・plan で固定）**: `original_*` は Create 時に `record.clock_in`（DB 値・usec 保持）を snapshot し timestamptz 列へ round-trip（Postgres timestamptz は usec 保持）。承認時の `record.clock_in` も同列型ゆえ未変更なら `==` で厳密一致。**新たに `Time.parse` した値と比較しない**（精度差で偽不一致）。両者とも DB 由来の `ActiveSupport::TimeWithZone` を比較する。
- **status 不変（D5）**: `apply_times!` は status を触らない。`previous_status == new_status`（記録のため両取得）。recalc が is_late 等を更新するため calc 系の前後は差が出る。
- **recalc 前提維持**: CCR 対象は clock_out 済記録に限定（§1.1 検証）ゆえ recalc は常に実行される。`Clockings::Recalculate` は work_pattern snapshot 済の既存 clocked 記録で動く（`record.clock_out.present?` ガードは防御的に残す）。

---

## 3. 申請側（employee-facing・2-2a 同型）

### 3.1 `ClockChangeRequests::Create`（command・1 tx・Start 起動）

```ruby
# def self.call(requester:, attendance_record:, change_type:, new_clock_in:, new_clock_out:, reason:)
# requester は controller が current_user を渡す（params 由来の id を受けない・MPR C3）
ActiveRecord::Base.transaction do
  ccr = ClockChangeRequest.create!(
    requester:, attendance_record:, change_type:, reason:,
    new_clock_in:, new_clock_out:,
    original_clock_in: attendance_record.clock_in,    # ★snapshot（サーバ権威）
    original_clock_out: attendance_record.clock_out
  )
  Approvals::Start.call(ccr)   # ルート解決 + pending assignment（既存エンジン）
  ccr
end
```

- `original_*` は **Create で記録から確定**（client の hidden field 不使用）。
- `Approvals::Start` の `RouteError`（manager 未設定）→ tx rollback →「申請不可・セットアップ要」を構造表現（host・assignment 未永続）。

### 3.2 `ClockChangeRequestsController`（index / new / create / cancel）

- パス `/clock_change_requests`。**`requester = current_user` 構造固定**（params の requester_id/user_id 不受理）。
- **`new`**: 対象記録 id を受け **`policy_scope(AttendanceRecord).find(params[:attendance_record_id])`**（自分の記録に限定・scope 外 404・IDOR 防止）→ 現在時刻を表示し change_type + new_clock_* + reason のフォーム。
- **理由テンプレートチップ**（§6.3）: `ReasonTemplate`（`applies_to: clock_change / both`・実在確認済 enum 0/2）をチップ表示。Stimulus でチップ → textarea 追記（2-2a の `leave_request_form_controller` 同型・流用検討）。
- **`create`**: `ClockChangeRequests::Create.call(requester: current_user, attendance_record: <policy_scoped>, ...)`。`RouteError` / `RecordInvalid` / `ArgumentError(Date::Error)` を 2-2a controller 同型に rescue。
- **`cancel`**: `authorize @ccr, :cancel?` → **`Approvals::Cancel.call(approvable: @ccr, by: current_user)`**（再利用）→ flash。`AASM::InvalidTransition` rescue。
- member 取得は **`policy_scope(ClockChangeRequest).find`**（404 二層）。

### 3.3 `ClockChangeRequestPolicy`（LeaveRequestPolicy 同型）

```ruby
class ClockChangeRequestPolicy < ApplicationPolicy
  def index? = user.present?
  def new? = user.present?
  def create? = user.present?
  def cancel? = record.requester_id == user.id && record.applying?

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(requester_id: user.id)
  end
end
```

---

## 4. インボックス CCR 行（2-2b 基盤への最小追加）

- `app/views/approval_assignments/index.html.erb` の `case` に **`when ClockChangeRequest` → `Approvals::ClockChangeRequestRowComponent`** を追加。`includes(:approvable)` は **nested preload 無し**（2-2b I-1 で確定）ゆえ CCR 混在でクラッシュしない。
- **`ApprovalAssignmentsController#approve` に `Approvals::ConflictError` rescue を追加** → flash「変更前時刻が現在の記録と一致しません」。既存 `OverBalanceError` rescue と並列（両者 `Approvals::Error` 配下・型別 flash）。
- CCR 行 Component 表示: 申請者・対象記録日（`@ccr.attendance_record.work_date`）・change_type ラベル・**original → new 時刻**・理由・段階（`single_stage?`）・承認/却下フォーム（LeaveRequestRowComponent 同型）。
- 表示 N+1（CCR の requester / attendance_record）は §16.1 許容・型別 preload はバックログ継続。

---

## 5. テスト戦略（テナント文脈下・`gen-spec` 準拠・★は敵対/負例）

| 種別 | ファイル | 主眼 |
|---|---|---|
| model | `spec/models/clock_change_request_spec.rb` | change_type 別 new_clock_* presence（clock_in/clock_out/both）・**★both で new_out ≤ new_in 拒否**・**★on_leave 記録への変更拒否**・**★working 記録（clock_out 無）拒否 + clocked_out は許可**・**★他人記録（user≠requester）拒否**・reason 必須・テナント越境（**★requester / attendance_record × association + 整数 ID 直接代入**）・enum 毒入力 422・**★original_*/new_*/approval_status の mass-assignment 遮断** |
| model | `spec/models/attendance_history_spec.rb`（追記） | **★clock_change_approved の actor_id 必須** |
| service | `spec/services/clock_change_requests/create_spec.rb` | **★original_* を記録から snapshot**（client 値不使用）・`Approvals::Start` 連動（assignment 生成）・**★RouteError 時 CCR/assignment 双方不変**・requester=current_user 固定 |
| service | `spec/services/clock_change_requests/apply_approval_spec.rb` | 競合 pass で時刻更新（**★clock_in / clock_out / both 各 change_type**）+ recalc（is_late 等の再計算）+ history・**★競合（original≠現在）→ ConflictError + rollback（記録/履歴/assignment 不変）**・**★timestamptz 厳密比較（未変更で偽 ConflictError を出さない・usec 保持）**・**★status 不変・前後値カラム充填（previous/new の clock+status+late/early）**・FOR UPDATE ロック（`clock_out_spec` の receive(:lock) パターン流用可） |
| engine | `spec/services/approvals/approve_spec.rb`（追記・任意） | CCR host でも hook 発火（`apply_approval_effects!` 委譲。2-2b の generic hook spec で実証済ゆえ薄く） |
| policy | `spec/policies/clock_change_request_policy_spec.rb` | 本人 Scope・index?/new?/cancel?（applying のみ・terminal forbid）・第三者/他テナント forbid |
| request | `spec/requests/clock_change_requests_spec.rb` | フォーム（**★自分の記録のみ・他人記録 404**）・create（snapshot・**★mass-assignment 遮断**）・取消（`Approvals::Cancel`）・index 自分のみ |
| request | `spec/requests/approval_assignments_spec.rb`（追記） | **CCR 承認の一周（approve→時刻更新→recalc→history・status approved）**・**★競合承認→flash「変更前時刻が…」+ DB 無変化（記録/履歴/assignment 不変）**・却下・**★CCR 行が型別描画（LeaveRequest と混在で両方出る）** |
| component | `spec/components/approvals/clock_change_request_row_component_spec.rb` | original→new 時刻・change_type ラベル・段階表示・承認/却下ボタン描画 |

### 完了条件（CLAUDE.md サブエージェント 3 か条）

- `bin/rails db:test:prepare` ／ `bundle exec rspec` 緑 ／ `bundle exec rubocop --force-exclusion <files>` ／ app/ 変更ゆえ `bin/brakeman --no-pager`
- `tenant-isolation-reviewer`（model/service/migration）+ `/spec-check`（Phase 2 完了の一歩前ゆえ任意）
- PR 前に `/preflight`、**ROADMAP の 2-3 行更新（チェック + PR 番号）を PR に含める**

---

## 6. 新規 / 変更ファイル（manifest）

| ファイル | 役割 |
|---|---|
| `db/migrate/*_create_clock_change_requests.rb` | テーブル + 複合 FK + index |
| `app/models/clock_change_request.rb` | 申請モデル（Approvable・change_type 別検証・全休拒否・所有検証・テナント） |
| `app/models/attendance_history.rb`（追記） | `clock_change_approved` の actor 必須 |
| `app/services/clock_change_requests/create.rb` | 申請作成（original_* snapshot・1 tx・Start 起動） |
| `app/services/clock_change_requests/apply_approval.rb` | 側作用（競合チェック・時刻更新・recalc・前後値 history） |
| `app/services/approvals.rb`（追記） | `ConflictError < Error` |
| `app/controllers/clock_change_requests_controller.rb` | index/new/create/cancel（requester 固定・Cancel 再利用） |
| `app/controllers/approval_assignments_controller.rb`（追記） | approve に `ConflictError` rescue |
| `app/policies/clock_change_request_policy.rb` | 本人 Scope・index?/new?/cancel? |
| `app/components/approvals/clock_change_request_row_component.{rb,html.erb}` | インボックス CCR 行 |
| `app/views/approval_assignments/index.html.erb`（追記） | `when ClockChangeRequest` dispatch |
| `app/views/clock_change_requests/**` | 申請フォーム・一覧 |
| `app/javascript/controllers/*`（任意） | 理由チップ（2-2a 流用 or 共通化） |
| `config/routes.rb`（追記） | `resources :clock_change_requests`（index/new/create + member cancel） |
| `spec/**/*_spec.rb` | §5 のカバレッジ |

**新規 gem 不要**。

---

## 7. RAILS_GOTCHAS 留意（計画・レビューのプロンプトへ注入）

- **with_lock + rescue の文脈別正解（2-2b GOTCHAS）**: CCR も `ConflictError` を rescue せず raise 伝播させ承認ごと atomic rollback（競合なら変更を一切残さないのが正）。1-2 ClockOut の「打刻保全で隔離」とは逆。
- **timestamptz 厳密比較（§2 設計注）**: snapshot と現記録は DB 由来値同士で比較。`Time.parse` 値や精度を落とした値と比較しない（偽 ConflictError 防止）。
- **acts_as_tenant fail-closed**: 越境ガードは ID 基点（`*_id.nil?` early return → association 比較）。`ApplyApproval` は `with_tenant` 明示ラップ（Recalculate 同型）。
- **Pundit 非経由のリーダー**: `Create` の `attendance_record` は controller が `policy_scope(AttendanceRecord).find` で渡す（他人記録の混入を構造ブロック）。
- **enum `validate: true`**: 毒入力は 422。**AASM 迂回禁止**: approval_status は `approve!`/`cancel!` のみ。
- **console / rake**: `ActsAsTenant.current_tenant = ...` を先に。**rubocop**: 明示渡し `--force-exclusion`。**schema 手編集禁止**（migration 経由）。
- **インボックス preload**: `includes(:approvable)` を維持（nested 化すると型混在で `AssociationNotFoundError`・2-2b I-1）。

---

## 8. 後続フェーズ・バックログへの申し送り

1. **new_entry（4-2）**: absent 日への打刻追加。change_type=new_entry + target_date を消費し、absent→working/clocked_out（§13.1）。本スライスで予約値・列を置済。
2. **撤回フロー（2-5）**: CCR の `clock_change_approved` 前後値（D6）を参照し記録時刻を復元 + 再計算 + leave/clock_withdrawn 履歴。`withdrawal_reason` 列は本スライスで予約。`reject_withdrawal`（approved 復帰）は副作用を撃たない（§13.6・hook が approve 経路のみ発火する構造が下地）。
3. **承認者通知（§7.4・Phase 4-1）**: 競合時の承認者通知・滞留アラート（`last_stale_notified_on`）。本スライスは flash 代替。
4. **leave_approved 履歴の前後値遡及充填**: 2-2b の `leave_approved` は前後値カラム未充填（source=LeaveRequest 参照で代替）。§4.14 の完全性のため、前後値（previous=変更前 AR state / new=on_leave 等）を充填するか後続で判断（低優先・実害なし）。
5. **型別 preload 最適化**: インボックス表示 N+1（§16.1 許容）。承認対象型が増えた本スライス以降、型別 conditional preload を導入するか再判断。
6. **working 記録の時刻補正**: 本スライスは clock_out 済記録に限定（§1.1）。勤務中（working）記録の clock_in 補正（§6.3 は文面上許容）は、退勤後に CCR する運用で代替。専用対応（working→clocked_out 遷移を含む）の要否は後続で判断（§13.1 は CCR を clocked_out→clocked_out と定義）。
