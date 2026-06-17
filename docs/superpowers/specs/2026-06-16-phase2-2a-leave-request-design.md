# Phase 2-2a 休暇申請 + 残高（申請側）— 設計

- 日付: 2026-06-16
- スライス: ROADMAP Phase 2-2 を **2-2a（申請側）/ 2-2b（承認+副作用）** に分割した前半
- 1 スライス = 1 ブランチ = 1 PR（`feat/phase2-2a-leave-request`）
- 典拠: SPEC §4.9–4.10（LeaveRequest / LeaveBalance）・§5.5（LeaveDaysCalculator）・§6.2（休暇申請）・§7.1/§7.7（承認エンジン起動）・§13.2（AASM）・§3.4–3.6（認可・テナント分離）・§2.2（アーキ原則）
- 前提エンジン: Phase 2-1（`ApprovalAssignment` / `Approvable` concern / `Approvals::Start/Approve/Reject` / `RouteResolver` / `SelfApproval`）は据付済み
- **多視点レビュー反映済（2026-06-16・`/multi-perspective-review`）**: 原則整合 / 実用主義 / YAGNI / セキュリティ / テスト網羅 / 労務法令の 6 視点を独立並列で実施。収束した重大指摘 C1（仮残高クエリ確定）・C3（Estimate の残高漏洩固定）・C4（admin 名前空間フラット化）・C5（不要 migration 削除）と中位修正を本版で反映。判断ログ D5（granted_on=B2）追加

## 0. スコープと前提

ROADMAP の Phase 2-2（`LeaveRequest + LeaveBalance`）は実質「①データ+純計算 / ②申請側 UI / ③承認側+副作用」の三塊を抱える。③にドメイン risk（テナント分離・残高並行制御・締め判定）が集中するため、**2-2a（申請側）/ 2-2b（承認+副作用）へ分割**し、各サブスライスを独自の spec→plan→PR サイクルで進める（本書は 2-2a）。

2-2a は「**社員が休暇を申請・取消でき、hr_admin が残高を付与できる**」までを縦に通す。承認決裁は 2-2a 時点では未接続（`approval_status` は `applying` のまま積まれる）が、**承認エンジンの起動（ルート解決 + `ApprovalAssignment` 生成）は 2-2a で行う**（§7.7・後段 §3.2）。

### 設計判断ログ

| # | 論点 | 決定 |
|---|------|------|
| D1 | 2-2 のスコープ | **分割**（2-2a 申請側 / 2-2b 承認+副作用）。③のドメイン risk を独立 PR に隔離 |
| D2 | `LeaveBalance` の残高付与経路（39 条自動付与は Phase 4 固定） | **hr_admin 残高 CRUD を 2-2a に同梱**。複雑な 39 条自動付与・年度更新は §8.6 / Phase 4-4 |
| D3 | 申請フォームのリアルタイム日数表示 | **A: サーバ往復（debounce fetch）**。`LeaveDaysCalculator` を唯一の真実源に保つ |
| D4 | `fiscal_year_end_month` 変更禁止の格上げ（ROADMAP が 2-2 着手時の再判断と明記・社労士確認 #13） | **格上げ：残高が存在したら変更禁止** |
| D5（MPR） | `granted_on`（有給付与日・5 日義務起点）の 2-2a 扱い | **B2: CRUD で取得 + 必須検証同梱**。capture-at-source で Phase 4 backfill を回避。`paid_leave かつ annual` の残高は `granted_on` 必須を 2-2a で検証（§8.6 を最小前倒し）。「列は置くが検証なし」の中途半端を排す（YAGNI 視点） |
| F1（強制） | `LeaveDaysCalculator` の所定労働日の源 | **カレンダー駆動で確定**。`WorkPattern` は曜日別稼働日カラムを持たず、源は `CompanyCalendar` 一択。土曜（・祝日）稼働組織は当該日を `weekday` 登録して §5.5 但し書きを満たす |
| F2 | 見積りの単一ソース | **`LeaveRequests::Estimate`** に「日数 + 確定/仮残高 + 申請後残日数」を集約。フォーム初期描画・preview・`Create` が共有 |

### 本スライスに含めない（2-2b へ明示的後置）

- **`approve` 副作用一式**（§6.2・§13.6）: 対象日 `AttendanceRecord` 作成/更新（on_leave / morning_half / afternoon_half）・`LateEarly` 再計算・`LeaveBalance.used_days` の `lock!` 加算・`AttendanceHistory(leave_approved)` 記録 → **2-2b**
- 承認インボックス UI・`ApprovalAssignmentPolicy::Scope`・導出ヘルパ `single_stage?` / `pending_approver`・却下 UI → **2-2b**
- **`AttendanceRecord.status` enum 拡張**（morning_half:2 / afternoon_half:3 / on_leave:4）→ **2-2b**（書き込み主体＝副作用と同居）
- **月跨ぎ/年度跨ぎ**（§6.2）: 年度跨ぎ加算統一は `used_days` writer と同じ **2-2b**。月跨ぎの「締め済み月のみブロック」は **Phase 3（`MonthlyAttendanceSummary`）依存**ゆえ、2-2b でも per-day 月分割計上の構造までで締めチェックは Phase 3 接続
- **事後有給**（absent→on_leave・§6.2）: `absent` status が **4-2** まで存在しないため、さらに後置
- 撤回フロー（withdrawal_requested / withdrawn）→ **2-5**。`withdrawal_reason` / `last_stale_notified_on` 列も消費スライスで追加

---

## 1. モデル / スキーマ

### 1.1 `LeaveRequest`（§4.9・`include Approvable`）

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

#### インデックス & 参照整合（§3.6 二層防御）

- **複合 FK** `(organization_id, requester_id) → users(organization_id, id)`（`user_work_patterns` migration を参照実装に）
- **複合 FK** `(organization_id, leave_type_id) → leave_types(organization_id, id)`（**leave_types の `[organization_id, id]` unique index は既存**——MPR C5 で実機確認・追加 migration 不要）
- **INDEX** `[organization_id, requester_id, approval_status]` — 自分の申請一覧
- **INDEX** `[organization_id, requester_id, leave_type_id, start_date]` — 仮残高の年度別 applying 集計（§3.1 の確定クエリに整合。低ボリュームゆえ approval_status は WHERE 絞り）

#### モデル

```ruby
class LeaveRequest < ApplicationRecord
  acts_as_tenant(:organization)
  belongs_to :requester, class_name: "User"
  belongs_to :leave_type
  include Approvable   # approval_status の AASM + has_many :approval_assignments

  MAX_SPAN_DAYS = 366  # 1 年度相当の上限（不定・DoS 抑止。業務上 1 年超の連続休暇は非現実的）

  enum :half_day_type, { none: 0, morning: 1, afternoon: 2 }, validate: true

  validates :start_date, :end_date, :days_requested, presence: true
  validates :days_requested, numericality: { greater_than: 0 }   # ★0 日申請拒否（MPR）
  validate :end_date_not_before_start_date
  validate :span_within_limit                          # ★end-start <= MAX_SPAN_DAYS（MPR）
  validate :half_day_requires_single_day               # §4.9 半休排他
  validate :half_day_requires_half_day_enabled_type    # ★§6.2 半休可能種別のみ（MPR）
  validate :requester_must_belong_to_same_organization # ID 基点 fail-closed（user.rb 同型）
  validate :leave_type_must_belong_to_same_organization
end
```

- **0 日申請拒否**（MPR・テスト網羅）: `days_requested > 0`。全除外範囲（全日が休日）は取得日数 0 ゆえ `Create` がこの検証で「申請対象日がありません」を返す（空申請を通さない）。
- **半休排他**（§4.9）: `half_day_type != none` のとき `start_date == end_date` 必須。
- **半休可能種別**（MPR・§6.2）: `half_day_type != none` のとき `leave_type.allow_half_day?` 必須。
- **テナント越境ガードは ID 基点で fail-closed**（`attendance_history.rb` / `user.rb` 同型）。`requester` / `leave_type` 両方。
- `days_requested`・`approval_status` は **strong params に恒久ブロック**（writer は `LeaveRequests::Create` のみ＝サーバ権威。AASM 迂回防止・2-1 §2 #5）。

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
| `granted_on` | date | NULL | 有給付与日（5 日義務起点・§8.6）。**D5: paid_leave×annual は必須検証** |

- **UNIQUE** `[organization_id, user_id, leave_type_id, fiscal_year]`
- **複合 FK** `(organization_id, user_id) → users` / `(organization_id, leave_type_id) → leave_types`
- **残日数 = `granted_days + carry_over_days - used_days`**（メソッド採用。§4.10 が許す STORED 生成列は v1 見送り）。
- **`granted_on` 必須検証（D5・§8.6 最小前倒し）**:
  ```ruby
  validates :granted_on, presence: true, if: :paid_annual?
  def paid_annual? = leave_type&.paid_leave? && leave_type&.annual?
  ```
  これにより NULL `granted_on` の有給 annual 残高を作れず、Phase 4 の 5 日義務時計が起動可能な状態で残高が生まれる。
- テナント越境ガードは LeaveRequest と同型（ID 基点 fail-closed・`user` / `leave_type` 両方）。
- `used_days` は 2-2a では常に default 0（加算経路が無い）。残日数表示は 0 前提でも正しく動く。

---

## 2. 純計算 — `LeaveDaysCalculator` + Resolver 拡張

### 2.1 `LeaveDaysCalculator`（§5.5・`app/calculators/`・純関数）

```ruby
LeaveDaysCalculator.call(classifications:, half_day_type:) → BigDecimal
```

- 入力 `classifications` = `{ Date => { day_type: Symbol, counts_as_paid_leave: Boolean } }`（**値**として渡す・§2.2-1 境界）。AR 依存の合成は service 層。
- **除外**: `saturday` / `sunday`（所定休日曜日）/ `holiday` / `legal_holiday` / `company_holiday` かつ `counts_as_paid_leave == false`。**計上**: `weekday`、および `company_holiday` かつ `counts_as_paid_leave == true`。
- **半休**（`half_day_type != none`）: 単日に 0.5 係数。当該日が計上対象なら 0.5、除外日なら 0。
- **全休**: 計上対象日数 × 1.0 を合計。**全除外範囲は `BigDecimal("0")`** を返す（型を保つ・空 `sum` の Integer 化を避ける）。
- **防御 assert（MPR・原則整合）**: `half_day_type != none` かつ `classifications.size > 1` は `ArgumentError`（純関数の入力契約。上流の `start==end` 検証バイパス時に不定値を返さない fail-closed）。
- F1: カレンダーが所定休日の唯一の源。**祝日稼働組織も当該祝日を `weekday` 登録要**（SPEC §5.5 但し書きは土曜のみ明示だが同型対応・運用 note）。

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

> 実装注（MPR 実用主義・任意）: `day_types` の fallback/range ロジックと重複する。可能なら `day_types` を `day_classifications(...).transform_values { it[:day_type] }` 由来に薄く寄せ二重持ちを消す（Phase 1 ホットパスへの blast-radius を計測で確認できる範囲で・必須ではない）。

---

## 3. サービス — `app/services/`

### 3.1 `LeaveRequests::Estimate`（見積りの単一ソース・query service）

フォーム初期描画・preview・`Create` が共有する（F2）。

```ruby
# 入力: requester, leave_type, start_date, end_date, half_day_type
# requester は呼び出し側で current_user に固定（§3.2・MPR C3）。引数で他者を渡さない契約
Estimate::Result = Data.define(
  :days_requested,        # LeaveDaysCalculator の結果
  :fiscal_year,           # Organization#fiscal_year_for(start_date)（§6.2 年度跨ぎ統一）
  :paid_leave,            # leave_type.paid_leave?（残高表示の有無）
  :confirmed_remaining,   # 確定残高 = granted + carry_over - used_days（nil 残高は 0 扱い・非 paid は nil）
  :provisional_remaining, # 仮残高（下式・非 paid は nil）
  :remaining_after        # 申請後残日数 = provisional_remaining - days_requested（非 paid は nil）
) do
  # ★status は格納でなく派生メソッド（MPR 実用主義）
  def status
    return nil if remaining_after.nil?
    remaining_after.positive? ? :positive : (remaining_after.zero? ? :zero : :negative)
  end
end
```

**算出手順:**

1. **半休 fail-closed（MPR C/原則整合）**: `half_day_type != none` のとき `start_date == end_date` でなければ見積りエラー（calculator 呼出前。preview もここを通る）。`end - start <= MAX_SPAN_DAYS` も検証。
2. **日数**: `CompanyCalendarResolver#day_classifications(start..end)` → `LeaveDaysCalculator.call`。
3. **年度**: `requester.organization.fiscal_year_for(start_date)`（§6.2 年度跨ぎ統一）。
4. **残高**（paid_leave 種別のみ。非 paid は残高 3 フィールド nil）:
   - 確定残高 = 当該 `LeaveBalance`（無ければ 0 付与扱い）の残日数。
   - **仮残高 = 確定 − Σ(applying な同一申請者・同一種別で start_date が当該年度に属する `days_requested`)**。
   - 申請後残日数 = 仮残高 − 今回 `days_requested`。

**★C1: 仮残高クエリの確定形（年度→日付範囲の逆写像）**

`leave_requests` に `fiscal_year` 列は無く、`fiscal_year_for` は date→year の片方向のみ。年度別 applying を絞るため **`Organization#fiscal_year_range(year)` を新設**（`fiscal_year_for` の逆・fiscal 単一ソースを `Organization` に集約）:

```ruby
# Organization（fiscal_year_for と対で spec する）
def fiscal_year_range(fiscal_year)
  start_month = fiscal_year_end_month % 12 + 1
  start = Date.new(fiscal_year.to_i, start_month, 1)
  start..start.next_year.prev_day            # 例: end_month=3, "2026" → 2026-04-01..2027-03-31
end
```

```ruby
# Estimate 内（acts_as_tenant スコープ下・自社のみ）
provisional_used =
  LeaveRequest.where(requester: requester, leave_type: leave_type, approval_status: :applying)
              .where(start_date: requester.organization.fiscal_year_range(fiscal_year))
              .sum(:days_requested)
```

- **スコープ隔離が要**（MPR テスト網羅・高）: where は `requester` / `leave_type` / **当該年度 start_date** で必ず絞り、他 user・他種別・他年度・他テナント（acts_as_tenant）の applying を**巻き込まない**（過小残高バグ防止）。負例テスト必須（§8）。

### 3.2 `LeaveRequests::Create`（command・1 tx・承認エンジン起動）

```ruby
# def self.call(requester:, leave_type:, start_date:, end_date:, half_day_type:, reason:)
# ★requester は controller が current_user を渡す。params 由来の requester_id/user_id は受けない（MPR C3）
ActiveRecord::Base.transaction do
  est = Estimate.call(requester:, leave_type:, start_date:, end_date:, half_day_type:)
  record = LeaveRequest.create!(
    requester:, leave_type:, start_date:, end_date:, half_day_type:,
    reason:, days_requested: est.days_requested      # サーバ確定（client の hidden field 不使用）
  )
  Approvals::Start.call(record)   # ルート解決 + pending ApprovalAssignment 生成（§7.7・2-1）
  record
end
```

- `days_requested` は **Estimate で確定**（サーバ権威）。0 日は §1.1 の `> 0` 検証で `RecordInvalid`。
- **承認エンジンは 2-2a で起動**（決裁 UI のみ 2-2b）。`Approvals::Start` が `RouteError`（manager 未設定・§7.2）→ tx ロールバック →「申請不可・セットアップ要」を構造表現（host・assignment ともに**未永続**）。
- 残高不足でも申請は通す（§6.2・承認者が最終判断）。Create は残高チェックをしない。
- 実装注（MPR YAGNI・任意）: Create が消費するのは `est.days_requested` のみ（残高 3 値は捨てる）。微最適化が要れば days-only 経路を切れるが、F2 の単一ソース優先で Estimate 共有を既定とする。

### 3.3 `Approvals::Cancel`（2-1 後置の回収・command）

```ruby
# def self.call(approvable:, by:)
approvable.with_lock do
  raise SelfApprovalError unless by.id == approvable.requester_id  # ★防御 in depth（MPR）
  approvable.cancel!   # AASM applying→canceled（whiny_persistence で偽 success 化を防ぐ）
end
```

- **副作用なし**（status 遷移のみ）。`ApprovalAssignment` 行は履歴として残置。
- 認可は `cancel?` Pundit（§6・本人 + applying のみ）と service 内 `by == requester` の**二層**（§7.3 と同思想）。
- **`with_lock` は前置**（MPR・任意残置）: 2-2a 単体では副作用ゼロゆえ素の `cancel!` でも安全だが、(a) 二重クリック耐性、(b) 2-2b の `approve`（`with_lock` + 残高加算）と形を揃える seam として残す。
- `canceled` は terminal（§13.2）。terminal 再 cancel は `AASM::InvalidTransition`。

---

## 4. 申請側 UI（employee-facing・非 Admin）

`LeaveRequestsController`（`index` / `new` / `create` / `preview` / `cancel`）。パス `/leave_requests`。**`requester = current_user` を構造固定**し、`requester_id` / `user_id` を params から一切受けない（MPR C3・`ClockingsController` §3.5 同型）。

### 4.1 申請フォーム

- フィールド: `leave_type`（active な種別・acts_as_tenant スコープの `find`）・`start_date` / `end_date`・`half_day_type`・`reason`。
- **理由テンプレートチップ**（§6.2）: `ReasonTemplate`（`applies_to: leave / both`・0b-5 既存）をチップ表示。Stimulus でチップ → textarea 追記。
- **manager 未設定バナー**: `Create` の `RouteError` を rescue し「申請不可・セットアップ要」を表示（§7.2）。

### 4.2 preview エンドポイント（D3 サーバ往復の着地点）

- `GET /leave_requests/preview` が `LeaveRequests::Estimate`（requester=current_user 固定）を呼び **Turbo Frame** を返す。
- **Turbo Frame の `src` 書き換え方式**（MPR 実用主義）: フォームに `turbo_frame_tag "leave_estimate", src: ...` を置き、Stimulus `leave_request_form_controller` は type/date/half の変更で **frame の `src` 属性を debounce（~300ms）更新するだけ**（Turbo が自動取得・差し替え。生 `fetch`+innerHTML 操作はしない＝再発明回避）。
- **認可**: persisted record が無いため **class-level `authorize LeaveRequest, :preview?`**（`preview?` = 本人見積りゆえ `user.present?`）。`requester` 固定で他者見積りは構造的に不可。

### 4.3 残高 2 段階表示（§6.2・ViewComponent）

- **paid_leave 種別のみ**表示。確定残高（承認済）と仮残高（申請中含む）を並記。
- **申請後残日数の状態**（`Estimate::Result#status` が決定・erb にロジックを散らさない）:
  - `:positive` → 通常表示
  - `:zero` → アンバー + ℹ️「今年度の有給を使い切ります」
  - `:negative` → 赤警告
- **不足でも申請は通す**（送信ボタンは活性のまま・承認者が最終判断）。

---

## 5. hr_admin 残高 CRUD（MPR C4: フラット既存規約に整合）

**0b-4 `Admin::UserWorkPatternsController` と同じフラット構成**（深いモジュールネストにしない）:

- コントローラ `Admin::LeaveBalancesController`（route は `resources :users do resources :leave_balances end` で user ネスト URL・コントローラはフラット）。
- 認可は **`authorize [:admin, record]`** 経由 → **`Admin::LeaveBalancePolicy`**（`hr_admin?` 専用）。
- 親 user は **`policy_scope([:admin, User]).find(params[:user_id])`** で解決（scope 外 → 404・IDOR/越境防止・MPR セキュリティ）。
- strong params は **`granted_days` / `carry_over_days` / `granted_on` のみ**。`used_days`（2-2b approve の専有 writer）と `user_id`（ネスト URL 由来）は**恒久ブロック**（MPR セキュリティ・負例テストで固定）。
- 残高は `user × leave_type × fiscal_year` 単位。複雑な 39 条自動付与・年度更新は §8.6 / Phase 4-4。

---

## 6. 認可（Pundit）

| Policy | 要点 |
|---|---|
| `LeaveRequestPolicy` | `Scope` = 自分の申請（`requester_id == user.id`）・**`index?`（`user.present?`・本アプリは index でも `verify_authorized` 発火）**・`new?`/`create?`・`preview?`（本人見積り）・`cancel?`（本人 + `applying?`） |
| `Admin::LeaveBalancePolicy` | `hr_admin?` 専用 CRUD・`Scope` も hr_admin 限定 |

- controller index は **`policy_scope` + `authorize`（class）の両方**を呼ぶ（既存 leave_types/users index 同型）。
- `cancel?` は approvable（LeaveRequest）側の認可（2-1 §5 後置の回収）。controller は `authorize @leave_request, :cancel?` を通し `verify_authorized` を backstop に。
- **member 取得は `policy_scope(LeaveRequest).find(params[:id])`**（他人の申請を 403 まで持ち込まず 404・scope + policy の二層・MPR セキュリティ）。
- 承認系（`ApprovalAssignmentPolicy#approve?/reject?`）は 2-1 実装済。インボックス `Scope` は 2-2b。

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

- `without_tenant` idiom は `WorkPattern#deactivation_requires_no_current_or_future_assignments` 同型（mismatched with_tenant の fail-open を遮断）。`Organization` は acts_as_tenant 非対象ゆえ明示ラップ。
- 0b-5 設定画面からの更新がこの検証で弾かれる。残高未生成の新規組織はセットアップで変更可。
- **0b-5 の更新経路が `save`/`update`（バリデーション発火）であることを確認**（`update_column`/`update_all` ならガード素通り・MPR セキュリティ）。

---

## 8. テスト戦略（テナント文脈下・`gen-spec` 準拠・**MPR で負例を全面補強**）

| 種別 | ファイル | 主眼（★は MPR 追加の負例・敵対ケース） |
|---|---|---|
| model | `spec/models/leave_request_spec.rb` | 半休排他（none 以外で start≠end 拒否 + **★valid 側: 半休×単日 / none×複数日が通る**）・end<start 拒否・**★span 上限超 422**・**★0 日（`days_requested=0`）拒否**・**★half×allow_half_day=false の種別拒否**・テナント越境（**★requester / leave_type の参照 2 本 × association + 整数 ID 直接代入の 2 機構**・`attendance_history_spec` 写経）・enum 毒入力 422・DB FK 最終防衛 |
| model | `spec/models/leave_balance_spec.rb` | 一意（org,user,type,fiscal_year）・**★鏡像（別テナントで同一キー valid）**・**★`save!(validate:false)`→`RecordNotUnique` / 複合 FK `ForeignKeyViolation`**・テナント越境（user / leave_type 各 2 機構）・残日数メソッド・**★`granted_on` 必須（paid×annual）/ 非該当種別は不要** |
| calculator | `spec/calculators/leave_days_calculator_spec.rb` | 全 day_type の除外/計上・**★全除外範囲 = `BigDecimal("0")`（型まで）**・半休計上 = `0.5`・除外日の半休 = 0・company_holiday paid=計上/unpaid=除外・fallback 土日・複数日合計（型）・**★防御 assert（half×複数日 → ArgumentError）** |
| service | `spec/services/company_calendar_resolver_spec.rb`（追記） | `day_classifications` が counts_as_paid_leave を surface・fallback 日 flag=false |
| service | `spec/services/leave_requests/estimate_spec.rb` | 日数 + 確定/仮残高 + status(正/0/負)・**★仮残高スコープ隔離（他 user / 他 leave_type / 他テナントの applying を巻き込まない）**・**★非 applying 個別（approved / rejected / canceled が各々効かない）**・**★他年度 applying が当年度仮残高を変えない**・**★合成ケース（granted/carry/used/applying 全非ゼロで confirmed≠provisional）**・paid_leave 限定（非 paid は残高 nil）・残高未生成 = 0 扱い |
| service | `spec/services/leave_requests/create_spec.rb` | days_requested をサーバ確定・`Approvals::Start` 連動（assignment 生成）・**★RouteError 時 `LeaveRequest.count` と `ApprovalAssignment.count` 双方不変**・残高不足でも作成成功・0 日 → `RecordInvalid` |
| service | `spec/services/approvals/cancel_spec.rb` | applying→canceled・terminal 再 cancel→`InvalidTransition`・assignment 行残置・副作用なし・**★`by≠requester`→`SelfApprovalError`（service 層）**・**★with_lock race（`clock_out_spec` の receive(:with_lock) パターン流用・ロック内 reload で非 applying なら whiny で大声失敗）** |
| policy | `spec/policies/leave_request_policy_spec.rb` | 本人 permit / 第三者・他テナント forbid・Scope = 自分のみ・**★index? / preview?（他者見積り forbid）**・cancel?（本人 applying のみ・terminal forbid） |
| policy | `spec/policies/admin/leave_balance_policy_spec.rb` | hr_admin permit / 他ロール forbid |
| component | `spec/components/.../leave_balance_*_spec.rb` | **★status 駆動の 3 表示（positive→通常 / zero→アンバー+「今年度の有給を使い切ります」/ negative→赤）の描画テキスト・クラス**・送信ボタン活性 |
| request | 申請フォーム・preview・残高 CRUD・取消 | preview（frame src 更新 → 日数 + 残高状態）・**★mass-assignment（`days_requested`/`approval_status` を POST しても永続値はサーバ Estimate・status=applying）**・**★preview に `requester_id` を渡しても自分の見積りのみ / 他テナント leave_type は 404**・**★index が他テナント・他者を漏らさない**・残高 CRUD（hr_admin permit / 非 hr_admin 403・**★`used_days` 改竄無視**・**★org A の hr_admin が org B の user_id にネスト経由で付与不可**）・取消ボタン |
| model | `spec/models/organization_spec.rb`（追記） | **★残高ありで fiscal_year_end_month 変更拒否 / 残高なしで許可 / 別 current_tenant 文脈でも拒否（without_tenant pin）/ 他 org 残高は当 org をロックしない / 他属性変更は残高ありでも通る（過剰ブロック回避）**・`fiscal_year_range` が `fiscal_year_for` の逆（往復一致） |

### 完了条件（CLAUDE.md サブエージェント 3 か条）

- `bin/rails db:test:prepare` ／ `bundle exec rspec` 緑 ／ `bundle exec rubocop --force-exclusion <files>` ／ app/ 変更ゆえ `bin/brakeman --no-pager`
- PR 前に `/preflight`、**ROADMAP の 2-2 行を 2-2a/2-2b へ分解し 2-2a を更新（チェック + PR 番号）して PR に含める**

---

## 9. 新規ファイル一覧（manifest）

| ファイル | 役割 |
|---|---|
| `db/migrate/*_create_leave_requests.rb` | テーブル + 複合 FK + index（leave_types unique index は既存ゆえ追加 migration 無し） |
| `db/migrate/*_create_leave_balances.rb` | テーブル + UNIQUE + 複合 FK |
| `app/models/leave_request.rb` | 申請モデル（Approvable・半休排他/可能種別・span・0 日拒否・テナント検証） |
| `app/models/leave_balance.rb` | 残高モデル（一意・残日数メソッド・granted_on 必須・テナント検証） |
| `app/models/organization.rb`（追記） | `fiscal_year_range`（C1）・決算月ガード格上げ（D4） |
| `app/calculators/leave_days_calculator.rb` | 取得日数の純計算（§5.5・防御 assert） |
| `app/services/company_calendar_resolver.rb`（追記） | `day_classifications` 追加 |
| `app/services/leave_requests/estimate.rb` | 見積りの単一ソース（仮残高確定クエリ） |
| `app/services/leave_requests/create.rb` | 申請作成（1 tx・Start 起動） |
| `app/services/approvals/cancel.rb` | 取消（applying→canceled・by 検証・2-1 後置回収） |
| `app/controllers/leave_requests_controller.rb` | index/new/create/preview/cancel（requester 固定） |
| `app/controllers/admin/leave_balances_controller.rb` | hr_admin 残高 CRUD（フラット・user ネスト URL） |
| `app/policies/leave_request_policy.rb` | 本人 Scope・index?/preview?/cancel? |
| `app/policies/admin/leave_balance_policy.rb` | hr_admin 限定 |
| `app/components/**` | 残高 2 段階表示 ViewComponent・申請フォーム |
| `app/javascript/controllers/leave_request_form_controller.js` | frame src の debounce 更新・理由チップ |
| `spec/**/*_spec.rb` | §8 のカバレッジ |

**新規 gem は不要**（`aasm` は 2-1 導入済・Hotwire/ViewComponent は基盤既存）。

---

## 10. RAILS_GOTCHAS 留意（計画・レビューのプロンプトへ注入）

- **複合 FK idiom**: `db/migrate/*_create_user_work_patterns.rb` を参照実装に。
- **acts_as_tenant の fail-closed 検証**: 越境ガードは **ID 基点**（`*_id.nil?` early return → association 比較）。`record.nil?` early return は fail-open（`user.rb` / `attendance_history.rb` 同型）。
- **Pundit 非経由の残高リーダー**（MPR C3）: `Estimate` は `LeaveBalancePolicy` を通らない。**requester=current_user の構造固定**（params 不受理）が崩れた瞬間クロスユーザー残高漏洩——controller で固定し負例テストで pin。
- **enum `validate: true`**: 毒入力は 422（ArgumentError でなく検証エラー）。
- **console / rake**: `ActsAsTenant.current_tenant = Organization.find_by!(subdomain: "...")` を先に（`NoTenantSet` 回避）。
- **rubocop**: ファイル明示渡し時 `--force-exclusion`。
- **fiscal guard の `without_tenant`**: `WorkPattern#deactivation_*` 同型。0b-5 の更新が `save`/`update` 発火であること要確認。
- **schema 手編集禁止**: migration 経由（`block-schema-edit` フック）。
- **2-2b への seam（前置）**: `Approvals::Cancel` の `with_lock` は副作用ゼロだが、2-2b で `approve` に残高加算等を足す際、**with_lock 内 tx で SQL 例外を rescue すると偽 success + 更新消失**（1-2 で仕留めた罠）。失敗し得る後続副作用は savepoint 隔離 or commit 後（ClockOut→Recalculate 構造）に置く設計を 2-2b へ申し送り。

---

## 11. 後続フェーズ・社労士への申し送り（MPR 労務法令視点・2-2a スコープ外）

労務法令レビューで**法令の明確な誤りは検出されず**（39 条原典と §5.5/§4.10 が一致：legal_holiday 除外・半休 0.5・5 日義務起点が正）。以下は Phase 4 / NOTES への申し送り:

1. **年度帰属は会計年度でなく個人基準日アンカー**（労基法 39 条 1〜2 項は雇入れ日 + 6 ヶ月基準）。`fiscal_year` は管理バケツに留め、**繰越・失効（Phase 4-4）は `granted_on` / 2 年時効基準で動かす**ことを年度更新ジョブで明示（NOTES #13 紐付け）。決算月ガード（§7）自体はデータ整合性として保守的で問題なし。
2. **`carry_over_limit` の 2 年時効下限**（労基法 115 条・NOTES #13(b)）: Phase 4-4 のカラム追加 PR で「`carry_over_limit ≥ 2 年時効相当」検証を同梱。2-2a は `carry_over_days` writer 無し（default 0）ゆえ実害なし。
3. **`granted_days` 手入力の 39 条最低付与ガードレール**: v1 は hr_admin 任意入力（D2・自動付与は Phase 4）。CRUD 画面に「39 条最低付与の自動検証は Phase 4」の注記・参考表示を検討。
4. **NOTES #10 追記（計画的付与）**: `company_holiday × counts_as_paid_leave=true` の計上は、(a) 労使協定の存在、(b) 39 条 6 項「5 日を超える部分に限る」制約をシステムは検証しない（運用担保）。`docs/LABOR_LAW_REVIEW_NOTES.md` #10 に追記し、`counts_as_paid_leave=true` 運用時の社労士確認を明文化。実装 PR で NOTES を更新する。
5. **祝日稼働組織の `weekday` 登録**（§2.1）: SPEC §5.5 但し書きは土曜のみ明示だが、祝日稼働組織も当該祝日を `weekday` 登録する同型対応が要る（運用 note・法令誤りではない）。
