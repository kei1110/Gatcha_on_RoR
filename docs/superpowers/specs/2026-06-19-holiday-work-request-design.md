# Phase 2-4 HolidayWorkRequest（休日出勤申請）— 設計

- 日付: 2026-06-19
- スライス: ROADMAP Phase 2-4（1 スライス = 1 ブランチ = 1 PR・`feat/phase2-4-holiday-work-request`）
- 典拠: SPEC §4.12（HolidayWorkRequest）・§6.11（休日出勤フロー）・§13.3（approval_status AASM）・§13.5（連携俯瞰）・§4.03（is_holiday_work）・§4.10（LeaveBalance）・§4.7（法定休日特定）・§8.1/§8.6（35%・有給5日）・§3.4–3.6（認可・テナント分離）
- 前提エンジン: Phase 2-1（承認エンジン）+ 2-2a/2-2b（`Approvable` hook・`Approvals::Approve/Reject/Start/Cancel`・`ApplyApproval` パターン・承認インボックス・`LeaveBalance`）+ 2-3（CCR・型別インボックス行・`ConflictError`）はすべて据付・merge 済（main = 2-3 完了）
- **本設計のブレスト確定事項（2026-06-19・`superpowers:brainstorming`）**: 下記 D1–D7 をユーザー承認済み。**多視点レビュー（`/multi-perspective-review`・6 視点）反映済**（§0 末尾）

## 0. スコープと前提

2-2b で承認の副作用パターン（汎用エンジン hook → host 別 `ApplyApproval` service・同一 tx・atomic rollback）、2-3 で型別インボックス行 Component と承認時の前提再検証（§7.4 競合チェック）が確立した。2-4 は **三つ目の承認対象 `HolidayWorkRequest`（HWR）** を投入し、「社員が休日出勤を申請 → 2 段承認 → 代休残高 +1 ＋ is_holiday_work 連動まで一周」させる。

HWR は 2-3 CCR の骨格（model + `Approvable` hook + Create + ApplyApproval + Controller + Policy + 申請 UI + 型別インボックス行）をほぼそのまま流用する。**固有の新ロジックは三点に局所化**される: ① `is_holiday_work` の双方向連動（承認＝予約／打刻＝付与）② 代休残高 +1 と消費側の対称化 ③ 代休限定（振替は後置）。

完了条件: 休日出勤が **申請 → 2 段承認 → 承認時の平日性再検証 → 代休残高 +1 ＋（既存 AR があれば）is_holiday_work 付与まで一周**し、ClockIn/ProxyClockIn が承認済 HWR のある日の打刻で is_holiday_work を立てる。撤回は持たない（4 値・§13.3）。

### 設計判断ログ

| # | 論点 | 決定 | 根拠 |
|---|------|------|------|
| D1 | `is_holiday_work` をいつ立てるか | **双方向連動**。承認＝予約（既存 AR があれば付与）／ClockIn・ProxyClockIn＝作成時付与 | §6.11 step2「承認後、当日打刻で is_holiday_work=true 自動セット」＋§13.3「is_holiday_work 予約」。事前申請（未打刻→後で打刻）と事後申請（打刻済→後で承認）の両ケースをカバー。is_holiday_work カラムは schema 未存在（§4.03 概念列・Phase 1 後送り）ゆえ本スライスで追加 |
| D2 | 代休残高の付与・消費の対称性 | **`LeaveType#balance_tracked?`（v1 は `paid_leave? \|\| compensatory_leave?`）述語を導入**し、HWR 承認の付与（+1）と LeaveRequest の消費（減算・over-balance）を同一述語で駆動。2-2b `LeaveRequests::ApplyApproval#add_to_balance` の `paid_leave?` を `balance_tracked?` に一般化 | HWR 承認で代休残高 +1 しても消費側が `paid_leave?` に弾かれて減算しないと残高が write-only に増え続ける。付与と消費を対称化し残高が正しく回る。**`substitute_holiday?` は述語に含めない**（v1 は HWR が代休限定＝真を返す経路が無いデッド項・YAGNI。振替実装スライスで追加・§1.3 レビュー反映 R1） |
| D3 | 振替休日（substitute_holiday）の扱い | **v1 は代休（compensatory_leave）のみ提供**。振替休日は「振替元休日・振替先労働日の事前特定モデリング」が要るため後続スライスへ後置（backlog） | SPEC §6.11 の事前特定ノート: 割増免除は「あらかじめ労働日と休日を振り替えた」場合のみ・未指定は代休扱い（35% 計上対象）。§4.12 モデルに振替元/先カラムが無い。代休限定なら 35% 抑制の潜在バグを作らず最も法的に安全。ROADMAP の「代休残高 +1」文言とも一致 |
| D4 | 承認時の前提再検証 | **`ApplyApproval` 冒頭で work_date の平日性を再検証**し、申請〜承認の間にカレンダー編集で平日化していたら `Approvals::ConflictError` で承認ごと atomic rollback | 2-3 §7.4 の「承認時に前提を再確認」哲学に倣う。HWR の前提は「work_date が休日」。fail-closed。ConflictError は raise 伝播で rollback（2-2b OverBalanceError・2-3 ConflictError 同型）。インボックス controller は ConflictError を既に flash 変換（2-3） |
| D5 | HWR 承認の AttendanceHistory | **書かない**。§4.14 の event_type taxonomy は 9 値（0–8）で凍結（末尾追加のみ許可）で holiday-work イベントが無く、SPEC は HWR 承認に AttendanceHistory を要求していない | 証跡は HWR.approval_status + ApprovalAssignment（承認者・日時）+ AR.is_holiday_work フラグ自体 + 実打刻の clock_in 履歴で追える。凍結 taxonomy を独断拡張しない。35% 監査で holiday-work イベントが要るなら Phase 3/4 で末尾追加を再判断（backlog・LABOR_LAW_REVIEW_NOTES #17 追記案を §5 に記載） |
| D6 | is_holiday_work 付与時の再計算 | **再計算しない**。§5 calculator 4 種（WorkTime/Overtime/DeepNight/LateEarly）は is_holiday_work を読まない | 35% 割増（`holiday_work_hours`）は §4.13 月次サマリ列＝Phase 3-1 集計の責務。日次 AR に holiday_work_hours 列は無い。flag を立てても §5 計算は不変ゆえ Recalculate は no-op。誤った依存の含意を避け呼ばない |
| D7 | エンジン再利用 | **Start/Approve/Reject/Cancel を全面再利用**（対象非依存） | HWR 専用の承認/取消サービスを作らない（YAGNI）。`Approvals::Cancel`（by==requester + cancel!）・`Approvals::Start`（requester.manager 遡行）は HWR でそのまま動く。#3 自己承認（第1=第2段階同一）防止は RouteResolver の単段縮約で担保＝§4 でテスト固定 |

### 本スライスに含めない（明示的後置）

- **日次 35% 割増計算**（`holiday_work_hours`）→ **Phase 3-1**（MonthlySummaryService が is_holiday_work AR から月次集計・§4.13/§5.2）。2-4 は flag を立てるところまで
- **未打刻検出**（承認済 × work_date 過去 × 当日 AR 無し → 代休取消①／代理打刻②／保留③）→ **Phase 4-2**（§6.11 後段・通知基盤 4-1 依存）。本スライスは承認で代休 +1 を付与するのみ（未打刻でも +1 され得る＝Phase 4 の取消フローで整合化）
- **振替休日（substitute_holiday）＋ 振替元/先モデリング**→ **後続スライス**（backlog 追記・D3）。事前特定（振替元休日・振替先労働日・承認日時）の必須化が前提
- **撤回フロー** → HWR は 4 値で**撤回を持たない**（§13.3）。2-5 対象外
- **承認/却下の通知送信** → **Phase 4-1**（通知基盤確立まで・ROADMAP 横断ルール）。本スライスは flash で代替
- **ReasonTemplate chips（休日出勤）** → v1 は reason 手入力のみ（chips 落とし・§3.3 R7）。`reason_templates.applies_to` enum への holiday_work 追加は後続

> **リリースゲート（労務レビュー R5・Codex C1/C4・§6.11 L851）**: 本スライスは承認で代休 +1 を付与するが、不整合が**顕在化するのは月次確定（finalize）と 35% 計算が入る Phase 3 以降**。**finalize を本番投入する前に Phase 4-2（または finalize 前整合チェック）が以下 3 点を解消すること**: ①「承認済・未打刻・代休 +1」（§6.11 未打刻検出）／②「approved HWR ⨯ 当日 AR あり ⨯ is_holiday_work=false」（承認↔打刻 write-skew の補正・Codex C1）／③「代休を実勤務前/未打刻で消費済 → 取消で負残高」（事前消費ハザード・Codex C4）。2-4 単独出荷は安全（①②③ が顕在化する finalize/35% 経路がまだ存在しない）。

### 多視点レビュー反映（2026-06-19・6 視点）

`/multi-perspective-review`（原則整合・実用主義・YAGNI・セキュリティ・労務法令・テスト網羅）の独立並列 critique を統合し、収束した指摘を本設計へ反映した。主要採用:

- **R1（high・原則/実用/セキュ/労務 一致）**: `balance_tracked?` を v1 では `paid_leave? || compensatory_leave?` に縮約（boolean 列と enum の OR を最小化・`substitute_holiday?` のデッド項を排除）。§1.3・D2
- **R2（high・原則/実用 一致）**: 残高付与の `find_or_create` + `RecordNotUnique` リトライは外側 `with_lock` の同一 PG tx 内で毒される（`PG::InFailedSqlTransaction`）。2-2b の `.lock.first` idiom ＋ create を `transaction(requires_new: true)` savepoint で隔離する方式に確定。§2.2
- **R3（high・YAGNI/労務）**: `attendance_records [org, work_date, is_holiday_work]` index は本スライスで読み手ゼロ＝削除（カラムは残す）。Phase 3-1 が実クエリ形状に合わせて張る。§1.2
- **R4（high/mid・労務）**: `is_holiday_work` の母数（平日以外すべて）≠ 35% 母数（legal_holiday のみ）。Phase 3 集計は `is_holiday_work AND day_type==legal_holiday` で 35% を確定する申し送りを §5 へ。§1.2 注記
- **R5（mid・労務）**: リリースゲート（finalize 前に未打刻検出が要る）を §0 に明記
- **R6（mid・セキュ）**: `cancel` の `authorize` 明示・strong params 白リスト明示・`ApplyApproval` の `with_tenant(@hwr.organization)` 明示・#3 単段縮約テスト追加。§3.1・§2.2・§4
- **R7（mid・原則/実用）**: 連動述語を `User#holiday_work_reserved_on?(date)` モデル述語へ（`Clockings` 直下の宙吊り module 関数を回避・`inverse_of` 付与）。§2.3
- **R8（労務）**: 代休 LeaveBalance を年度繰越ジョブ（Phase 4-4・SPEC §4.10）の対象に含めない（代休に carry_over は不適切）。§2.5 注記＋§5 handoff
- **R9（テスト網羅・high×4）**: prose で圧縮された負例を独立 example へ展開（孤児 AR 非作成・並行二重付与の stub 技法・代休 over-balance 境界・no-recalc を計算済 AR で・FK 二層・ProxyClockIn 主体取り違え）。§4

加えて **Codex（GPT-5.x 系）の非対話・敵対的レビュー**（別モデルの独立視点）で 6 視点が見落とした穴を反映:

- **C1/C2（high・新規）**: 承認 tx（未コミット）↔ ClockIn tx の write-skew で `is_holiday_work` が false 確定し得る（balance ロックは承認同士のみ直列化＝旧「直列化ゆえ競合なし」根拠は誤り）。flag を finalize まで advisory 扱いとし Phase 4-2 整合バッチで補正。§2.2③・§0 ゲート・§5
- **C3（mid・新規）**: `paid_leave=true` の振替種別は述語列挙に関わらず `balance_tracked?` が true（既存 paid_leave? 経路）。§1.3 に優越注記＋§4.2 に該当 example を追加
- **C4（high・新規鋭化）**: 代休を実勤務前/未打刻で消費 → 取消で負残高ハザード。§0 ゲート③・§5 handoff・社労士確認へ
- **C5（mid）**: 35% 母数を `day_type==legal_holiday` に絞ると未登録日曜フォールバックが漏れる（既存 backlog と同根）。§5 で §4.7 と相互参照
- **C6（low・既出）**: 遡及 flag の AttendanceHistory 不在は NOTES #17 案で記載済（追加対応なし）

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
- **重複禁止の DB 二層防衛**: `add_index :holiday_work_requests, %i[organization_id requester_id work_date], unique: true, where: "approval_status IN (0, 1)"`
  - applying(0)/approved(1) のみの **partial unique index**（canceled/rejected 後の再申請は許可）
  - **これは partial unique index であり exclusion constraint ではない** → RAILS_GOTCHAS の「exclusion constraint WHERE 句 schema dump 罠（`from(2).to(-3)`）」は**適用されない**（`add_index ..., unique: true, where:` は Rails 標準で schema round-trip 安定・R2 実用レビュー峻別）
  - `where` 句の生整数 `0,1` は **`approval_status` enum の applying=0/approved=1 に依存**（Approvable で 0–3 凍結宣言済）。一次防衛は model の `no_duplicate_active_request`（enum 述語ベース）・DB は二層
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
  validate  :compensation_type_is_compensatory # v1 代休限定（D3・振替退行防止）
  validate  :no_duplicate_active_request       # 同一日重複禁止（applying/approved）
  validate  :requester_must_belong_to_same_organization
  validate  :compensation_leave_type_must_belong_to_same_organization

  def apply_approval_effects!(acting_user:)
    HolidayWorkRequests::ApplyApproval.call(holiday_work_request: self, acting_user:)
  end
end
```

- `work_date_is_non_weekday`: `CompanyCalendarResolver.new(organization:).day_type(work_date) != :weekday`（未登録日は ISO 曜日フォールバック＝土日許可・平日拒否。§4.7）。`work_date` nil 時は skip（presence に委ねる＝resolver を nil で呼ばない）
- `compensation_type_is_compensatory`: `compensation_leave_type&.compensatory_leave?` でなければ error。**コメントに「v1 は振替（substitute_holiday）を選べない＝割増免除運用を作らない・SPEC §6.11 事前特定ノート」と明記**し将来 enum で振替が選べる退行を防ぐ（労務レビュー R）
- `no_duplicate_active_request`: 同一 `(requester_id, work_date)` で applying/approved の他レコードがあれば error（自身は除外。DB partial unique と二層・UX 用 422 / DB は並行 TOCTOU の真の防衛線）
- 組織スコープ検証は ID 基点 fail-closed（`leave_balance.rb`/`attendance_history.rb` 同型）

### 1.2 `attendance_records.is_holiday_work`（§4.03）

```ruby
add_column :attendance_records, :is_holiday_work, :boolean, null: false, default: false
# index は張らない（R3）: Phase 3-1 が実集計クエリの形状に合わせて張る
```

- 既定 false。承認（既存 AR）or 打刻（ClockIn/ProxyClockIn）で true になる
- **`is_holiday_work=true` は「承認済み休日出勤日への打刻」を意味し、35%（法定休日労働）とは母数が異なる**（R4・労務）。`is_holiday_work` は work_date が「平日以外」なら所定休日（土日・company_holiday）でも true。一方 35% 割増（`holiday_work_hours`）の対象は**法定休日（legal_holiday）労働のみ**（SPEC §8.1・L484）。**Phase 3 集計は `is_holiday_work AND day_type==legal_holiday` で 35% を確定**し、`is_holiday_work` 単独を 35% 母数に流用しない（所定休日労働の過大割増を防ぐ）。§5 handoff 参照
- **event_type taxonomy は変更しない**（D5）

### 1.3 `LeaveType#balance_tracked?`（D2・R1）

```ruby
# 残高で管理する種別の述語。付与（HWR 承認）・消費（LeaveRequest 承認）の両方がこれで分岐。
# paid_leave は admin 設定の boolean 列（有給消化系）、compensatory_leave は system_type enum（代償休暇）。
# v1 は振替（substitute_holiday）を述語に列挙しない＝HWR が代休限定で真を返す経路が無いデッド項を作らない。
# 振替実装スライスで substitute_holiday? を追加（その際の残高乗せ可否は振替設計で再判断）。
def balance_tracked? = paid_leave? || compensatory_leave?
```

> **`paid_leave=true` の優越に注意（Codex C3）**: 述語は `paid_leave?` 単独でも true ゆえ、admin が `system_type=substitute_holiday` の種別に `paid_leave=true` を立てれば**列挙の有無に関わらず balance_tracked? は true** になる（既存 `paid_leave?` 経路と同一・D2 で挙動は変えていない）。「v1 で振替を残高管理から外す」保証は述語ではなく **admin が振替種別に paid_leave を立てない運用**＋HWR が振替を選べない（`compensation_type_is_compensatory`）ことに依存する。振替の残高扱いを厳密に閉じるなら `system_type=substitute_holiday && paid_leave=true` を禁じる LeaveType バリデーションを振替実装スライスで追加（v1 は YAGNI で見送り・本注記で受容を明示）。

- 既存 `paid_leave?` 単独ガードに `compensatory_leave?` を足す最小拡張。`paid_leave=true` 種別の挙動は不変（回帰なし）。**新たに有効化されるのは `paid_leave=false` の代休種別の残高追従**（=設計意図）
- 付与（HWR.compensation_leave_type）と消費（LeaveRequest.leave_type）は**同一 `leave_type_id` の LeaveBalance 行**を指して初めて対称になる（社員が付与された代休と同じ種別で取得）。組織が複数の compensatory_leave 種別を持つ場合の取り違えは UX/運用注意（2-4 ブロッカーではない）

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
- `Approvals::Start` の `RouteError`（manager 未設定）は **tx 内 raise → create! ごと rollback**（HWR を残さない・atomic）→ controller で flash 変換
- CCR と違い snapshot（original_*）が無い＝より単純

### 2.2 `HolidayWorkRequests::ApplyApproval`（承認副作用・`with_tenant` 自己完結）

呼び出し元: `HolidayWorkRequest#apply_approval_effects!`（`Approvals::Approve` の `with_lock` 内・同一 tx）。内側で rescue しない — `ConflictError` 等は raise 伝播し承認ごと atomic rollback。**全体を `ActsAsTenant.with_tenant(@hwr.organization)` でラップ**（CCR/LeaveRequest ApplyApproval 同型・文脈喪失/将来ジョブ化に fail-closed・R6）。`organization` は一貫して `@hwr.organization`。

処理順:

```ruby
ActsAsTenant.with_tenant(@hwr.organization) do
  # ① re-validate（D4・R6）— 承認時に平日化していたら弾く
  resolver = CompanyCalendarResolver.new(organization: @hwr.organization)
  raise Approvals::ConflictError if resolver.day_type(@hwr.work_date) == :weekday

  # ② balance（D2・付与）— 2-2b .lock.first idiom + create を savepoint 隔離（R2）
  fiscal_year = @hwr.organization.fiscal_year_for(@hwr.work_date)   # §6.2 年度跨ぎ統一
  balance = lock_or_create_balance(@hwr.requester_id,
                                   @hwr.compensation_leave_type_id, fiscal_year)
  balance.update!(granted_days: balance.granted_days + 1)
  # over-balance チェック無し（付与であり消費ではない）

  # ③ is_holiday_work（D1・既存 AR のみ・予約は AR を新規作成しない）
  ar = @hwr.requester.attendance_records.find_by(work_date: @hwr.work_date)
  ar.update!(is_holiday_work: true) if ar
  # 再計算しない（D6・§5 は is_holiday_work 非依存）／AR を新規作成しない（未打刻は予約のまま）
end
```

`lock_or_create_balance`（R2・tx 毒回避の要）:

```ruby
def lock_or_create_balance(user_id, leave_type_id, fiscal_year)
  scope = LeaveBalance.where(user_id:, leave_type_id:, fiscal_year:)
  # まず行ロック取得（2-2b add_to_balance と同型・並行承認の二重 +1 を直列化）
  balance = scope.lock.first
  return balance if balance

  # 行が無ければ create。RecordNotUnique は savepoint 内に隔離（親 with_lock tx を毒さない）
  begin
    ActiveRecord::Base.transaction(requires_new: true) do
      LeaveBalance.create!(user_id:, leave_type_id:, fiscal_year:,
                           granted_days: 0, carry_over_days: 0, used_days: 0)
    end
  rescue ActiveRecord::RecordNotUnique
    # 並行 create の敗者 — 行は既に存在。savepoint のみ rollback、親 tx は健全
  end
  scope.lock.first   # 自分の create でも敗者の合流でも、ここで FOR UPDATE 再取得
end
```

- `granted_on` は `LeaveBalance` の既存バリデーション（`presence: true, if: :paid_annual?`）に委ねる。代休は `paid_annual?`（paid_leave? && annual?）が false ゆえ **granted_on 不要**（spec で要否を再説明せず model を SSOT に・原則レビュー）
- ③ の「既存 AR のみ」: 予約フェーズで AR を新規作成すると clock_in 無し・status:working 検証に抵触する不完全行ができるため作らない（事後申請＝既に打刻済の AR にのみ flag を立てる）。**AR を `lock` せず `find_by` で引く**（CCR の `lock.find(id)` と非対称・理由は次項）
- **承認↔打刻の write-skew（Codex 敵対レビュー C1/C2・既知の受容リスク）**: 承認 tx（未コミット）と ClockIn tx が同時実行されると、ClockIn は未コミットの approved を見られず `is_holiday_work=false` の AR を作り、承認側 §2.2③ も未コミット AR を見られず flag 付与をスキップし得る。**balance の行ロックは「承認同士」を直列化するが ClockIn は balance を lock しないため承認↔打刻は直列化されない**（旧コメントの「直列化ゆえ競合なし」は誤り・C2）。結果 approved HWR + clocked AR が揃うのに flag=false で確定し得る。**2-4 ではこの flag を finalize までの advisory として扱い、Phase 4-2 の整合バッチで「approved HWR ⨯ 当日 AR あり ⨯ is_holiday_work=false」を検出・補正**する（未打刻検出と同じ走査に相乗り・§5 handoff・R5 ゲート）。日次の発生確率は低く（同日・狭窓）、消費点（finalize/35%）は Phase 3 ゆえ 2-4 単独出荷は安全

### 2.3 `User#holiday_work_reserved_on?`（D1・事前付与の述語・R7）

```ruby
# User モデル
has_many :holiday_work_requests, foreign_key: :requester_id, inverse_of: :requester

# 承認済 HWR が当日にあるか（ClockIn/ProxyClockIn が打刻 AR の is_holiday_work 初期値に使う）。
# acts_as_tenant default_scope + association 起点ゆえ他人/他テナントの HWR を拾わない。
def holiday_work_reserved_on?(date) = holiday_work_requests.approved.exists?(work_date: date)
```

- `approved` scope は enum 由来（自動生成）
- `Clockings` 直下の module 関数でなく User 述語に置く（`paid_annual?` 等のモデル述語流儀・呼び出しが `@user.holiday_work_reserved_on?(today)` で読める・テナントスコープが user 経由で自然）

### 2.4 `Clockings::ClockIn` / `Clockings::ProxyClockIn` 改修（D1）

両者の `attendance_records.create!(...)` に一行追加（**いずれも既存の `ActsAsTenant.with_tenant` ブロック内**で評価）:

```ruby
is_holiday_work: @user.holiday_work_reserved_on?(today)          # ClockIn
is_holiday_work: @target_user.holiday_work_reserved_on?(today)   # ProxyClockIn（target_user・operator ではない）
```

- 承認済 HWR がある休日の打刻で is_holiday_work=true。無ければ false（既定）
- ProxyClockIn は **target_user** の予約を見る（operator のではない・R8 テストで主体取り違えを pin）。同一 tx 内（履歴記録と原子的）ゆえ追加も tx 内で安全
- 平日打刻でも述語が定数 1 クエリを足す（N+1 ではない）。早期 return 最適化はしない（CompanyCalendarResolver 呼出と相殺・過剰最適化回避）

### 2.5 `LeaveRequests::ApplyApproval#add_to_balance` 一般化（D2・2-2b 回帰点）

```ruby
def add_to_balance
  return unless @leave_request.leave_type.balance_tracked?   # was: paid_leave?
  # 以降は不変（lock.first・over-balance ハード拒否・used_days 加算）
end
```

- これで代休（compensatory_leave）を LeaveRequest で取得時に `used_days` が減算され over-balance も効く＝付与（HWR）と消費（LeaveRequest）が対称
- **回帰注意**: 既存 paid_leave 経路は `balance_tracked?` が true を返すため挙動不変。代休 LeaveRequest の残高検証が**新たに有効化**される（残高行が無ければ available=0 → OverBalanceError＝対応 HWR 承認前に代休 LR を出すと fail-closed に拒否。これは仕様意図）
- **繰越ジョブとの相互作用（R8・労務）**: `balance_tracked?` 拡張で代休も `used_days`/over-balance 対象になるが、**代休 LeaveBalance は年度繰越ジョブ（Phase 4-4・SPEC §4.10）の対象に含めない**（代休に carry_over は不適切）。繰越ジョブ側のフィルタを `paid_annual?` に限定済みか Phase 4-4 着手時に確認（§5 handoff）。本スライスのテストで「代休 LeaveBalance は carry_over_days=0 を維持」を pin

---

## 3. Controller / Policy / View / Component

### 3.1 `HolidayWorkRequestsController`（CCR controller 同型）

- `index` / `new` / `create` / `cancel`。requester=`current_user` 固定
- **strong params 白リスト**: `params.require(:holiday_work_request).permit(:work_date, :compensation_leave_type_id, :reason)`。**`requester_id` / `approval_status` は受けない（サーバ権威）** — requester は `current_user` 固定、approval_status は Approvable/エンジンのみが遷移
- `create`: `HolidayWorkRequests::Create.call`。`RouteError`（manager 未設定）・`ActiveRecord::RecordInvalid`（平日/重複/種別/理由）を flash 変換。work_date は date_field（CCR の `parse_org_time` のような時刻 parse は不要）
- `cancel`: `policy_scope` で対象取得 → **`authorize @hwr, :cancel?`（明示・R6）** → `Approvals::Cancel.call`。`AASM::InvalidTransition` を rescue（CCR `cancel` 同型）

### 3.2 `HolidayWorkRequestPolicy`（CCR policy 同型）

- `index?` / `new?` / `create?` — `user.is_user?`（社員以上）
- `cancel?` — `record.requester_id == user.id && record.applying?`
- `Scope#resolve` — `scope.where(requester_id: user.id)`

### 3.3 Views `app/views/holiday_work_requests/`

- `_form.html.erb`: `work_date`（date_field）＋ `compensation_leave_type_id`（select・`LeaveType.where(system_type: :compensatory_leave)` のみ）＋ `reason`（textarea・**v1 は手入力のみ＝ReasonTemplate chips を出さない・R7**）
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

---

## 4. テスト（TDD）

各 prose を独立 example へ展開（R9・テスト網羅レビュー）。リポジトリ既存作法のマッチャを使う: `not_to change`・`not_to receive`・`raise_error` + `.reload` 状態確認・`in_savepoint` + `save!(validate: false)`。

### 4.1 model `HolidayWorkRequest`

- `work_date_is_non_weekday`: 登録済 legal_holiday → valid／未登録土曜（ISO フォールバック）→ valid／登録済平日 → invalid／**work_date nil → resolver を呼ばず presence に委ねる**（3+1 経路）
- `compensation_type_is_compensatory`: compensatory_leave → valid／**substitute_holiday → invalid**（D3 退行防止）／annual 等 → invalid
- `no_duplicate_active_request`: applying/approved 重複 → invalid／**canceled 後再申請 → valid**／**rejected 後再申請 → valid**（partial index IN(0,1) ゆえ rejected も許可・canceled だけで証明しない）／DB 層 `in_savepoint { save!(validate: false) }` で 2 件目 applying 同一 `(requester, work_date)` → `RecordNotUnique`（二層）
- テナント越境 FK 二層（`leave_balance_spec` L64–98 同型）: `requester` と `compensation_leave_type` の各々で model `be_invalid` + `errors[...]`、かつ `in_savepoint { save!(validate: false) }` → `ActiveRecord::InvalidForeignKey`（計 4 example・DB 層を落とさない）
- `Approvable` lifecycle: apply/reject/cancel 遷移

### 4.2 model `LeaveType#balance_tracked?`

- paid_leave(列 true) → true（**system_type 不問**＝既存挙動）／compensatory_leave かつ paid_leave=false → true（D2 新挙動）／**substitute_holiday かつ paid_leave=false → false**（v1 デッド項除外を pin）／annual(paid_leave 無)・child_care・other(paid_leave 無) → false。**全 system_type を `paid_leave=false` で列挙**し default-false を保証。加えて **`substitute_holiday` かつ `paid_leave=true` → true** を 1 example で pin（Codex C3・「振替は paid_leave 列で乗り得る／述語列挙では閉じない」ことを明示）

### 4.3 service `HolidayWorkRequests::Create`

- HWR 作成 ＋ `Approvals::Start` 起動（assignment 生成）
- manager 未設定 → `RouteError` かつ **`not_to change { [HolidayWorkRequest.count, ApprovalAssignment.count] }`**（tx atomic・HWR を残さない）

### 4.4 service `HolidayWorkRequests::ApplyApproval`

- **① 平日化 ConflictError + atomicity**: 承認直前にカレンダー編集で平日化 → `ConflictError`、かつ `balance.granted_days` が +1 されない・既存 AR の `is_holiday_work` が flip しない（balance も AR も巻き戻る）
- **② balance 付与**: 残高行あり → +1／**残高行なし → 新規作成され `granted_days==1, used_days==0, carry_over_days==0, granted_on==nil`**（full 属性 pin）／balance の `user_id` が **requester（acting_user でない）**
- **② 並行二重付与防止**: `LeaveBalance` 取得を stub して `RecordNotUnique` を一度起こし、savepoint 隔離 → 再 `lock.first` 経路を通って `granted_days` が**ちょうど +1**（+2 でも error でもない・clock_in_spec L82 のレース stub 技法に倣う）
- **③ is_holiday_work（双方向マトリクス）**: (a) 既存 clocked AR あり → 承認で true／(b) **AR 無し → 承認後も AR を新規作成しない**（`not_to change { AttendanceRecord.count }`・予約は AR を作らない・§2.2 ③）かつ balance は +1
- **③ no-recalc / no-history（否定 pin）**: 計算済（clocked_out・actual_work_hours 等 non-nil）AR に承認 → `expect(Clockings::Recalculate).not_to receive(:call)` かつ calc 列が `.reload` で不変／`not_to change { AttendanceHistory.count }`

### 4.5 model `User#holiday_work_reserved_on?`（述語直接 unit）

- approved + 同日 → true／**applying（未承認）→ false**／**別日 approved → false**／**別 user の approved → false**／**他テナント approved → false**（4 false + 1 true・ClockIn 経由でなく述語で scope バグを隔離）

### 4.6 service `Clockings::ClockIn` / `ProxyClockIn`

- ClockIn: 承認済 HWR ある日 → `is_holiday_work=true`／無し → false
- **ProxyClockIn 主体取り違え**: operator が HWR 保持・target 無し → `is_holiday_work=false`（target_user を見る・operator のではない）／target が approved HWR → true

### 4.7 service `LeaveRequests::ApplyApproval`（回帰・D2）

- **代休 LeaveRequest 消費**: 残高 +1 済の代休を取得 → `used_days` 減算／over → `OverBalanceError` + `used_days` 不変 + **AR/history 未作成**（順序契約）／**境界**（消費 == remaining）→ 成功（`>` vs `>=` off-by-one pin）／（`apply_approval_spec` L33–55 を compensatory_leave で clone）
- **既存 paid_leave 経路の不変**（回帰）／**代休 LeaveBalance は carry_over_days=0 維持**（R8）

### 4.8 policy / request

- policy: `cancel?` は本人 applying のみ・Scope は requester 限定
- **#3 単段縮約**（D7・R6）: requester の 2 段ルートが同一 approver に縮約される構成で assignment が 1 件になることを HWR で固定
- request: create（成功・平日/重複/種別/理由 失敗）・cancel（authorize 経由）・インボックスでの HWR 承認（balance +1・既存 AR 付与）・平日化 ConflictError の flash・**他テナント assignment の approve が 404**

### 4.9 factory

- `holiday_work_requests`: work_date は休日・compensation_leave_type は compensatory_leave（純粋属性のみ・after(:create) callback を持たない＝2-3 の factory 教訓）

検証コマンド: `bundle exec rspec` / `bundle exec rubocop --force-exclusion <files>` / app/ に触れるので `bin/brakeman --no-pager`。

### レビュー（merge 前）

- `tenant-isolation-reviewer`（model/migration/ClockIn・ProxyClockIn 改修・複合 FK・partial unique）
- `labor-law-compliance-reviewer` ＋ `/legal-citation-audit`（代休残高・35% 前提・振替後置の妥当性・§6.11 事前特定ノート整合）
- `/spec-check` は Phase 2 完了時

---

## 5. ハンドオフ / バックログ追記

- **振替休日（substitute_holiday）の実装**: 振替元休日・振替先労働日・承認日時の事前特定モデリング（HWR にカラム追加 or 別テーブル）＋ 35% 抑制の根拠完備。`balance_tracked?` に `substitute_holiday?` を乗せるか（振替は日付 swap で割増免除＝残高に乗らない可能性）はこの設計で再判断。本スライスは代休限定（D3・§6.11 事前特定ノート）
- **HWR 未打刻検出 + 承認↔打刻整合（§6.11 後段・Codex C1）**: Phase 4-2（通知基盤 4-1 依存）の整合バッチは ①承認済 × work_date 過去 × 当日 AR 無し → 代休取消①／代理打刻②／保留③、に加え ②**approved HWR × 当日 AR あり × is_holiday_work=false → flag 補正**（承認↔打刻 write-skew の収束・同じ走査に相乗り）を行う。**リリースゲート（§0）: finalize（Phase 3）投入前に必須**
- **代休の事前消費ハザード（Codex C4・労務 NOTES 追記）**: HWR 承認で代休 +1 → 社員が**実勤務前/未打刻のまま** LeaveRequest で代休を消費でき、その後未打刻なら Phase 4-2 の代休取消（granted −1）で **granted 0・used 1 = remaining 負**になり得る。over-balance チェックは「付与超の消費」は防ぐが「勤務前消費」は防がない。**Phase 4-2 の取消フローは『消費済代休を取り消す場合の負残高/差戻し』を扱う**こと＋**社労士確認**（実労働なき代償休暇付与・先取り消費の運用可否）。リリースゲート（§0）に含む
- **Phase 3-1 の 35% 母数（R4・労務・Codex C5）**: `holiday_work_hours`（35%）の母数は `is_holiday_work` 単独でなく **`is_holiday_work AND day_type==legal_holiday`** で確定（所定休日労働は 35% 対象外・SPEC §8.1）。ただし **legal_holiday 登録漏れの組織では未登録日曜が resolver フォールバックで `:sunday` に降格し 35% から漏れる**（Codex C5・SPEC §4.7「要確認」状態・ROADMAP backlog「legal_holiday カバレッジ失効」と同根）。Phase 3-1 は §4.7 の「要確認」フォールバック扱いと整合させること。`is_holiday_work` index もこの実クエリ形状で Phase 3-1 が張る（R3）
- **代休 LeaveBalance の繰越除外（R8・労務）**: 年度繰越ジョブ（Phase 4-4・SPEC §4.10）のフィルタを `paid_annual?` に限定し代休を含めない（代休に carry_over は不適切）
- **holiday-work の AttendanceHistory イベント / 遡及付与の証跡（D5・労務 NOTES #17 追記案）**: 事後申請で打刻済 AR に遡及で is_holiday_work=true を立てる経路は AttendanceHistory に残らず、証跡は HWR.approval_status + ApprovalAssignment（承認者・日時）に依存。労基法 109 条の保存・証跡要件をこの設計で満たすか社労士確認（§4.14 taxonomy 末尾に `holiday_work_approved` を追加するかを Phase 3/4 で再判断）

---

## 6. 参照した RAILS_GOTCHAS / 既知の罠

- enum `validate: true`（不正値を ArgumentError でなく validation error に — `LeaveType`/`AttendanceHistory` 同型）
- **`RecordNotUnique` は PG tx 全体を aborted 化**（後続 `update!` が `PG::InFailedSqlTransaction`）→ 外側 `with_lock` 内の create は `transaction(requires_new: true)` savepoint で隔離（R2・§2.2）
- 複合 FK `[organization_id, id]` 標的 ＋ **partial unique index**（`add_index ..., unique: true, where:`）は exclusion constraint ではない＝schema dump 罠の対象外（R2 峻別）
- rubocop はファイル明示渡しで `--force-exclusion` 必須（db/schema.rb 偽 FAIL 回避）
- `ActsAsTenant.with_tenant` ラップ（ClockIn/ProxyClockIn/ApplyApproval は console・将来ジョブ経路も fail-closed）
- migration 経由のみ（db/schema.rb 手編集禁止・hook 防御）
