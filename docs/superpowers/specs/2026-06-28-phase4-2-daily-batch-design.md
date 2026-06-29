# Phase 4-2 日次バッチ（打刻漏れ検知・欠勤確定・勤務間インターバル・代理打刻通知）— 設計

- 日付: 2026-06-28
- 対象: ROADMAP Phase 4-2「日次バッチ」コア 4 機能
- SPEC 参照: §6.8 / §6.9 / §6.10 / §8.4 / §9.1 / §9.2 / §10 / §3.6 / §4.8 / §4.14 / §1.4
- 前提: Phase 4-1 通知基盤（Notifier / NotificationDelivery / SuppressionWindow / ディスパッチャ→子ジョブ）完了済（PR #22/#24/#25）

## 0. ゴールと非ゴール

**ゴール**: 日次バッチによる**打刻漏れ検知**（退勤忘れ・無打刻）と**欠勤確定フロー**、出勤打刻時の**勤務間インターバル判定**、残る producer（**代理打刻通知**）を実装し、Phase 4-1 の通知パイプへ接続する。ディスパッチャ→子ジョブのテナント反復（§3.6・§10）を日次バッチで踏襲し、4-3 以降の週次/月次バッチの規範実装とする。

**非ゴール（後続 Phase・本設計に含めない）**:
- 過重労働 / 36 協定 / 有給 5 日 / 残業アラート（45h/80h/100h）等の**コンプラ検知**（Phase 4-3 週次/月次バッチ）
- 連続勤務日数（§8.5・Phase 4-3）
- **finalize 前ゲート backlog**: HWR 承認↔打刻 write-skew 整合バッチ（ROADMAP #106）/ 代休の事前消費取消（#107・社労士確認要）/ CCR new_entry（#48）— 別スライスへ後置（ブレストでスコープ確定）
- 前日積み上げ集計（§10 の "前日積み上げ"）— 計算は打刻時 `Recalculate` が担い、本バッチは検知に純化

## 1. 確定した設計判断（ブレインストーミング結果）

| # | 判断 | 根拠 |
|---|------|------|
| A | **コア 4 機能のみ**（打刻漏れ検知 / 欠勤確定 / インターバル / 代理打刻通知）。finalize 前ゲート backlog は後置 | スコープを絞りフェーズを集中。代休取消は社労士依存ゆえブロッカーを持ち込まない |
| B | 欠勤候補を**軽量な永続テーブル `AbsenceCandidate`** で保持（AR は作らない） | 一覧・notify-once（重複通知防止）・猶予・lifecycle を一元化。「AR は作らない」（§6.8）は別テーブルゆえ満たす |
| C | **4 サブ PR** に分割（4-2a データ層 / 4-2b 検知バッチ / 4-2c 欠勤確定 UI / 4-2d インターバル+代理打刻通知） | 1 スライス = 1 PR・各 PR をレビュー可能な粒度に |
| D | **次稼働日通知は「日次 run + `notified_on` dedup」で実現**（将来 job を撒かない） | 毎日走るバッチが「本人の今日が稼働日かつ未通知」の候補のみ通知 → 次稼働日に自然に送達。連続休日も `CompanyCalendarResolver` で吸収（4-1c 申し送りの回収） |
| E | **欠勤候補の対象日 = カレンダー稼働日**（day_type ∉ HOLIDAY_DAY_TYPES）。WorkPattern は稼働曜日を持たない | 唯一利用可能な「期待稼働日」シグナルはカレンダー。非常勤の過検出は**管理者が確定時にフィルタ**（manager がゲート・§6.10） |
| F | **インターバル記録/通知はクロックイン commit 後に best-effort**（打刻をブロックしない） | §6.9「打刻はブロックしない」。4-1c producer 同型（tx 後発火・rescue+log・§9.5） |

## 2. アーキテクチャ

```
                    ┌──────────── 日次バッチ（4-2b・§10 "at daily_batch_hour every day"） ───────────┐
config/recurring.yml │  DailyAttendanceJob（ディスパッチャ・current_tenant=nil）                     │
   daily_attendance ─┤    └→ Organization.active.find_each { DailyAttendanceTenantJob(org.id) }       │
                     │  DailyAttendanceTenantJob（子・with_tenant(org)）— 前日分を検査               │
                     │    ① 退勤忘れ検知 → Notifier(本人・参考・退勤申請リンク)                       │
                     │    ② 無打刻検知:                                                              │
                     │       ・欠勤候補（no AR ∧ no LR ∧ 稼働日）→ AbsenceCandidate upsert            │
                     │       ・休暇申請中無打刻（no AR ∧ LR 申請中/進行中）→ Notifier(管理者・情報提供)│
                     │    ③ 候補の通知/解決:                                                          │
                     │       ・既存候補が AR/LR で覆われた → resolve（削除）                           │
                     │       ・本人の今日が稼働日 ∧ notified_on 未設定 → Notifier(本人+管理者) + 記録  │
                     └──────────────────────────────────────────────────────────────────────────────┘

欠勤確定（4-2c・管理者 UI）                          インターバル+代理打刻（4-2d・リアルタイム）
  AbsenceConfirmationsController                       ClockingsController#clock_in
   index = AbsenceCandidate を policy_scope 一覧         └→ Clockings::ClockIn.call（既存・AR 生成）
   create = 1 社員×N 日付 + absence_reason               └→（commit 後）Clockings::IntervalCheck.call
     └→ tx: AR(absent) 一括生成 + 候補 resolve              ・前日退勤〜当日出勤 < rest_interval_hours
         + AttendanceHistory(absence_confirmed) N 件          ・AR.note 追記 + interval_violation_count++
     └→（commit 後）Notifier(本人・集約 1 件)               + AttendanceHistory(interval_shortage)
                                                            ・（commit 後）Notifier(本人 画面警告+管理者)
                                                         ProxyClockingsController#clock_in/out
                                                           └→ Clockings::ProxyClockIn/Out.call（既存）
                                                           └→（commit 後）Notifier(本人・情報提供)
```

**テナント安全（§3.6・最重要）**: `DailyAttendanceJob`（ディスパッチャ）は `current_tenant = nil` 前提で `Organization.active` をスコープ外列挙し org_id だけ子へ渡す。`DailyAttendanceTenantJob` は perform 冒頭で `ActsAsTenant.with_tenant(org)` ラップ必須（`check-job-tenant-wrap` フック対象）。4-1b の `NotificationDispatchJob`/`NotificationDispatchTenantJob` を雛形に踏襲する。

**producer 接ぎ目（§9③・4-1c の教訓）**: `Notifier.call` は**主操作の tx 確定後**に発火（欠勤確定 tx 後 / クロックイン commit 後 / 代理打刻 service 戻り後）。`with_lock`/tx 内に置かない（rollback 時の幻通知防止）。通知失敗は §9.5 準拠で rescue+log（主操作の応答/打刻を覆さない）。

## 3. データモデル（4-2a）

複合 FK は repo idiom `[organization_id, X] → table[organization_id, id]`。全新規モデルに `acts_as_tenant(:organization)` + ID 基点 `*_must_belong_to_same_organization` 検証（二層防御・§3.6）。migration は `/create-migration` 規約。

### 3.1 既存テーブルへの追加

| テーブル | 追加 | 型・既定 | 備考 |
|----------|------|----------|------|
| `attendance_records` | `status` に `absent: 5` | enum 値追加（予約済・列変更なし） | §4.8 予約整数。`absent` は打刻なし＝計算 8 列 NULL |
| 〃 | `absence_reason` | integer (enum), null 可 | §6.10。`status: absent` の時のみ非 null |
| `monthly_attendance_summaries` | `interval_violation_count` | integer, default 0, null false | §6.9 / §8.4 月内回数 |
| `organization_settings` | `rest_interval_hours` | integer, default 11 | §6.9 / §4.15 勤務間インターバル閾値 |
| 〃 | `daily_batch_hour` | integer, default 2（0..23） | §10 日次バッチ実行時刻（既定 2am） |
| `attendance_histories` | `event_type` に `absence_confirmed` / `interval_shortage` 追加 | enum 値追加（append-only） | §4.14 監査。確定/インターバル不足を記録 |

> `organization_settings` は **4-2 が消費する 2 列のみ**追加（連続勤務 `consecutive_work_day_limit` 等は 4-3 が同梱・§4.15 注記 YAGNI）。各列に妥当性検証（時刻/時間は範囲 inclusion）。`Organization#setting` の lazy 既定に新列反映。

### 3.2 新規テーブル `absence_candidates`

欠勤候補の作業状態（存在 = 未解決の候補・§6.8/§6.10）。**確定 or AR/LR 出現で削除**（resolved 状態列は持たない＝監査は `AttendanceHistory(absence_confirmed)` が担う・候補自体は ephemeral）。

| 列 | 型 | 備考 |
|----|-----|------|
| organization_id | bigint | acts_as_tenant |
| user_id | bigint | 複合 FK `[org_id, user_id]→users`・対象社員 |
| target_date | date | 未打刻の対象日（前日検知） |
| detected_on | date | バッチが最初に検知した日 |
| notified_on | date, null 可 | 本人/管理者へ通知した日（null = 未通知）。**次稼働日 dedup の鍵**（判断 D） |

- unique index `[organization_id, user_id, target_date]`（同一候補の二重生成を DB で排除・`find_or_create_by` の競合敗者を吸収）
- index `[organization_id, user_id]`（一覧/解決スキャン）
- `validate :user_must_belong_to_same_organization`（複合 FK と二層）
- `acts_as_tenant(:organization)` / `belongs_to :user`

### 3.3 enum 定義

```ruby
# AttendanceRecord（既存に absent 追加）
enum :status, { working: 0, clocked_out: 1, morning_half: 2, afternoon_half: 3,
                on_leave: 4, absent: 5 }, validate: true
enum :absence_reason, { unauthorized: 0, illness: 1, family: 2, investigating: 3, other: 4 },
     validate: { allow_nil: true }                 # absent 以外は null

# Notification.source_type（4-1 の append-only enum を拡張）
# request_approved: 0, request_rejected: 1（既存）に追加:
#   clock_out_missing: 2, absence_candidate: 3, leave_pending_no_clock: 4,
#   proxy_clocked: 5, interval_shortage: 6, absence_confirmed: 7
```

> `absence_reason` の `other` 選択時のみ `note`（AR の既存 `note` 列）に理由を入れる。other 以外は note=null（§6.10）。`Notification.source_type` は integer enum ゆえ値追加は model 編集のみ（4-1 と同方針）。

### 3.4 モデル責務

- `AttendanceRecord`: `absent` status / `absence_reason` enum / `scope :absent`（既存 enum が生成）。`absent` は LEAVE_STATUSES と同様「打刻なし」だが計算スキップ経路は既存の `calculated` scope が吸収（8 列 NULL）
- `AbsenceCandidate`: 上記。`scope :unnotified, -> { where(notified_on: nil) }`
- `OrganizationSetting`: `rest_interval_hours`（0..24 検証）/ `daily_batch_hour`（0..23 検証）
- `MonthlyAttendanceSummary`: `interval_violation_count`（default 0）

## 4. 打刻漏れ検知バッチ（4-2b）

### 4.1 ジョブ構造（§3.6・§10）

| 種別 | 名前 | 責務 |
|------|------|------|
| job | `DailyAttendanceJob`（ディスパッチャ） | `Organization.active.find_each { DailyAttendanceTenantJob.perform_later(org.id) }`（スコープ外列挙） |
| job | `DailyAttendanceTenantJob`（子） | `with_tenant(org) { AttendanceAnomalies::Detect.call(date: org.today.prev_day) }` |
| service | `AttendanceAnomalies::Detect`(PORO/Service) | 前日分の退勤忘れ・無打刻を検知し AbsenceCandidate upsert + 候補通知/解決。Notifier を呼ぶ |

`config/recurring.yml` の production に追加（§10）:
```yaml
  daily_attendance_batch:
    class: DailyAttendanceJob
    schedule: "at 2am every day"   # daily_batch_hour 既定と整合（運用で前後可）
```

### 4.2 検知ロジック（対象 = 前日 `org.today.prev_day`）

**① 退勤打刻忘れ**（§6.8）:
```
status ∈ {working, morning_half, afternoon_half} AND clock_in IS NOT NULL AND clock_out IS NULL
```
- `clock_in IS NOT NULL` で「休暇承認のみ・打刻なし」の誤検知を防ぐ
- **夜勤除外**: AR の `work_pattern.night_shift = true` はバッチ時点で勤務中の可能性 → 対象外（翌日 run で検出）
- → `Notifier(target_user: 本人, source_type: :clock_out_missing, priority: :reference)` ＋ 退勤申請リンク（§9.1 退勤打刻忘れ = 参考・ベルのみ）。本人通知ゆえ次稼働日 dedup（§4.4）対象

**② 無打刻検知**（AR を作らない・通知のみ）:

| カテゴリ | 条件（対象日・対象社員） | 扱い |
|---------|--------------------------|------|
| 欠勤候補 | AR 無 ∧ LeaveRequest（全 status）無 ∧ **対象日が稼働日**（day_type ∉ HOLIDAY_DAY_TYPES・判断 E） | `AbsenceCandidate.find_or_create_by(user, target_date)` upsert |
| 休暇申請中・打刻なし | AR 無 ∧ LeaveRequest（申請中/進行中）有 | `Notifier(管理者, :leave_pending_no_clock, :informational)`（§9.2 部下の打刻漏れ = 情報提供） |

> 対象社員の母集合は `User.active`（在籍・テナント内）。スキャンは `policy_scope` 不要（バッチは認可主体なし）だが `with_tenant` で自社限定。LeaveRequest の「申請中/進行中」は既存 status enum で判定。

### 4.3 欠勤候補の通知・解決（§6.8 次稼働日・§6.10 起点）

各 run で既存 `AbsenceCandidate` を走査:
- **解決（削除）**: 対象 (user, target_date) に AR or LeaveRequest が出現 → 候補は欠勤候補でなくなる → `destroy`（打刻変更申請で AR が出来た・事後 LR を出した等）
- **通知**: `notified_on` 未設定 ∧ **本人の今日（`org.today`）が稼働日** → `Notifier(本人, :absence_candidate, :informational)`（事前通知:「{target_date} の出勤記録がありません。打刻漏れなら打刻変更申請を（猶予: 翌営業日 17:00）」）＋ `Notifier(管理者, :absence_candidate, :informational)`（同 source_type・target=管理者・§9.2 部下の打刻漏れ）→ `notified_on = org.today` をセット（notify-once）

### 4.4 次稼働日送達（判断 D・4-1c 申し送り回収）

「通知は本人の次の稼働日に送信」（§6.8）は **4-1 Notifier の in_app 即時モデルと衝突**する（土曜検知をベルで即時に鳴らさない）。本設計は**将来 job を撒かず**、日次 run のたびに「本人の今日が稼働日（`CompanyCalendarResolver(org).day_type(org.today) ∉ HOLIDAY_DAY_TYPES`）かつ `notified_on` 未設定」の候補/退勤忘れのみ Notifier を呼ぶ。これにより:
- 土日祝検知分は本人の稼働日 run（例: 月曜 2am）まで通知が出ない＝次稼働日送達
- 連続休日（連休）も自然に吸収（CompanyCalendarResolver が連休明けを稼働日と判定）— 4-1c が「producer live 化前に連休考慮を」と申し送った宿題の回収
- email 抑制 `SuppressionWindow`（quiet hours / holiday_block）は**直交のまま**（in_app の送達日は本バッチが、email の時刻微調整は SuppressionWindow が担う・二重管理しない）

> 退勤忘れも「翌営業日バッチ」（§9.1）ゆえ同じ次稼働日 dedup 経路に載せる。退勤忘れは候補テーブルを持たないため、当日検知の退勤忘れAR を `org.today` が稼働日の時のみ通知（非稼働日検知分は翌稼働日 run で `clock_out` が依然 NULL なら通知）。

## 5. 欠勤確定フロー（4-2c）

### 5.1 コンポーネント

- `AbsenceConfirmationsController`:
  - `index` = `policy_scope(AbsenceCandidate)` を社員×日付で一覧（管理者の「欠勤候補一覧」・§6.10 step 2）。Pundit `authorize`
  - `create` = 1 社員 × **N 日付** + `absence_reason`（+ other 時 note）で一括確定（§6.10 step 3-5）
- `AbsenceConfirmationPolicy` / `AbsenceCandidatePolicy::Scope`: 管理者は「自分の部下」に絞る（既存 `policy_scope` 規約・§3.4「自分 + 部下」）。`params` の対象社員/日付は scope に対する解決で IDOR を塞ぐ

### 5.2 確定処理（単一 tx・§6.10 step 4-5）

```
ActiveRecord::Base.transaction do
  対象 N 日付それぞれ:
    AttendanceRecord.create!(user:, work_date: date, status: :absent,
                             absence_reason:, note: (other 時のみ))   # 打刻 8 列 NULL
    AbsenceCandidate.where(user:, target_date: date).destroy_all       # 候補 resolve
    AttendanceHistory.create!(event_type: :absence_confirmed, actor: current_user, ...)  # N 件
end
（commit 後）Notifier(本人, :absence_confirmed, 集約 1 件)  # 「{日付列}（計 N 日）の欠勤が確定。事後の有給申請が可能」
```

- **制限**（§6.10）: `finalized` 月の対象日への確定**禁止**（`MonthlyAttendanceSummary.status` 参照・差戻し→確定→再提出）。`deferred` 月は許可。確定前に対象日の月次 status を検証しエラー化（既存の申請制限 idiom と同型）
- **重複防止**: 確定対象日に既に AR があれば skip/エラー（候補は AR 出現で resolve 済のはずだが、競合に備え `find_or_create` でなく presence チェック）
- 通知は 1 社員 × N 日付を**1 件に集約**（§6.10 step 5）

### 5.3 §1.4 動線（4-2c で reachable）

| アクター | 目的 | 起点 route | nav 入口 | 結果 | 状態 |
|----------|------|-----------|----------|------|------|
| 管理者 | 欠勤候補を確認し欠勤確定したい | `/absence_confirmations` | GlobalNav「欠勤確定」（manager\|hr_admin） | AR(absent) 一括生成 + 通知 | ✅ |

## 6. インターバル + 代理打刻通知（4-2d）

### 6.1 勤務間インターバル（§6.9・出勤打刻時リアルタイム）

- 接ぎ目: `ClockingsController#clock_in` が `Clockings::ClockIn.call` 成功後（**commit 後**）に `Clockings::IntervalCheck.call(record:)` を呼ぶ（打刻をブロックしない・判断 F）
- 判定: 直前の退勤（同一 user の `clock_out` を持つ直近 AR）と今回 `clock_in` の間隔 < `rest_interval_hours`（既定 11）。**夜勤は翌々日の出勤で判定**（直前 AR が night_shift パターンなら 1 日跨ぎを考慮）
- 不足時（自テナント・単一 tx で記録）: `AttendanceRecord.note` 自動追記 + `MonthlyAttendanceSummary.interval_violation_count` インクリメント + `AttendanceHistory(interval_shortage)` 記録
- 通知（記録 commit 後）: 本人へ**画面警告**（clock_in レスポンスの flash/turbo）+ 管理者へ `Notifier(:interval_shortage, :informational)`。打刻はブロックしない
- enforcement mode（warning/error/block）は §8.4 の将来拡張ゆえ本 Phase は warning 固定（記録 + 通知のみ）

### 6.2 代理打刻通知（残り producer・§9.1）

- 接ぎ目: `ProxyClockingsController#clock_in/#clock_out` が `Clockings::ProxyClockIn/Out.call` 成功後（**service 戻り後**）に `Notifier(target_user: 本人, source_type: :proxy_clocked, priority: :informational)`（「{操作者}があなたの勤怠を代理で打刻しました」）
- 4-1c 承認 producer と同型: 成功時のみ・controller 層・rescue+log（通知失敗が打刻応答を覆さない）

## 7. テスト戦略

| 層 | 観点 |
|----|------|
| model | `AbsenceCandidate`（unique・テナント scoping・複合 FK 越境拒否）/ AR `absent` enum / `absence_reason` allow_nil / org_settings 新 2 列の既定・検証 |
| service | `AttendanceAnomalies::Detect`: 退勤忘れ（夜勤除外）・欠勤候補（稼働日のみ・AR/LR 有で非検知）・候補解決・notify-once（`notified_on`）。`IntervalCheck`: 閾値境界・夜勤翌々日・打刻非ブロック |
| job | `DailyAttendanceJob`: **テナント越境ゼロ**（他社 AR/候補を拾わない）。子の with_tenant ラップ |
| request | `AbsenceConfirmationsController`: 一覧 policy_scope（部下のみ）・一括確定（N 日付・finalized 禁止・IDOR）・代理打刻/clock_in 通知接続 |
| 統合 | バッチ → 欠勤候補生成 → 確定 → AR(absent) + 通知（端から端まで）。連続休日跨ぎの次稼働日送達 |

**負例の明文化**（positive 素通り防止）: 夜勤の退勤忘れ非検知 / 休日の欠勤候補非検知 / AR or LR 有の日の非検知 / 同一候補の二重通知なし（notified_on）/ 確定 IDOR（他部下/他テナント 404）/ finalized 月確定拒否 / インターバル不足でも打刻成功（非ブロック）/ 通知失敗で打刻/確定が覆らない（§9.5）/ バッチのテナント越境ゼロ。

## 8. レビュー・DoD

- **設計段階**: 本 design に `multi-perspective-review`（多視点並列 critique）を当ててから writing-plans（大物・CLAUDE.md 慣行）。critique は §10 に binding 追補として反映。
- **マージ前（各サブ PR）**:
  - `tenant-isolation-reviewer`（models / jobs / migrations に触れる全 PR・特に日次バッチのディスパッチャ→子）
  - `labor-law-compliance-reviewer`（欠勤確定の労務的扱い・インターバル閾値 §8.4 — 法定値でなく努力義務ゆえ org 設定可だが既定 11h の根拠確認）
  - `/preflight`・`bundle exec rspec`・`bundle exec rubocop --force-exclusion`・`bin/brakeman --no-pager`
  - **§1.4 到達性 DoD**（4-2c）: 「欠勤確定」が GlobalNav から到達可能・状態 ✅ が実態一致
  - 各 PR で ROADMAP 該当行更新（チェック + PR 番号）

## 9. サブ PR 分割

| PR | 範囲 | reachable? | レビュアー |
|----|------|:---:|------|
| **4-2a** データ層 | §3 の migrations + models（AR absent/absence_reason・AbsenceCandidate・org_settings 2 列・MAS interval 列・AH event_type 2 値・Notification source_type 5 値） | —（データ層） | tenant-isolation |
| **4-2b** 検知バッチ | §4 の DailyAttendanceJob/子/Detect service・recurring.yml・退勤忘れ/無打刻/候補通知・次稼働日 dedup | —（内部・caller は recurring） | tenant-isolation |
| **4-2c** 欠勤確定 UI | §5 の AbsenceConfirmationsController/Policy・一括確定・§1.4 行 + 統合テスト | ✅ | tenant-isolation + labor-law |
| **4-2d** インターバル+代理打刻通知 | §6 の IntervalCheck（clock_in フック）・代理打刻 producer 接続 | ✅ | tenant-isolation |

> 4-2a/4-2b は §1.4 行を持たない（到達面ゼロ＝データ層・内部バッチ）。4-2c/4-2d で reachable に着地。依存順は 4-2a → 4-2b → 4-2c（候補を消費）／ 4-2d は 4-2a 後いつでも可（独立）。

## 10. 多視点レビュー反映（2026-06-28・binding 追補）

6 視点（原則整合 / 実用 / YAGNI / セキュリティ・テナント / テスト網羅 / 労務正確性）の並列 critique を反映。**本節は §2〜§9 を上書きする拘束力を持つ**（writing-plans は本節を必須要件として扱う）。骨格（4 サブ PR・AbsenceCandidate・ディスパッチャ→子・tx 後発火）は妥当と確認。以下は明示の binding 修正。

### ① 退勤忘れの送達モデル（実用 High・テスト High 一致・最重要）
`prev_day` 1 点検査と「次稼働日送達」は構造矛盾（週末の退勤忘れが永久に未通知）。**解消: 退勤忘れは検知 run（前日分）で即時通知**（§9.1 退勤打刻忘れ = **参考・ベルのみ・email なし**ゆえ休日ベルは低害）。**次稼働日 deferral は email を伴う 欠勤候補のみ**に適用（`AbsenceCandidate.notified_on` + 本人稼働日ゲート）。§4.4 の「退勤忘れも翌稼働日 dedup」記述は削除。退勤忘れの notify-once は `prev_day` 限定走査が 1 AR = 1 回を自然に保証（窓走査・AR 列追加は不要）。
> （厳密な次稼働日 deferral を退勤忘れにも課す場合は AR に `clock_out_missing_notified_on` + 窓走査が要るが、参考/ベルのみゆえ v1 は即時で割り切る。upgrade path として記録。）

### ② 欠勤確定の権威源は AbsenceCandidate（セキュリティ High・原則整合 Med 一致・IDOR 封鎖）
§5.2 の確定は **params 日付を権威にしない**。`Absences::Confirm` Service が `policy_scope(AbsenceCandidate).where(user: target_user, target_date: 要求日付)` で解決し、**候補が実在する日付のみ** `AR(absent)` を生成（候補の無い日付は 422 で即終了）。これで「候補に存在しない過去日の確定捏造」をアプリ + scope の 2 層で封じる（§3.4 準拠）。`user_id` は param 名で受けるが `policy_scope(User).find` で解決（生 find 禁止）。

### ③ PORO / Service 分離（原則整合 High ×2・§2.2-①②）
- **検知**: 純粋判定（日付・AR 集合・LR 集合・稼働日を引数に分類結果を返す）を `AttendanceAnomalyDetector`(PORO・DB なし単体テスト) に切り出し、`AttendanceAnomalies::Detect`(Service) は upsert + Notifier の副作用オーケストレーターに専念。
- **欠勤確定**: controller 直 tx をやめ `Absences::Confirm.call(target_user:, dates:, absence_reason:, note:, actor:)`(Service)。controller は結果受領 + commit 後 Notifier 発火のみ。
- **インターバル**: `IntervalShortageCalculator.call(prev_clock_out:, clock_in:, threshold:) → shortage | nil`(PORO) を抽出し `IntervalCheck`(Service) は記録 + 通知に専念（実装上 Service 内 private でも可・設計判断として明示）。

### ④ YAGNI 列削除（YAGNI High ×2）
- **`daily_batch_hour` 削除**: recurring.yml が `"at 2am"` 固定で誰も読まない（SPEC §4.15 自身が警告）。動的スケジュールを実装する Phase で追加。
- **`AbsenceCandidate.detected_on` 削除**: consumer 無し・`created_at`（`insert_all`/`find_or_create_by` の初回セット）で兼用。
- → **org_settings 追加は `rest_interval_hours` 1 列のみ**（§3.1 表を更新）。**`enforcement_mode` 列は追加しない**旨を 4-2a PR description に明記（§8.4 は法改正後の将来拡張）。

### ⑤ 猶予期限のバックエンド強制（労務 Med・適正手続）
確定ガード: `notified_on` の**翌営業日 17:00 経過後のみ確定可**（`CompanyCalendarResolver` で翌営業日算出・列追加せず `notified_on` から computed）。猶予前確定は 422。本人事前通知 + 猶予で弁明機会を担保（労基法 24 条の趣旨）。

### ⑥ absent→on_leave 事後有給パスの検証 + 通知文の正確化（労務 Med）
「事後の有給申請が可能」通知は Phase 2 LR 承認 service が既存 `AR(absent)` を `on_leave` へ上書きするパス（SPEC §6.2 L777・§13）の存在に依存。**writing-plans 前に当該パスの実在を実コードで確認**し、未対応なら 4-2c scope に含めるか通知文を縮小。`investigating` 確定 AR のクリア（CCR new_entry #48 後置）も踏まえ、**通知文は「事後に有給休暇または打刻変更申請を提出できます」へ正確化**。

### ⑦ Detect のユーザー単位 rescue（実用 High）
`User.active.find_each` ブロック内で **per-user rescue + log（+ Sentry）**。1 ユーザーの例外でテナント全体の検知/通知が欠落しないことを DoD に追加。

### ⑧ テスト判別性の強化（テスト High ×3 + Med 群）— §7 に追記
- **テナント越境ゼロ**: Org B の候補/AR を**事前 seed** → Org A 子ジョブ実行 → `org_b_candidate.reload.notified_on == nil` ∧ Org B 宛 Notifier 0 件（with_tenant 除去で落ちる向き）
- **次稼働日送達**: `travel_to` で**曜日 pin の多段**（土曜 2am run → notified_on nil／月曜 2am run → 設定）。3 連休は 3 step（休日×2 → 稼働日で初めて設定）
- **非ブロック**: `response 200` 単独でなく **`interval_violation_count == 1` ∧ `AttendanceHistory(:interval_shortage)` 生成**との複合 assert
- **IDOR 2 variant 分割**: 同テナント別管理者の部下 → 404（Pundit）／他テナント候補 → 404（acts_as_tenant）
- **notify-once 3 step**: Day0 検知 → Day1 通知 → Day2 再 run で Notifier 増えない
- **interval 閾値境界**: 11h 丁度 = 非違反 / 11h−1m = 違反（< の境界・分単位丸め方向を §6.1 に明記）
- **夜勤翌々日 両方向**: 夜勤後 9h = 違反 / 12h = 非違反
- **org TZ 依存の prev_day**: TZ=UTC と Asia/Tokyo で `org.today.prev_day` が正しいことを service spec で（RAILS_GOTCHAS travel_to/TZ 罠）

### ⑨ AbsenceCandidate upsert の atomicity（実用 Low）
`find_or_create_by`（非 atomic・競合で RecordNotUnique）→ `insert_all([...], unique_by: %i[organization_id user_id target_date])` で atomic upsert。

### ⑩ rest_interval_hours 下限 1（労務 Low）
`0` 設定で `interval < 0` が常に false → 機能無効化の穴。検証を **`1..24`** に（0 を禁止）。

### ⑪ 欠勤候補の夜勤除外注記（労務 Low）
§4.2 ② に「夜勤パターン（`night_shift=true`・前日 AR が `working`/`clock_out:nil`）は①退勤忘れで捕捉ゆえ欠勤候補対象外（二重検知防止）」を明記・テスト負例化。

### ⑫ AR.status plain enum 継続の根拠記録（原則整合 High・§13.1 未回答）
`absent` 追加で 6 状態だが **plain enum 継続**。根拠: `absent` は `[*]→absent` の単方向終端・副作用は `Absences::Confirm` Service が担い AASM イベントフック不要（§13.1 注記「3 状態以上で再判断」への明示回答として記録）。

### 是認（変更不要と確認された設計判断）
ディスパッチャ→子のテナント反復（§3.6 充足）/ AbsenceCandidate 二層 FK + unique index / tx 後 Notifier + rescue+log（§9.5・4-1c 同型）/ `source_type` 6 値（全値 consumer あり）/ interval warning 固定・打刻非ブロック（努力義務段階・§8.4）/ 既定 11h（厚労省目安と一致・法定値でない）/ `absence_reason` 分類（`investigating` 含め実務妥当）/ 猶予後も自動確定せず管理者手動（賃金控除の弁明機会）/ 欠勤候補 = カレンダー稼働日 ∧ LR 全 status 除外 / 4 サブ PR 分割と依存順。
