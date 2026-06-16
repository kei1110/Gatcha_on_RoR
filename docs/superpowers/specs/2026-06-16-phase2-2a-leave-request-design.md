# Phase 2-2a 休暇申請 + 残高（申請側）— 設計

- 日付: 2026-06-16
- スライス: ROADMAP Phase 2-2 を **2-2a（申請側）/ 2-2b（承認+副作用）** に分割した前半
- 1 スライス = 1 ブランチ = 1 PR（`feat/phase2-2a-leave-request`）
- 典拠: SPEC §4.9–4.10（LeaveRequest / LeaveBalance）・§5.5（LeaveDaysCalculator）・§6.2（休暇申請）・§7.1/§7.7（承認エンジン起動）・§13.2（AASM）・§3.6（テナント分離）・§2.2（アーキ原則）
- 前提エンジン: Phase 2-1（`ApprovalAssignment` / `Approvable` concern / `Approvals::Start/Approve/Reject` / `RouteResolver` / `SelfApproval`）は据付済み。本スライスは 2-1 が後置した「`Approvals::Cancel` + `cancel?` Pundit」を回収し、申請対象モデルを初投入する

## 0. スコープと前提

ROADMAP の Phase 2-2（`LeaveRequest + LeaveBalance`）は実質「①データ+純計算 / ②申請側 UI / ③承認側+副作用」の三塊を抱える。③にドメイン risk（テナント分離・残高並行制御・締め判定）が集中するため、**2-2a（申請側）/ 2-2b（承認+副作用）へ分割**し、各サブスライスを独自の spec→plan→PR サイクルで進める（本書は 2-2a）。

2-2a は「**社員が休暇を申請・取消でき、hr_admin が残高を付与できる**」までを縦に通す。承認決裁は 2-2a 時点では未接続（`approval_status` は `applying` のまま積まれる）が、**承認エンジンの起動（ルート解決 + `ApprovalAssignment` 生成）は 2-2a で行う**（§7.7・後段 §3.2）。

### 設計判断ログ（ブレインストームでの決定）

| # | 論点 | 決定 |
|---|------|------|
| D1 | 2-2 のスコープ | **分割**（2-2a 申請側 / 2-2b 承認+副作用）。③のドメイン risk を独立 PR に隔離しレビュー（`tenant-isolation-reviewer` / with_lock 罠）を集中 |
| D2 | `LeaveBalance` の残高付与経路（39 条自動付与は Phase 4 固定） | **hr_admin 残高 CRUD を 2-2a に同梱**。申請フォームの残高 2 段階表示が完結し、本番でも人事が付与できる。複雑な 39 条自動付与・年度更新は §8.6 / Phase 4-4 |
| D3 | 申請フォームのリアルタイム日数表示 | **A: サーバ往復（debounce fetch）**。所定休日分類はサーバ側 `CompanyCalendar` 一択ゆえ、`LeaveDaysCalculator` を唯一の真実源に保ち、提出時 `days_requested` と表示を一致させる。B（クライアント JS 二重実装）は §2.2 越え・drift 源ゆえ却下 |
| D4 | `fiscal_year_end_month` 変更禁止の格上げ（ROADMAP が 2-2 着手時の再判断と明記・社労士確認 #13） | **格上げ：残高が存在したら変更禁止**。`LeaveBalance` が `fiscal_year` をキーに持ち始めると決算月変更が残高帰属を破壊するため、残高誕生地の 2-2a で窓を閉じる |
| F1（強制） | `LeaveDaysCalculator` の所定労働日の源 | **カレンダー駆動で確定**（選択の余地なし）。`WorkPattern` は曜日別稼働日カラムを持たず、所定休日の判定源は `CompanyCalendar`（組織横断）一択。土曜稼働組織は当該土曜を `weekday` 登録して §5.5 但し書きを満たす |
| F2 | 見積りの単一ソース | **`LeaveRequests::Estimate`** に「日数 + 確定/仮残高 + 申請後残日数」を集約。フォーム初期描画・preview エンドポイント・`Create` の 3 箇所が共有（drift 防止） |

### 本スライスに含めない（2-2b へ明示的後置）

- **`approve` 副作用一式**（§6.2・§13.6）: 対象日 `AttendanceRecord` 作成/更新（on_leave / morning_half / afternoon_half）・`LateEarly` 再計算・`LeaveBalance.used_days` の `lock!` 加算・`AttendanceHistory(leave_approved)` 記録 → **2-2b**
- 承認インボックス UI・`ApprovalAssignmentPolicy::Scope`・導出ヘルパ `single_stage?` / `pending_approver`・却下 UI → **2-2b**
- **`AttendanceRecord.status` enum 拡張**（morning_half:2 / afternoon_half:3 / on_leave:4）→ **2-2b**（書き込み主体＝副作用と同居・消費スライス同梱原則）
- **月跨ぎ/年度跨ぎ**（§6.2）: 年度跨ぎ加算統一は `used_days` writer と同じ **2-2b**。月跨ぎの「締め済み月のみブロック」は **Phase 3（`MonthlyAttendanceSummary`）依存**ゆえ、2-2b でも per-day 月分割計上の構造までで締めチェックは Phase 3 接続（スライス跨ぎ依存を 2-2b brainstorm へ申し送り）
- **事後有給**（absent→on_leave・§6.2）: `absent` status が **4-2** まで存在しないため、さらに後置
- 撤回フロー（withdrawal_requested / withdrawn）→ **2-5**。`withdrawal_reason` / `last_stale_notified_on` 列も消費スライスで追加（0b-5「消費 Phase が列を同梱」方式）

---

## 1. モデル / スキーマ

### 1.1 `LeaveRequest`（§4.9・`include Approvable`）

承認対象モデルの初投入。`Approvable` concern（2-1）を include し、業務ステータスを AASM で持つ。host 契約（`acts_as_tenant` + `belongs_to :requester`）を満たす。

#### マイグレーション `leave_requests`

| カラム | 型 | 制約 | 説明 |
|---|---|---|---|
| `organization_id` | bigint | NOT NULL | テナント（付随明示・§3.6） |
| `requester_id` | bigint | NOT NULL | 申請者（User） |
| `leave_type_id` | bigint | NOT NULL | 休暇種別 |
| `start_date` / `end_date` | date | NOT NULL | 期間 |
| `half_day_type` | integer (enum) | NOT NULL default 0 | none(0) / morning(1) / afternoon(2) |
| `days_requested` | decimal(6,2) | NOT NULL | 取得日数（サーバ算出・§5.5） |
| `reason` | text | NULL | 申請理由 |
| `approval_status` | integer (enum) | NOT NULL default 0 | `Approvable`（applying:0 … canceled:3） |
| `created_at` / `updated_at` | timestamptz | NOT NULL | |

#### インデックス & 参照整合（§3.6 二層防御）

- **複合 FK** `(organization_id, requester_id) → users(organization_id, id)`（`user_work_patterns` migration を参照実装に）
- **複合 FK** `(organization_id, leave_type_id) → leave_types(organization_id, id)`（leave_types に `[organization_id, id]` unique index が無ければ同 migration で追加）
- **INDEX** `[organization_id, requester_id, approval_status]`（自分の申請一覧 + 仮残高の applying 集計）
- **INDEX** `[organization_id, requester_id, leave_type_id, start_date]`（仮残高の年度別 applying 集計）

#### モデル

```ruby
class LeaveRequest < ApplicationRecord
  acts_as_tenant(:organization)
  belongs_to :requester, class_name: "User"
  belongs_to :leave_type
  include Approvable   # approval_status の AASM + has_many :approval_assignments

  enum :half_day_type, { none: 0, morning: 1, afternoon: 2 }, validate: true

  validates :start_date, :end_date, :days_requested, presence: true
  validates :days_requested, numericality: { greater_than_or_equal_to: 0 }
  validate :end_date_not_before_start_date
  validate :half_day_requires_single_day              # §4.9 半休排他
  validate :requester_must_belong_to_same_organization   # ID 基点 fail-closed（user.rb 同型）
  validate :leave_type_must_belong_to_same_organization
end
```

- **半休排他**（§4.9）: `half_day_type != none` のとき `start_date == end_date` 必須。
- **テナント越境ガードは ID 基点で fail-closed**（`attendance_history.rb` / `user.rb` と同型 — `*_id` が立っていれば、acts_as_tenant が association を nil 解決しても能動エラー化）。
- `days_requested` は **strong params に載せない**。唯一の writer は `LeaveRequests::Create`（サーバが Estimate で確定）。`approval_status` も strong params 恒久ブロック（2-1 §2 #5・AASM 迂回防止）。

### 1.2 `LeaveBalance`（§4.10）

#### マイグレーション `leave_balances`

| カラム | 型 | 制約 | 説明 |
|---|---|---|---|
| `organization_id` | bigint | NOT NULL | テナント |
| `user_id` | bigint | NOT NULL | 対象社員 |
| `leave_type_id` | bigint | NOT NULL | 対象種別 |
| `fiscal_year` | string | NOT NULL | `Organization#fiscal_year_for` の返り値型に一致 |
| `granted_days` | decimal | NOT NULL default 0 | 当年度新規付与 |
| `carry_over_days` | decimal | NOT NULL default 0 | 前年度繰越（年度更新ジョブ＝Phase 4-4 が設定） |
| `used_days` | decimal | NOT NULL default 0 | 使用済（**2-2b の approve 副作用が唯一の writer・`lock!`**） |
| `granted_on` | date | NULL | 有給付与日（5 日義務起点・§8.6 で消費） |

- **UNIQUE** `[organization_id, user_id, leave_type_id, fiscal_year]`
- **複合 FK** `(organization_id, user_id) → users` / `(organization_id, leave_type_id) → leave_types`
- **残日数 = `granted_days + carry_over_days - used_days`**（メソッド採用）。§4.10 が許す STORED 生成列は v1 では見送り（migration 簡素・writer が 2-2b のみで生成列の COALESCE 配慮も不要）。
- **取得義務期限**（`granted_on + 365`・期限超過判定）は §8.6 / Phase 4 で消費。2-2a はカラムを置くのみ。
- テナント越境ガードは LeaveRequest と同型（ID 基点 fail-closed）。
- `used_days` は 2-2a では常に default 0（加算経路が無い）。残高表示は 0 前提でも正しく動く。

---

## 2. 純計算 — `LeaveDaysCalculator` + Resolver 拡張

### 2.1 `LeaveDaysCalculator`（§5.5・`app/calculators/`・純関数）

```ruby
# 値→値（DB 非依存）。AR 依存の入力合成は service 層が担う（§2.2-1 境界）
LeaveDaysCalculator.call(classifications:, half_day_type:) → BigDecimal
```

- 入力 `classifications` = `{ Date => { day_type: Symbol, counts_as_paid_leave: Boolean } }`（**値**として渡す）。
- **除外**: `saturday` / `sunday`（所定休日曜日）/ `holiday` / `legal_holiday` / `company_holiday` かつ `counts_as_paid_leave == false`。
- **計上**: `weekday`、および `company_holiday` かつ `counts_as_paid_leave == true`。
- **半休**（`half_day_type != none`）: 上流で `start == end` を強制済ゆえ単日。当該日が計上対象なら 0.5、除外日なら 0。
- **全休**: 計上対象日数 × 1.0 を合計。
- 戻り値は decimal（`days_requested` の型に一致）。F1 によりカレンダーが所定休日の唯一の源。

### 2.2 `CompanyCalendarResolver#day_classifications`（小拡張）

既存 `day_types(from, to)`（Phase 1 が使用）は温存し、`counts_as_paid_leave` を surface する範囲一括メソッドを追加:

```ruby
# 1 クエリ。company_holiday 以外の counts_as_paid_leave は false 固定（calculator が無視）
def day_classifications(from, to)
  registered = with_tenant do
    CompanyCalendar.where(date: from..to).pluck(:date, :day_type, :counts_as_paid_leave)
  end.to_h { |date, dt, cpl| [date, { day_type: dt.to_sym, counts_as_paid_leave: cpl }] }
  (from..to).index_with do |d|
    registered[d] || { day_type: fallback(d), counts_as_paid_leave: false }
  end
end
```

fallback 由来日（未登録）は `day_type` が weekday/saturday/sunday、`counts_as_paid_leave: false`（company_holiday は登録必須ゆえ fallback には出ない）。

---

## 3. サービス — `app/services/`

### 3.1 `LeaveRequests::Estimate`（見積りの単一ソース・query service）

フォーム初期描画・preview エンドポイント・`Create` が共有する（F2）。

```ruby
# 入力: requester, leave_type, start_date, end_date, half_day_type
# 出力: 値オブジェクト（Data）
Estimate::Result = Data.define(
  :days_requested,      # LeaveDaysCalculator の結果
  :fiscal_year,         # Organization#fiscal_year_for(start_date)（§6.2 年度跨ぎ統一）
  :paid_leave,          # leave_type.paid_leave?（残高表示の有無）
  :confirmed_remaining, # 確定残高 = granted + carry_over - used_days（nil 残高は 0 扱い）
  :provisional_remaining, # 仮残高 = 確定 - Σ(applying days_requested 同一 user×type×fiscal_year)
  :remaining_after,     # 申請後残日数 = provisional_remaining - days_requested
  :status               # :positive / :zero / :negative（remaining_after の符号）
)
```

- **日数**: `CompanyCalendarResolver#day_classifications(start..end)` → `LeaveDaysCalculator.call`。
- **年度**: `requester.organization.fiscal_year_for(start_date)`。年度跨ぎ申請でも残高は start_date 年度に統一（§6.2）。
- **残高**（paid_leave 種別のみ算出。非 paid_leave は残高フィールド nil）:
  - 確定残高 = 当該 `LeaveBalance`（無ければ 0 付与扱い）の残日数。
  - 仮残高 = 確定 − Σ(同一 user×type×fiscal_year で `approval_status: applying` の `days_requested`)。新規申請レコードはまだ applying 集合に無く二重計上は起きない（2-2a に編集フローは無い）。
  - 申請後残日数 = 仮残高 − 今回 `days_requested`。符号で `status`。
- **テナント文脈**: requester の組織下で算出。残高クエリは acts_as_tenant スコープ + organization_id 明示。

### 3.2 `LeaveRequests::Create`（command・1 tx・承認エンジン起動）

```ruby
# def self.call(requester:, leave_type:, start_date:, end_date:, half_day_type:, reason:)
ActiveRecord::Base.transaction do
  est = Estimate.call(requester:, leave_type:, start_date:, end_date:, half_day_type:)
  record = LeaveRequest.create!(
    requester:, leave_type:, start_date:, end_date:, half_day_type:,
    reason:, days_requested: est.days_requested
  )
  Approvals::Start.call(record)   # ルート解決 + pending ApprovalAssignment 生成（§7.7・2-1）
  record
end
```

- `days_requested` は **Estimate で確定**（クライアントの hidden field を信用しない・サーバ権威）。
- **承認エンジンは 2-2a で起動**（決裁 UI のみ 2-2b）。`Approvals::Start` が `RouteError`（manager 未設定・§7.2）を上げると tx ロールバック →「申請不可・セットアップ要」を構造表現（host 未永続）。
- 残高不足でも申請は通す（§6.2・承認者が最終判断）。Create は残高チェックをしない。

### 3.3 `Approvals::Cancel`（2-1 後置の回収・command）

```ruby
# def self.call(approvable:, by:)  — by = 実行ユーザ（requester 本人想定）
approvable.with_lock do
  approvable.cancel!   # AASM applying→canceled（whiny_persistence で偽 success 化を防ぐ）
end
```

- **副作用なし**（status 遷移のみ）。`ApprovalAssignment` 行は履歴として残置（消さない）。
- 認可は `cancel?` Pundit（後段 §6）。本人 + applying のみ。`canceled` は terminal（§13.2）。
- 2-1 設計が「取消アクション/controller が現れる時に追加」と後置したものをここで回収。

---

## 4. 申請側 UI（employee-facing・非 Admin）

`LeaveRequestsController`（`index` / `new` / `create` / `preview` / `cancel`）。パス `/leave_requests`。`requester = current_user`。

### 4.1 申請フォーム

- フィールド: `leave_type`（active な種別）・`start_date` / `end_date`・`half_day_type`・`reason`。
- **理由テンプレートチップ**（§6.2）: `ReasonTemplate`（`applies_to: leave / both`・0b-5 既存）をチップ表示。Stimulus でチップ → textarea 追記。
- **manager 未設定バナー**: `Create` の `RouteError` を rescue し「申請不可・セットアップ要」を表示（§7.2）。

### 4.2 preview エンドポイント（D3 サーバ往復の着地点）

- `GET /leave_requests/preview` が `LeaveRequests::Estimate` を呼び **Turbo Frame** を返す（`days_requested` + 残高 2 段階 + 申請後残日数の状態）。
- Stimulus `leave_request_form_controller`: `leave_type` / `start_date` / `end_date` / `half_day_type` の変更を **debounce**（~300ms）して frame を再取得。`LeaveDaysCalculator` がサーバで唯一回るため提出時 `days_requested` と必ず一致。

### 4.3 残高 2 段階表示（§6.2・ViewComponent）

- **paid_leave 種別のみ**表示。確定残高（承認済）と仮残高（申請中含む）を並記。
- **申請後残日数の状態**（Estimate の `status` が決定・erb にロジックを散らさない）:
  - `正` → 通常表示
  - `0` → アンバー + ℹ️「今年度の有給を使い切ります」
  - `負` → 赤警告
- **不足でも申請は通す**（送信ボタンは活性のまま・承認者が最終判断）。

---

## 5. hr_admin 残高 CRUD

`LeaveBalance` を **社員詳細にネスト**（0b-4 `UserWorkPattern` と同型）。`Admin::Users::LeaveBalances`（`user × leave_type × fiscal_year` に `granted_days` / `carry_over_days` / `granted_on` を設定）。

- **hr_admin 専用**（Pundit・§6）。Admin 名前空間の明示 permit（0b-1 の方式）。
- 残高が常に「ある社員の」属性ゆえ独立トップ index でなくネストを採る（一覧性より文脈整合）。
- 複雑な 39 条自動付与・年度更新は §8.6 / Phase 4-4。本 CRUD は v1 の最小付与経路。

---

## 6. 認可（Pundit）

| Policy | 要点 |
|---|---|
| `LeaveRequestPolicy` | `Scope` = 自分の申請（`requester_id == user.id`）・`new?`/`create?`・`preview?`（自分の見積り）・`cancel?`（本人 + `applying?`） |
| `LeaveBalancePolicy` | `hr_admin?` 専用 CRUD・`Scope` も hr_admin 限定 |

- `cancel?` は **approvable（LeaveRequest）側**の認可（2-1 §5 の「具体 approvable の `cancel?` は 2-2 で追加」を回収）。controller は `authorize @leave_request, :cancel?` を通し `verify_authorized` を backstop に。
- 承認系（approve?/reject? の `ApprovalAssignmentPolicy`）は 2-1 で実装済。インボックス `Scope` は 2-2b。

---

## 7. 決算月ガード格上げ（D4・§4.15 / 社労士確認 #13）

`Organization` に検証を追加:

```ruby
validate :fiscal_year_end_month_locked_when_balances_exist

def fiscal_year_end_month_locked_when_balances_exist
  return unless fiscal_year_end_month_changed?
  return unless ActsAsTenant.without_tenant { LeaveBalance.where(organization_id: id).exists? }

  errors.add(:fiscal_year_end_month, "は休暇残高が存在するため変更できません")
end
```

- `without_tenant` idiom は `WorkPattern#deactivation_requires_no_current_or_future_assignments` と同型（mismatched with_tenant の fail-open を遮断）。`Organization` は acts_as_tenant 非対象ゆえ明示ラップ。
- 0b-5 設定画面からの `fiscal_year_end_month` 更新がこの検証で弾かれる。残高未生成の新規組織はセットアップで変更可（=0b-5 の自動再計算は残す）。

---

## 8. テスト戦略（テナント文脈下・`gen-spec` 準拠・負例重視）

| 種別 | ファイル | 主眼 |
|---|---|---|
| model | `spec/models/leave_request_spec.rb` | 半休排他（none 以外で start≠end 拒否）・end<start 拒否・**テナント越境 2 種 fail-closed（association + 整数 ID 直接代入・`attendance_history_spec` 写経）**・enum 毒入力 422（ArgumentError でない）・DB 最終防衛（save(validate:false)→ForeignKeyViolation）・`include Approvable` の初期 applying |
| model | `spec/models/leave_balance_spec.rb` | 一意（org,user,type,fiscal_year）・テナント越境 2 種・残日数メソッド（used_days 加算後も正）・default 0 |
| calculator | `spec/calculators/leave_days_calculator_spec.rb` | 全 day_type の除外/計上・half 0.5・**company_holiday paid=計上 / unpaid=除外**・fallback 土日除外・**除外日の半休 = 0**・複数日合計 |
| service | `spec/services/company_calendar_resolver_spec.rb`（追記） | `day_classifications` が counts_as_paid_leave を surface・fallback 日の flag=false |
| service | `spec/services/leave_requests/estimate_spec.rb` | 日数 + 確定/仮残高 + 正/0/負・**applying 集計のみ仮残高に効く**・年度跨ぎは start_date 年度キー・**paid_leave 限定（非 paid は残高 nil）**・残高未生成は 0 扱い |
| service | `spec/services/leave_requests/create_spec.rb` | days_requested をサーバ確定（client 値無視）・**`Approvals::Start` 連動（assignment 生成）**・**RouteError 時 host 未永続ロールバック（count 不変）**・残高不足でも作成成功 |
| service | `spec/services/approvals/cancel_spec.rb` | applying→canceled・terminal（再 cancel 不可）・assignment 行残置・副作用なし |
| policy | `spec/policies/leave_request_policy_spec.rb` | 本人 permit / 第三者 forbid・Scope = 自分のみ・cancel?（本人 applying のみ・terminal forbid） |
| policy | `spec/policies/leave_balance_policy_spec.rb` | hr_admin permit / 他ロール forbid |
| request/system | 申請フォーム・preview・残高 CRUD・取消 | preview debounce → 日数 + 残高状態・残高 CRUD（hr_admin）・取消ボタン |
| model | `spec/models/organization_spec.rb`（追記） | **残高ありで fiscal_year_end_month 変更拒否／残高なしで許可** |

### 完了条件（CLAUDE.md サブエージェント 3 か条）

- `bin/rails db:test:prepare` ／ `bundle exec rspec` 緑 ／ `bundle exec rubocop --force-exclusion <files>` ／ app/ 変更ゆえ `bin/brakeman --no-pager`
- PR 前に `/preflight`、**ROADMAP の 2-2 行を 2-2a/2-2b へ分解し 2-2a を更新（チェック + PR 番号）して PR に含める**

---

## 9. 新規ファイル一覧（manifest）

| ファイル | 役割 |
|---|---|
| `db/migrate/*_create_leave_requests.rb` | テーブル + 複合 FK + index |
| `db/migrate/*_create_leave_balances.rb` | テーブル + UNIQUE + 複合 FK |
| `db/migrate/*_add_unique_index_to_leave_types.rb`（要時） | `(organization_id, id)` unique（複合 FK 参照先・既存なら不要） |
| `app/models/leave_request.rb` | 申請モデル（Approvable・半休排他・テナント検証） |
| `app/models/leave_balance.rb` | 残高モデル（一意・残日数メソッド・テナント検証） |
| `app/calculators/leave_days_calculator.rb` | 取得日数の純計算（§5.5） |
| `app/services/company_calendar_resolver.rb`（追記） | `day_classifications` 追加 |
| `app/services/leave_requests/estimate.rb` | 見積りの単一ソース |
| `app/services/leave_requests/create.rb` | 申請作成（1 tx・Start 起動） |
| `app/services/approvals/cancel.rb` | 取消（applying→canceled・2-1 後置回収） |
| `app/controllers/leave_requests_controller.rb` | index/new/create/preview/cancel |
| `app/controllers/admin/users/leave_balances_controller.rb` | hr_admin 残高 CRUD（ネスト） |
| `app/policies/leave_request_policy.rb` | 本人 Scope・cancel? |
| `app/policies/leave_balance_policy.rb` | hr_admin 限定 |
| `app/models/organization.rb`（追記） | 決算月ガード格上げ |
| `app/components/**` | 残高 2 段階表示 ViewComponent・申請フォーム |
| `app/javascript/controllers/leave_request_form_controller.js` | debounce preview fetch・理由チップ |
| `spec/**/*_spec.rb` | §8 のカバレッジ |

**新規 gem は不要**（`aasm` は 2-1 導入済・Hotwire/ViewComponent は基盤既存）。

---

## 10. RAILS_GOTCHAS 留意（計画・レビューのプロンプトへ注入）

- **複合 FK idiom**: `db/migrate/*_create_user_work_patterns.rb` を参照実装に（`(organization_id, fk_id)` で越境を DB 層排除）。
- **acts_as_tenant の fail-closed 検証**: 越境ガードは **ID 基点**（`*_id.nil?` early return → association 比較）。`record.nil?` early return は acts_as_tenant の nil 解決で fail-open になる（`user.rb` / `attendance_history.rb` 同型）。
- **enum `validate: true`**: 毒入力は 422（ArgumentError でなく検証エラー）。
- **console / rake**: `ActsAsTenant.current_tenant = Organization.find_by!(subdomain: "...")` を先に（`NoTenantSet` 回避）。
- **rubocop**: ファイル明示渡し時 `--force-exclusion`（schema.rb 等の Exclude 無視回避）。
- **fiscal guard の `without_tenant`**: `WorkPattern#deactivation_*` 同型（mismatched with_tenant の fail-open 遮断）。
- **schema 手編集禁止**: migration 経由（`block-schema-edit` フック）。
- **2-2b への seam（前置）**: `Approvals::Cancel` は `with_lock` を使うが副作用ゼロ。2-2b で `approve` に残高加算等を足す際、**with_lock 内 tx で SQL 例外を rescue すると偽 success + 更新消失**（1-2 で仕留めた罠）。失敗し得る後続副作用は savepoint 隔離 or commit 後（ClockOut→Recalculate 構造）に置く設計を 2-2b へ申し送り。
