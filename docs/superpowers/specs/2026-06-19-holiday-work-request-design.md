# Phase 2-4 HolidayWorkRequest（休日出勤申請）— 設計

- 日付: 2026-06-19
- スライス: ROADMAP Phase 2-4（1 スライス = 1 ブランチ = 1 PR・`feat/phase2-4-holiday-work-request`）
- 典拠: SPEC §4.12（HolidayWorkRequest）・§6.11（休日出勤フロー）・§13.3（approval_status AASM）・§13.5（連携俯瞰）・§4.03（is_holiday_work）・§4.10（LeaveBalance）・§4.7（法定休日特定）・§3.4–3.6（認可・テナント分離）
- 前提エンジン: Phase 2-1（承認エンジン）+ 2-2a/2-2b（`Approvable` hook・`Approvals::Approve/Reject/Start/Cancel`・`ApplyApproval` パターン・承認インボックス・`LeaveBalance`）+ 2-3（CCR・型別インボックス行・`ConflictError`）はすべて据付・merge 済（main = 2-3 完了）
- **本設計のブレスト確定事項（2026-06-19・`superpowers:brainstorming`）**: 下記 D1–D7 をユーザー承認済み

## 0. スコープと前提

2-2b で承認の副作用パターン（汎用エンジン hook → host 別 `ApplyApproval` service・同一 tx・atomic rollback）、2-3 で型別インボックス行 Component と承認時の前提再検証（§7.4 競合チェック）が確立した。2-4 は **三つ目の承認対象 `HolidayWorkRequest`（HWR）** を投入し、「社員が休日出勤を申請 → 2 段承認 → 代休残高 +1 ＋ is_holiday_work 連動まで一周」させる。

HWR は 2-3 CCR の骨格（model + `Approvable` hook + Create + ApplyApproval + Controller + Policy + 申請 UI + 型別インボックス行）をほぼそのまま流用する。**固有の新ロジックは三点に局所化**される: ① `is_holiday_work` の双方向連動（承認＝予約／打刻＝付与）② 代休残高 +1 と消費側の対称化 ③ 代休限定（振替は後置）。

完了条件: 休日出勤が **申請 → 2 段承認 → 承認時の平日性再検証 → 代休残高 +1 ＋（既存 AR があれば）is_holiday_work 付与まで一周**し、ClockIn/ProxyClockIn が承認済 HWR のある日の打刻で is_holiday_work を立てる。撤回は持たない（4 値・§13.3）。

### 設計判断ログ

| # | 論点 | 決定 | 根拠 |
|---|------|------|------|
| D1 | `is_holiday_work` をいつ立てるか | **双方向連動**。承認＝予約（既存 AR があれば付与）／ClockIn・ProxyClockIn＝作成時付与 | §6.11 step2「承認後、当日打刻で is_holiday_work=true 自動セット」＋§13.3「is_holiday_work 予約」。事前申請（未打刻→後で打刻）と事後申請（打刻済→後で承認）の両ケースをカバー。is_holiday_work カラムは schema 未存在（§4.03 概念列・Phase 1 後送り）ゆえ本スライスで追加 |
| D2 | 代休残高の付与・消費の対称性 | **`LeaveType#balance_tracked?`（= paid_leave? \|\| substitute_holiday? \|\| compensatory_leave?）述語を導入**し、HWR 承認の付与（+1）と LeaveRequest の消費（減算・over-balance）を同一述語で駆動。2-2b `LeaveRequests::ApplyApproval#add_to_balance` の `paid_leave?` を `balance_tracked?` に一般化 | HWR 承認で代休残高 +1 しても消費側が `paid_leave?` に弾かれて減算しないと残高が write-only に増え続ける。付与と消費を対称化し残高が正しく回る |
| D3 | 振替休日（substitute_holiday）の扱い | **v1 は代休（compensatory_leave）のみ提供**。振替休日は「振替元休日・振替先労働日の事前特定モデリング」が要るため後続スライスへ後置（backlog） | SPEC §6.11 の事前特定ノート: 割増免除は「あらかじめ労働日と休日を振り替えた」場合のみ・未指定は代休扱い（35% 計上対象）。§4.12 モデルに振替元/先カラムが無い。代休限定なら 35% 抑制の潜在バグを作らず最も法的に安全。ROADMAP の「代休残高 +1」文言とも一致 |
| D4 | 承認時の前提再検証 | **`ApplyApproval` 冒頭で work_date の平日性を再検証**し、申請〜承認の間にカレンダー編集で平日化していたら `Approvals::ConflictError` で承認ごと atomic rollback | 2-3 §7.4 の「承認時に前提を再確認」哲学に倣う。HWR の前提は「work_date が休日」。fail-closed。ConflictError は raise 伝播で rollback（2-2b OverBalanceError・2-3 ConflictError 同型）。インボックス controller は ConflictError を既に flash 変換（2-3） |
| D5 | HWR 承認の AttendanceHistory | **書かない**。§4.14 の event_type taxonomy は 9 値（0–8）で凍結（末尾追加のみ許可）で holiday-work イベントが無く、SPEC は HWR 承認に AttendanceHistory を要求していない | 証跡は HWR.approval_status + ApprovalAssignment（承認者・日時）+ AR.is_holiday_work フラグ自体 + 実打刻の clock_in 履歴で追える。凍結 taxonomy を独断拡張しない。35% 監査要件で holiday-work イベントが要るなら Phase 3/4 で末尾追加を再判断（backlog） |
| D6 | is_holiday_work 付与時の再計算 | **再計算しない**。§5 calculator 4 種（WorkTime/Overtime/DeepNight/LateEarly）は is_holiday_work を読まない | 35% 割増（`holiday_work_hours`）は §4.13 月次サマリ列＝Phase 3-1 集計の責務。日次 AR に holiday_work_hours 列は無い。flag を立てても §5 計算は不変ゆえ Recalculate は no-op。誤った依存の含意を避け呼ばない |
| D7 | エンジン再利用 | **Start/Approve/Reject/Cancel を全面再利用**（対象非依存） | HWR 専用の承認/取消サービスを作らない（YAGNI）。`Approvals::Cancel`（by==requester + cancel!）・`Approvals::Start`（requester.manager 遡行）は HWR でそのまま動く |

### 本スライスに含めない（明示的後置）

- **日次 35% 割増計算**（`holiday_work_hours`）→ **Phase 3-1**（MonthlySummaryService が is_holiday_work AR から月次集計・§4.13/§5.2）。2-4 は flag を立てるところまで
- **未打刻検出**（承認済 × work_date 過去 × 当日 AR 無し → 代休取消①／代理打刻②／保留③）→ **Phase 4-2**（§6.11 後段・通知基盤 4-1 依存）。本スライスは承認で代休 +1 を付与するのみ（未打刻でも +1 され得る＝Phase 4 の取消フローで整合化）
- **振替休日（substitute_holiday）＋ 振替元/先モデリング**→ **後続スライス**（backlog 追記・D3）。事前特定（振替元休日・振替先労働日・承認日時）の必須化が前提
- **撤回フロー** → HWR は 4 値で**撤回を持たない**（§13.3）。2-5 対象外
- **承認/却下の通知送信** → **Phase 4-1**（通知基盤確立まで・ROADMAP 横断ルール）。本スライスは flash で代替

---

## 1. モデル / スキーマ

### 1.1 `HolidayWorkRequest`（§4.12・`include Approvable`）

#### マイグレーション `create_holiday_work_requests`

| カラム | 型 | 制約 | 説明 |
|---|---|---|---|
| `organization_id` | bigint | NOT NULL | テナント（§3.6） |
| `requester_id` | bigint | NOT NULL | 申請者（User） |
| `work_date` | date | NOT NULL | 出勤予定日（平日以外のみ・事前/事後とも可） |
| `compensation_leave_type_id` | bigint | NOT NULL | 代償休暇種別（v1 は compensatory_leave 限定） |
| `reason` | text | NULL（モデルで presence） | 出勤理由 |
| `approval_status` | integer (enum) | NOT NULL default 0 | `Approvable`（applying:0 … canceled:3） |

#### インデックス & 参照整合（§3.6 二層防御）

- `add_index :holiday_work_requests, %i[organization_id id], unique: true`（複合 FK 標的パターン・CCR 同型）
- `add_index :holiday_work_requests, %i[organization_id requester_id approval_status]`（インボックス/本人一覧）
- **重複禁止の DB 二層防衛**: `add_index :holiday_work_requests, %i[organization_id requester_id work_date], unique: true, where: "approval_status IN (0, 1)"`（partial unique・applying/approved のみ＝canceled/rejected 後の再申請は許可）
- 複合 FK: `requester` → `users [organization_id, id]`、`compensation_leave_type` → `leave_types [organization_id, id]`（同一テナント保証）

#### モデル `app/models/holiday_work_request.rb`

```ruby
class HolidayWorkRequest < ApplicationRecord
  acts_as_tenant(:organization)
  include Approvable   # approval_status enum + AASM + 承認ライフサイクル

  belongs_to :requester, class_name: "User"
  belongs_to :compensation_leave_type, class_name: "LeaveType"

  validates :work_date, presence: true
  validates :reason, presence: true
  validate  :work_date_is_non_weekday          # 平日以外のみ（§6.11 step1）
  validate  :compensation_type_is_compensatory # v1 代休限定（D3）
  validate  :no_duplicate_active_request       # 同一日重複禁止（applying/approved）
  validate  :requester_must_belong_to_same_organization
  validate  :compensation_leave_type_must_belong_to_same_organization

  def apply_approval_effects!(acting_user:)
    HolidayWorkRequests::ApplyApproval.call(holiday_work_request: self, acting_user:)
  end
end
```

- `work_date_is_non_weekday`: `CompanyCalendarResolver.new(organization:).day_type(work_date) != :weekday`（未登録日は ISO 曜日フォールバック＝土日許可・平日拒否。§4.7）。`work_date` nil 時は skip（presence に委ねる）
- `compensation_type_is_compensatory`: `compensation_leave_type&.compensatory_leave?` でなければ error（v1。振替後置の防御線）
- `no_duplicate_active_request`: 同一 `(requester_id, work_date)` で applying/approved の他レコードがあれば error（自身は除外。DB partial unique と二層）
- 組織スコープ検証は ID 基点 fail-closed（`leave_balance.rb`/`attendance_history.rb` 同型）

### 1.2 `attendance_records.is_holiday_work`（§4.03）

```ruby
add_column :attendance_records, :is_holiday_work, :boolean, null: false, default: false
add_index  :attendance_records, %i[organization_id work_date is_holiday_work]
```

- 既定 false。承認（既存 AR）or 打刻（ClockIn/ProxyClockIn）で true になる
- index は Phase 3-1 の月次集計（is_holiday_work true の AR 抽出）を見越した予約。本スライスのクエリ起点にはしない
- **event_type taxonomy は変更しない**（D5）

### 1.3 `LeaveType#balance_tracked?`（D2）

```ruby
def balance_tracked? = paid_leave? || substitute_holiday? || compensatory_leave?
```

- 残高で管理する種別の単一述語。付与（HWR）・消費（LeaveRequest）の両方がこれで分岐
- `substitute_holiday?` を含むのは将来振替が入っても残高機構が効くようにする前向き定義（v1 は HWR 側で代休に限定するが述語自体は対称）

---

## 2. サービス

### 2.1 `HolidayWorkRequests::Create`（1 tx・CCR Create 同型）

```ruby
def call
  ActiveRecord::Base.transaction do
    hwr = HolidayWorkRequest.create!(
      requester: @requester, work_date: @work_date,
      compensation_leave_type: @compensation_leave_type, reason: @reason)
    Approvals::Start.call(hwr)   # 固定 2 段ルート（requester.manager 遡行）
    hwr
  end
end
```

- requester は controller で `current_user` 固定（外から user_id を受けない）
- `Approvals::Start` の `RouteError`（manager 未設定）は controller で flash 変換
- CCR と違い snapshot（original_*）が無い＝より単純

### 2.2 `HolidayWorkRequests::ApplyApproval`（承認副作用・`with_tenant` 自己完結）

呼び出し元: `HolidayWorkRequest#apply_approval_effects!`（`Approvals::Approve` の `with_lock` 内・同一 tx）。内側で rescue しない — `ConflictError` 等は raise 伝播し承認ごと atomic rollback。

処理順:

```
① re-validate（D4）:
   day_type = CompanyCalendarResolver.new(organization:).day_type(work_date)
   raise Approvals::ConflictError if day_type == :weekday   # 承認時に平日化していたら弾く

② balance（D2・付与）:
   fiscal_year = organization.fiscal_year_for(work_date)     # §6.2 年度跨ぎ統一
   balance = find_or_create_balance(requester, compensation_leave_type, fiscal_year)
   balance.with_lock { balance.update!(granted_days: balance.granted_days + 1) }
   # over-balance チェック無し（付与であり消費ではない）

③ is_holiday_work（D1・既存 AR のみ・予約は AR を新規作成しない）:
   ar = requester.attendance_records.find_by(work_date: work_date)
   ar.update!(is_holiday_work: true) if ar
   # 再計算しない（D6・§5 は is_holiday_work 非依存）

# AttendanceHistory は書かない（D5）
```

- `find_or_create_balance`: `LeaveBalance.find_or_create_by(user:, leave_type:, fiscal_year:)`（`with_tenant` 下で organization_id 自動付与）。新規時は granted/carry_over/used を 0 初期化。`granted_on` は `paid_annual?`（paid_leave? && annual?）でないと不要＝代休は非 annual ゆえ不要。create 競合は UNIQUE `[org,user,type,fiscal_year]` で防衛 → `RecordNotUnique` 時は再 find して lock（並行承認の二重付与防止）
- ③ の「既存 AR のみ」: 予約フェーズで AR を新規作成すると clock_in 無し・status:working 検証に抵触する不完全行ができるため作らない（事後申請＝既に打刻済の AR にのみ flag を立てる）

### 2.3 `Clockings.holiday_work_reserved?`（D1・事前付与の共有述語）

```ruby
module Clockings
  def self.holiday_work_reserved?(user, date)
    user.holiday_work_requests.approved.exists?(work_date: date)
  end
end
```

- `User has_many :holiday_work_requests, foreign_key: :requester_id` を追加
- `approved` scope は enum 由来（自動生成）
- `with_tenant` 下で呼ばれる前提（ClockIn/ProxyClockIn は既に `ActsAsTenant.with_tenant` 内）

### 2.4 `Clockings::ClockIn` / `Clockings::ProxyClockIn` 改修（D1）

両者の `attendance_records.create!(...)` に一行追加:

```ruby
is_holiday_work: Clockings.holiday_work_reserved?(@user, today)   # ClockIn
is_holiday_work: Clockings.holiday_work_reserved?(@target_user, today)  # ProxyClockIn
```

- 承認済 HWR がある休日の打刻で is_holiday_work=true。無ければ false（既定）
- ProxyClockIn は同一 tx 内（履歴記録と原子的）ゆえ追加も tx 内で安全

### 2.5 `LeaveRequests::ApplyApproval#add_to_balance` 一般化（D2・2-2b 回帰点）

```ruby
def add_to_balance
  return unless @leave_request.leave_type.balance_tracked?   # was: paid_leave?
  # 以降は不変（lock.first・over-balance ハード拒否・used_days 加算）
end
```

- これで代休（compensatory_leave）を LeaveRequest で取得時に `used_days` が減算され over-balance も効く＝付与（HWR）と消費（LeaveRequest）が対称
- **回帰注意**: 既存 2-2a/2-2b の paid_leave 経路は `balance_tracked?` が true を返すため挙動不変。代休 LeaveRequest の残高検証が**新たに有効化**される点をテストで固定

---

## 3. Controller / Policy / View / Component

### 3.1 `HolidayWorkRequestsController`（CCR controller 同型）

- `index` / `new` / `create` / `cancel`。requester=`current_user` 固定
- `create`: `params` から work_date（date）・compensation_leave_type_id・reason を取り `HolidayWorkRequests::Create.call`。`RouteError`（manager 未設定）・`ActiveRecord::RecordInvalid`（平日/重複/種別/理由）を flash 変換
- `cancel`: `policy_scope` で本人限定 → `Approvals::Cancel.call`
- work_date は date_field（CCR の `parse_org_time` のような時刻 parse は不要＝日付のみ）

### 3.2 `HolidayWorkRequestPolicy`（CCR policy 同型）

- `index?` / `new?` / `create?` — `user.is_user?`（社員以上）
- `cancel?` — `record.requester_id == user.id && record.applying?`
- `Scope#resolve` — `scope.where(requester_id: user.id)`

### 3.3 Views `app/views/holiday_work_requests/`

- `_form.html.erb`: `work_date`（date_field）＋ `compensation_leave_type_id`（select・`LeaveType.where(system_type: :compensatory_leave)` のみ）＋ `reason`（textarea ＋ ReasonTemplate chips）
- `index.html.erb`: 本人の申請一覧（policy_scope・order: work_date desc）。status バッジ（applying/approved/rejected/canceled の i18n）
- `new.html.erb`: タイトル「休日出勤申請」＋ `_form`

### 3.4 `Approvals::HolidayWorkRequestRowComponent`（型別インボックス行）

- 申請者名・「休日出勤」ラベル・work_date・代償種別名・段階（single_stage? / 第 N 段階）・理由・承認/却下ボタン
- `app/views/approval_assignments/index.html.erb` の型分岐に `when "HolidayWorkRequest"` を追加（LeaveRequest/ClockChangeRequest と並ぶ三つ目）
- 承認/却下アクション自体は対象非依存ゆえ `ApprovalAssignmentsController#approve/reject` を再利用（ConflictError は 2-3 で既に flash 変換済 → HWR の D4 平日化エラーもそのまま拾える）

### 3.5 ルーティング

```ruby
resources :holiday_work_requests, only: %i[index new create] do
  member { patch :cancel }
end
```

### 3.6 i18n（`config/locales/ja.yml`）

- `activerecord.models.holiday_work_request: 休日出勤申請`
- `activerecord.attributes.holiday_work_request`: work_date / compensation_leave_type / reason
- `holiday_work_request.status`: applying（申請中）/ approved（承認済）/ rejected（却下）/ canceled（取消）
- ReasonTemplate の `applies_to` に休日出勤を含めるか（both 流用 or 新規値）は実装時に既存定義を見て最小選択

---

## 4. テスト（TDD）

| 種別 | 対象 | 要点 |
|---|---|---|
| model | `HolidayWorkRequest` | 平日拒否／土日・休日・法定休日許可／代休以外の種別拒否（D3）／同一日重複拒否（applying・approved）・canceled 後再申請可／組織スコープ／`Approvable` lifecycle（apply/reject/cancel） |
| model | `LeaveType#balance_tracked?` | paid_leave / substitute_holiday / compensatory_leave で true・other/child_care 等で false |
| service | `HolidayWorkRequests::Create` | HWR 作成 ＋ `Approvals::Start` 起動・manager 未設定で RouteError |
| service | `HolidayWorkRequests::ApplyApproval` | ①平日化で ConflictError＋rollback ②balance find_or_create ＋ granted_days +1（既存残高・残高無し両方）・並行二重付与防止 ③既存 AR に is_holiday_work=true／AR 無しなら何もしない・**再計算が走らない**こと・**AttendanceHistory が増えない**こと |
| service | `Clockings::ClockIn` / `ProxyClockIn` | 承認済 HWR ある日の打刻で is_holiday_work=true／無ければ false |
| service | `LeaveRequests::ApplyApproval`（回帰） | 代休 LeaveRequest 承認で used_days 減算・over-balance ハード拒否が効く／既存 paid_leave 経路は挙動不変 |
| policy | `HolidayWorkRequestPolicy` | cancel? は本人 applying のみ・Scope は requester 限定 |
| request | controller | create（成功・平日/重複/種別/理由 失敗）・cancel・インボックスでの HWR 承認（balance +1・既存 AR 付与）・平日化 ConflictError の flash |
| factory | `holiday_work_requests` | work_date は休日・compensation_leave_type は compensatory_leave |

検証コマンド: `bundle exec rspec` / `bundle exec rubocop --force-exclusion <files>` / app/ に触れるので `bin/brakeman --no-pager`。

### レビュー（merge 前）

- `tenant-isolation-reviewer`（model/migration/ClockIn 改修・複合 FK・partial unique）
- `labor-law-compliance-reviewer` ＋ `/legal-citation-audit`（代休残高・35% 前提・振替後置の妥当性・§6.11 事前特定ノート整合）
- `/multi-perspective-review`（本設計・brainstorm 直後）／フェーズ未完了ゆえ `/spec-check` は Phase 2 完了時

---

## 5. ハンドオフ / バックログ追記

- **振替休日（substitute_holiday）の実装**: 振替元休日・振替先労働日・承認日時の事前特定モデリング（HWR にカラム追加 or 別テーブル）＋ 35% 抑制の根拠完備。本スライスは代休限定（D3・§6.11 事前特定ノート）。後続スライスで判断
- **HWR 未打刻検出**: 承認済 × work_date 過去 × 当日 AR 無し → 代休取消①／代理打刻②／保留③（§6.11 後段）。Phase 4-2（通知基盤 4-1 依存）。本スライスの「承認で代休 +1（未打刻でも付与）」はこの取消フローで整合化される前提
- **holiday-work の AttendanceHistory イベント**: §4.14 taxonomy 末尾に `holiday_work_approved` を追加して is_holiday_work 変更（特に事後申請の遡及付与）を監査記録するか、Phase 3（35% 計算）/4 で再判断（D5）
- **日次 35% 割増**: `holiday_work_hours` は MonthlySummaryService が is_holiday_work AR から月次集計（Phase 3-1・§4.13/§5.2）

---

## 6. 参照した RAILS_GOTCHAS / 既知の罠

- enum `validate: true`（不正値を ArgumentError でなく validation error に — `LeaveType`/`AttendanceHistory` 同型）
- 複合 FK `[organization_id, id]` 標的 ＋ partial unique index（PG18・exclusion/unique 系の罠は 0b-4/PR #3 で踏破済）
- rubocop はファイル明示渡しで `--force-exclusion` 必須（db/schema.rb 偽 FAIL 回避）
- `ActsAsTenant.with_tenant` ラップ（ClockIn/ProxyClockIn/ApplyApproval は console・将来ジョブ経路も fail-closed）
- migration 経由のみ（db/schema.rb 手編集禁止・hook 防御）
