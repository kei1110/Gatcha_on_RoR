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
「事後の有給申請が可能」通知は Phase 2 LR 承認 service が既存 `AR(absent)` を `on_leave` へ上書きするパス（SPEC §6.2 L808・§13）の存在に依存。**writing-plans 前に当該パスの実在を実コードで確認**し、未対応なら 4-2c scope に含めるか通知文を縮小。`investigating` 確定 AR のクリア（CCR new_entry #48 後置）も踏まえ、**通知文は「事後に有給休暇または打刻変更申請を提出できます」へ正確化**。

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

## 11. 多視点レビュー反映（2nd pass・2026-07-02・binding 追補）

§10（設計時 1st pass）が対象化しなかった「**4-2a 実装 ↔ 既存/後続コードの接ぎ目**」を、マージ済み 4-2a を対象に 6 視点で再 critique（原則整合 / 実用+YAGNI / テスト網羅 / セキュリティ・テナント / 労務正確性 / tx atomicity・状態機械）。骨格（4 サブ PR・AbsenceCandidate 二層 FK・ディスパッチャ→子・tx 後 Notifier）に**越境の実害漏洩 High は無し**と再確認。潜在的欠陥はすべて接ぎ目に集中していた。**本節は §2〜§10 を上書きする**（writing-plans は §10 と本節を必須要件として扱う）。

### ①【最重要・4-2c merge ブロック】absent は非終端 — exit で随伴列をクリア（§10⑫ を訂正）
§10⑫ の「`absent` は `[*]→absent` の単方向終端」は **SPEC §13.1 と事実矛盾**（§13.1 状態遷移図 L1261-1263 は `absent→working`・`absent→clocked_out`・`absent→on_leave` の 3 出辺を明示・原典再確認済）。この誤前提ゆえ「absent を出る時の随伴列後始末」が設計から脱落した。
- **機序（原則整合/労務/tx atomicity の 3 視点が独立確認・Confirmed）**: 4-2c が `status:absent, absence_reason:非nil` の AR を確定 → 後日その同一 (user, work_date) に事後有給 LR が承認される → `LeaveRequests::ApplyApproval#upsert_attendance_records`（apply_approval.rb:51-56）が `find_or_initialize_by(user_id:, work_date:)` で**既存 absent AR を拾い** `status=:on_leave` に上書きするが `absence_reason` を残す → `save!` で 4-2a 新設の `absence_reason_only_on_absent`（attendance_record.rb:71-75）が発火 → `RecordInvalid` → `Approvals::Approve#call` の `with_lock`/同一 tx ごと**承認全体が rollback**（controller が「承認できませんでした」に反転）。半休（morning_half/afternoon_half）でも同じ。
- **現状 dormant**（absent AR を作る `Absences::Confirm` が未実装）→ **4-2c 出荷で live 化**。
- **binding 修正（4-2c で apply_approval を必ず同時修整＝merge ブロック条件）**:
  - `upsert_attendance_records` が既存 AR を拾った際、absent からの遷移なら `record.absence_reason = nil` / `record.note = nil` を**明示クリア**してから `save!`。
  - §10⑫ の根拠記述を訂正: 「absent は**非終端**（LR 承認で on_leave 化・§13.1）。plain enum 継続は据置だが、AASM exit フックが無いぶん**遷移を起こす各 service が随伴列クリアの責務を負う**」。
  - 回帰テスト: `absent(absence_reason 有) → 事後有給 LR 承認 → on_leave 昇格成功 ∧ absence_reason=nil`（現状この遷移は無テスト＝apply_approval_spec は新規作成のみ）。RAILS_GOTCHAS に罠を還流済（「enum 排他検証 × 遷移随伴列クリア漏れ」）。note 一括クリアは安全（absent AR の note は §3.3 により欠勤 other 理由専用・打刻なしゆえ interval 追記等は載らない）。
  - **レビュアー追加**: 本修正で 4-2c は `LeaveRequests::ApplyApproval`（承認副作用）に触れるため、§9 表の tenant-isolation + labor-law に **`approval-engine-reviewer` を追加**（CLAUDE.md トリガー「ApplyApproval に触れたら merge 前」準拠）。

### ② absent→on_leave は absence_to_paid を記録（§6.2 L808・監査の穴）
`AttendanceHistory` の `absence_to_paid`(event_type 6) は **enum 予約のみで writer 皆無**。`ApplyApproval#record_history` は無条件で `leave_approved` を記録し「新規 on_leave」と「absent→on_leave 変換」を区別しない → 労基法 109 条 5 年保存の監査（§4.14）で欠勤→有給振替の痕跡が残らない。
- **binding（4-2c）**: ①の exit クリアと同時に、拾った AR が変換前 absent だった場合は `absence_to_paid` を記録し previous_status を保持。

### ③ 事後救済 remedy が揃うまで確定通知文を縮小（労基法 24 条・虚偽の約束回避）
確定通知が挙げるもう一方の remedy「打刻変更申請」も CCR `new_entry` が明示拒否（clock_change_request.rb:20・#48 後置）ゆえ非機能。①未修整時は**有給も打刻変更も動かない＝二重の虚偽 remedy**。
- **binding（4-2c）**: ①②が通るまで確定通知文から「事後に有給休暇/打刻変更申請を提出できます」を削り「管理者へお問い合わせください」に縮小。①②実装後に「事後に有給休暇の申請ができます」へ戻す（打刻変更は #48 まで約束しない）。

### ④ 偽陽性候補の却下（dismiss）経路 — 判断 E の出口を用意（YAGNI High）
判断 E は「非常勤の過検出は管理者が確定時にフィルタ」で許容するが、候補の消滅経路は §3.2 の 2 つ（AR/LR 出現→destroy / 欠勤確定→destroy）のみ。管理者が「これは欠勤でない」と判断した候補は、確定すると誤 AR(absent) を生む＝確定できず、`notified_on` 済のまま**永久残留**し確定一覧（§5.1 policy_scope 全件）に恒久ノイズが蓄積する。
- **binding（4-2c）**: 「却下(dismiss)＝候補 destroy（監査に残さず消す・ephemeral 一貫）」の管理者経路を用意し、判断 E の「フィルタ」を機能させる出口とする。

### ⑤ insert_all は organization_id を明示・二層防御は DB 複合 FK に縮退（§10⑨ 補強）
§10⑨ の `insert_all(unique_by:)` は **validation・callback・acts_as_tenant の organization_id 自動注入を全 skip** → `user_must_belong_to_same_organization`（model 層）が無効化し二層防御が **DB 複合 FK `[org,user]→users` の 1 層に縮退**。org_id を明示しないと NOT NULL 違反でテナントの検知が丸ごと落ちる（repo 初出パターンゆえ踏みやすい）。
- **binding（4-2b）**: insert_all の各 row に `organization_id: ActsAsTenant.current_tenant.id` を明示。越境拒否テストは model 検証でなく **DB 層**（`RecordNotUnique`/`InvalidForeignKey`）で assert（model 検証は factory/console 経路の防御として残す）。二層が insert_all で片肺化する旨を 4-2b PR description に明記。

### ⑥ 4-2c の user/日付解決は policy_scope 経由（§10② 補強・IDOR + 500 回避）
`AttendanceRecord` には `user_must_belong_to_same_organization` が無い（clock/leave/absence_reason 検証のみ）。4-2c が生 param の `user_id` を `AR.create!` に渡すと DB FK 違反の **500**（clean 404 でない）、候補ゲートを生クエリでやると同テナント別部下の越えを塞げない。
- **binding（4-2c）**: (1) 対象社員は `policy_scope(User).find(params[:user_id])` で解決済みオブジェクトを `AR.create!` に渡す、(2) 日付は `policy_scope(AbsenceCandidate).where(user:, target_date: 要求)` で**実在候補のみ**確定・他は 422、(3) IDOR 2 variant（同テナント別部下→404 Pundit / 他テナント→404 acts_as_tenant）。AR にも `user_must_belong_to_same_organization` 追加を一考（attendance_record.rb:8-11 の宿題回収・二層化）。

### ⑦ 確定 tx は per-day savepoint + finalized は per-date ガード（§5.2 補強）
§5.2 の単一 tx N 日 `create!` は、並行 clock_in/CCR が同日 AR を作ると unique `[user_id,work_date]` 違反 → `PG::InFailedSqlTransaction` で**残り全日 rollback**（1 日の競合が確定バッチ全体を殺す）。finalized ガードも月境界跨ぎで per-date 判定が要る。
- **binding（4-2c）**: HWR の既存 idiom（`holiday_work_requests/apply_approval.rb:51-64` の `transaction(requires_new: true)` savepoint + RecordNotUnique/RecordInvalid 分別 rescue）を日次ループへ再利用（既存 AR 日は skip し結果に返す）。finalized 判定は既存 `MonthlySummaries::ClosingLock`（submitted/finalized=locked）を tx 冒頭で対象全日一括、1 日でも locked なら write 前に 422。

### ⑧ notify-once の atomicity — 本人宛 Notifier 成功後に notified_on（§4.3 補強・自己レビューで順序訂正）
Notifier 自前 tx（commit 後 broadcast）と `notified_on` 記録が別 write ゆえ順序が意味論を決める。当初 binding は「notified_on 先行（欠落側に倒す）」としたが、**`notified_on` は §10⑤ の猶予期限（翌営業日 17:00）の起算アンカー**でもあるため誤り: 先行確定後に Notifier が失敗（per-user rescue 捕捉・§10⑦）すると**通知は実在しないのに猶予時計だけが走り**、未通知のまま確定可能＝§10⑤ の弁明機会が形骸化し、notified_on 済ゆえ再試行もされない（恒久欠落）。
- **binding（4-2b）**: 順序は「**本人宛 Notifier 成功 → `notified_on = org.today` 確定**」。管理者宛は best-effort（notified_on の条件にしない — 管理者は §5.1 の候補一覧で pull 可視）。Notifier 失敗時は notified_on nil のまま次稼働日 run が自然に再試行。部分失敗（本人通知成功後・update 失敗）の再通知は稀な crash 窓のみで、猶予を**後ろへ延ばす方向**（本人保護側）にしか働かない。順序と失敗時意味論を実装コメントに明記。

### ⑨ interval_violation_count は live counter か Aggregate 派生かを 4-2d 前に決定（§6.1・YAGNI Med）
MAS は締め時に `find_or_initialize_by(year_month: AttendancePeriod.label)` で**遅延生成**。4-2d が月中 clock_in で increment すると、`AttendancePeriod.label`（closing_day 依存）を月中に正確再現しない限り別行に落ちて回数が**黙って消失/二重化**する。回数は既に `AttendanceHistory(interval_shortage)` が 1 違反=1 イベントで持つ。
- **binding（4-2d writing-plans 前に決定）**: 第一候補は late_days 同型で **Aggregate 派生集計**（`interval_shortage` 履歴を締め時に count）にし月中行生成/ラベル一致を不要化。live counter を維持するなら「4-2d は `AttendancePeriod.label` 経由・MAS 行 find_or_create・atomic SQL increment（lost-update 防止）」を DoD 化。

### ⑩ テスト追補（§7/§10⑧ に binding 追加）
- **AbsenceCandidate の二層 model 層を固定**: 越境テストを `save!(validate:false)` **無し**で `expect(c).to be_invalid` + `errors[:user]`（Notification spec 同型）。現状は validator を削除しても全緑。
- **enum 整数マッピング pin**: `AttendanceRecord.absence_reasons == {...}` / `Notification.source_types == {...}`（status/proxy_clock_reason 同様の並べ替え事故防止・DB 永続値保護）。
- **境界の有効側**: `rest_interval_hours` の `[1,24]` を valid として assert（0/25 invalid だけでは `2..23` に縮めても緑）。
- **binding 修正の判別テスト**: §10⑤ 猶予（翌営業日 16:59→422 / 17:01→成功・連休跨ぎ算出）、§10① 退勤忘れ即時発火（土曜 prev_day → 同 run で `clock_out_missing` を 1 件・稼働日ゲートを通さない）。
- **毒入力→422**: `absence_reason = "bogus"` → `be_invalid`（proxy_clock_reason 同型）。

### ⑪ 子ジョブの org 削除レース nil-guard（§4.1 補強）
`DailyAttendanceTenantJob(org_id)` は規範 `notification_dispatch_tenant_job.rb:7-8` の `org = Organization.find_by(id:); return if org.nil?` を踏襲（dispatch→実行間に org 消滅で `with_tenant(nil)`→NoTenantSet を回避）。

### corrigenda（SSOT 内部の事実誤り訂正）
- **§9 PR 分割表**: 4-2a「Notification source_type **5 値**」→ **6 値**（§3.3・計画 Task4・実装 notification.rb と一致・clock_out_missing:2〜absence_confirmed:7）。
- **§4.2 母集合 `User.active`**: 未実在（Organization は `scope :active` 有・User は無）→ 4-2b で `User.active` 新設 or `User.where(active: true)`。

### 非 binding メモ（低・任意）
- AbsenceCandidate の `idx_absence_candidates_org_user`（[org,user]）は unique 複合 [org,user,target_date] の左端プレフィックスで冗長・`references :organization` の単列 index も冗長（ephemeral 小テーブルに btree 4 本）。**既存 migration は改変せず**、気になれば 4-2b で drop migration。害小ゆえ据置可。
- 「absent は calculated スコープ外」テスト（attendance_record_spec.rb:193-197）は vacuous（absent 特異を突いていない）。

### 社労士確認事項（→ LABOR_LAW_REVIEW_NOTES.md に追記）
`investigating`（調査中）確定→即賃金控除の適正手続き（事後是正パス全滅と併せ）、欠勤候補＝カレンダー稼働日による非常勤・シフト過検出の誤確定防止。労基法 24 条 <https://laws.e-gov.go.jp/law/322AC0000000049> / 労働時間等設定改善法 2 条 <https://laws.e-gov.go.jp/law/404AC0000000090>（jp-labor-evidence は BUNDLED_INDEX_AGED 警告あり・直近改正未反映の可能性）。

## 12. 接ぎ目レビュー反映（4-2b→4-2c・2026-07-02・focused P4 gate・binding 追補）

4-2b（検知バッチ）merge 後・4-2c writing-plans 前に、**マージ済み 4-2b 実装 ↔ 未実装 4-2c 消費**の接ぎ目を 3 視点（tx atomicity・状態機械 / テナント・IDOR / 労務）で focused critique（P4 gate 条件② 発火・DEVELOPMENT_WORKFLOW「接ぎ目レビュー」）。§11 は再走せず、**4-2b の"実装済み"挙動が §11 binding と実コードで整合するか・設計時（§11）に見えなかった新規相互作用**に純化。**本節は §5 を上書きし §11 に追補する**（4-2c writing-plans は §5+§11+§12 を必須要件として扱う）。

### ①【最重要・3 視点収束】notified_on: nil の候補は確定不可（422）
候補は `AttendanceAnomalies::Detect#candidate_row` が `notified_on: nil` で生成し、`process_candidates` は「本人の今日（org.today）が稼働日」の run でしか設定しない。連休・Notifier 恒久失敗で **nil のまま §5.1 全件一覧に居座る**。§10⑤ 猶予ゲート「notified_on の翌営業日 17:00 経過後のみ確定可」は nil の扱いが未定義で、`next_business_day(nil)` を計算すると 500 or「制限なし＝無通知確定」に倒れる（労務: 弁明機会ゼロで賃金控除＝労基法 24 条抵触）。
- **binding（4-2c）**: 確定ガードは `candidate.notified_on.nil?` を**最初に判定し 422（ineligible・crash させない）**。`next_business_day(nil)` の computed に依存させない。§11⑧ が 4-2b 実コードで正実装（本人 Notifier 成功後に notified_on 設定・失敗時 nil で次 run 再試行）ゆえ「**notified_on 非 nil ⟹ 本人通知済＝弁明機会付与済**」が担保され、presence を弁明機会 proxy に使える。**`CompanyCalendarResolver` に翌営業日 API が存在しない**（実コード確認）ため 4-2c で `day_type ∉ HOLIDAY_DAY_TYPES` を走査する専用ヘルパ新設（連休吸収）。テスト: nil 候補→422 / notified_on set・翌営業日 16:59→422・17:01→成功。

### ②【High】§11① fix は「遷移前 status」を読め（silent no-op の罠）
§11① の absent→on_leave exit クリアは、`LeaveRequests::ApplyApproval#upsert_attendance_records`（apply_approval.rb:46-59）が `record.status = leave_status` を**先に代入**してから `record.absent?` を見ると常に false → `absence_reason` クリアも `absence_to_paid` 記録も**無言で no-op** → `absence_reason_only_on_absent` が依然発火し「fix したのに RecordInvalid で承認 rollback」になる。
- **binding（4-2c・§11① を精緻化）**: `find_or_initialize_by` 直後・status 代入**前**に `was_absent = record.absent?` / `previous_status = record.status` を捕捉。`was_absent` 時のみ `absence_reason=nil`（+ note・下 ⑤）をクリアしてから `save!`。回帰テストは**実 approve path**（stub 不可）で「absent(reason 有)→事後有給承認→on_leave 昇格成功 ∧ reason=nil ∧ 承認 tx 非 rollback」。

### ③【High】確定の user 解決 `policy_scope(User).find` は load-bearing（冗長でない）
§11⑥ の "500 not 404" は経路依存（`insert_all` 経路のみ 500・`create!` 経路は belongs_to presence で 422）。だが決定的事実: **same-tenant-cross-subordinate（同一テナントの他部下）は belongs_to presence も 複合 FK も model 検証も塞がず、`policy_scope(User).find(params[:user_id])` の解決済オブジェクトを渡すことだけが塞ぐ**（`AttendanceRecord` に `user_must_belong_to_same_organization` 無し・実コード確認）。
- **binding（4-2c）**: 対象社員は必ず `policy_scope(User).find`。日付は `policy_scope(AbsenceCandidate).where(user:, target_date:)` で実在候補のみ（§11⑥(2)）。IDOR 2 variant（同テナント別部下→Pundit 404 / 他テナント→acts_as_tenant 404）を負例固定。`AbsenceCandidatePolicy::Scope` は既存 MAS policy（`monthly_attendance_summary_policy.rb`）同型（hr_admin→org 全体・manager→`manager_id: me` の部下）。

### ④【High・cross-lens synthesis】確定は `create!` per-day を使え・`insert_all` 禁止
§5.2 は `AttendanceRecord.create!` per-day。これを一括 `insert_all` に最適化すると **belongs_to presence（IDOR 防御・③）+ `absence_reason_only_on_absent`（毒入力防御）の 2 model 検証を skip** し DB へ侵入させる。`create!` 維持で両検証 live。
- **binding（4-2c）**: 確定は per-day `create!`（下 ⑤ の savepoint 内）。**`insert_all`/`upsert_all` を確定 AR 生成に使わない**旨を plan 制約に明記（4-2b 候補 upsert とは別方針＝候補は検証不要 ephemeral・確定 AR は検証必須の権威データ）。

### ⑤【Med】per-day savepoint は 3 write を 1 単位に束ねよ
§11⑦ が流用を指す HWR idiom（`holiday_work_requests/apply_approval.rb:51-64`）は `create!` 1 本の savepoint。だが §5.2 の確定は 1 日あたり **AR create + `AbsenceCandidate` destroy + AttendanceHistory create の 3 write**。別 savepoint / savepoint 外だと、並行 clock_in/CCR の同日 unique 違反や history 失敗で**候補だけ destroy 済/孤児 history**という半端コミット→その日が再確定不能。
- **binding（4-2c）**: `transaction(requires_new: true)` で {AR create → 候補 destroy → history create} を 1 ブロックに束ね、`RecordNotUnique`/`RecordInvalid` はそのブロックのみ rescue し「skip 日」として結果へ。savepoint rollback で候補が intact に戻ることを assert。

### ⑥【High】absence_to_paid writer + DB backstop（§11①② を実装精緻化）
`absence_to_paid`(event_type 6) は enum 予約のみ writer 皆無（実コード確認）。`AttendanceHistory` の actor 必須検証に `absence_to_paid?`/`absence_confirmed?` の行が無い（actor 抜け監査行を許す）。
- **binding（4-2c）**: ②の `was_absent` 時に `event_type: :absence_to_paid`（`previous_status` 保持・`actor:`）を同 tx 記録。`AttendanceHistory` に `validates :actor_id, presence: true, if: :absence_to_paid?`（+ `:absence_confirmed?`）を追加（二層）。**`absence_reason` の DB CHECK（`absence_reason IS NULL OR status = <absent 整数>`・`leave_type` CHECK と対称・`/create-migration` idiom）を追加**し、§11① exit-clear を DB で強制（apply_approval が clear 忘れたら DB が拒否＝backstop・4-2c 申し送りの CHECK 対称化を格上げ）。

### ⑦【Med】4-2b 事前通知 body の虚偽 remedy も縮小（live 不整合）
§11③ は確定通知（4-2c）が対象だったが、**4-2b でマージ済みの事前通知**（`AttendanceAnomalies::Detect#notify_candidate` の body「打刻漏れの場合は打刻変更申請を提出してください」）も、候補は定義上 no-AR 日ゆえ CCR（`new_entry` 拒否・既存 AR 前提の検証）が全滅で非機能。
- **binding（4-2c 同梱で 4-2b の live コード修正）**: §11③ の確定通知縮小と同時に `detect.rb` の事前通知 body も「管理者へお問い合わせください」等へ縮小（#48 CCR new_entry 解除まで「打刻変更申請」を約束しない）。

### ⑧【Med】§11④ dismiss は 4-2c 必須（optional でない）
過検出が**個人稼働日を一切参照しない**実装を確認（anomaly service 内に UserWorkPattern/個人稼働曜日の参照ゼロ・母集合 `User.active` 全員 × 会社カレンダーのみ）。非常勤・シフト者の非所定日が無制限に候補化し、`investigating` 確定で未確定事由の即控除。§11④ 「却下(dismiss)＝候補 destroy」の耐久性は OK（pass 1 は prev_day のみ走査＝過去日を再検知しない・実コード確認）。
- **binding（4-2c）**: §11④ dismiss 経路を**必須**とし判断 E の出口を機能させる。確定 UI に「非所定日/シフト未把握」注意喚起。`manager_id: nil` の候補（トップ階層・hr_admin 自身）は hr_admin のみ確定可を確認（負例）。

### ⑨【Low】却下/撤回 LR 日は候補ゲートで absent 化不能（仕様判断）
`no_clock_anomaly` は全 status LR を「覆う」と扱う（§10 是認）。休暇が却下/取消/撤回され打刻も無い日は候補が生成/resolve され、§11② 候補ゲート確定では absent にできない（候補無→422）→ 実欠勤が欠勤トラッキングから漏れる。検知側は意図的だが 4-2c への波及は未トレース。
- **plan 判断**: 「却下/撤回された休暇日の欠勤確定」を扱うか明記。扱うなら候補ゲート迂回の管理者手動追加経路が要る（§11② と緊張）。v1 は非対象として仕様明記が妥当。
- **plan 確定（2026-07-09・4-2c-2）**: **v1 非対象**。候補ゲート（§11②「実在候補のみ確定」）を厳守し、手動追加経路は設けない。SPEC §6.10 の「制限」に明記済み。

### ⑩【Low】ClosingLock は submitted も locked（§5.2 より厳格）
既存 `MonthlySummaries::ClosingLock` の `LOCKED = %w[submitted finalized]`。§5.2「finalized 禁止・deferred 許可」は submitted の可否を無言。流用すると submitted 月の確定も 422（安全側だが仕様文言と非一致）。
- **plan 判断**: 「submitted も遮断する」意図を plan に明記（据置なら §5.2 側を補注）。
- **plan 確定（2026-07-09・4-2c-2）**: `MonthlySummaries::ClosingLock` を流用し **`submitted` も遮断**する（§5.2 の「finalized 禁止」より厳格・安全側）。SPEC §6.10 の「制限」を実装に合わせて改訂済み。

### 是認（4-2b 実コードで確認・変更不要）
§11⑧ notify-once 順序は 4-2b 実装で正（本人 Notifier 成功→notified_on・失敗時 nil で次 run 再試行＝①の proxy 前提が成立）/ 候補 resolve vs 確定の二重 destroy は benign（`absence_candidates` に `lock_version` 無し→競合は 0 行 DELETE/UPDATE で silent・per-candidate rescue 捕捉・新規 atomicity 破綻なし）/ §11① rollback 経路は実 approve path（`Approvals::Approve#call` with_lock 内 rescue 無し）で Confirmed。

### 社労士確認事項（→ LABOR_LAW_REVIEW_NOTES.md 追記・#4）
`absence_reason` の illness/family は就業規則で有給特別休暇（病気休暇・慶弔）と定められる場合があり、確定フローが**全種別を同一の unpaid absent** に落とすと乖離し得る（労基法 24 条）。illness/family を deducting absent 既定にしてよいか・確定 UI で有給振替検討の注意喚起を要するか（就業規則依存ゆえ会社差あり）。
