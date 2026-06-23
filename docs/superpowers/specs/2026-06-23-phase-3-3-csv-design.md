# Phase 3-3 月次サマリ・日別明細 CSV + 休暇集計 — 設計

- 日付: 2026-06-23
- スライス: ROADMAP Phase 3-3。**2 PR に分割**（D1）:
  - **3-3a** 休暇集計の素材整備（`feat/phase3-3a-leave-aggregation`）— migration + 承認 hot path 統合 + 集計エンジン拡張
  - **3-3b** CSV 出力（`feat/phase3-3b-csv-export`）— exporter + controller/routes/policy + 最小 UI
- 典拠: SPEC §6.4（月次勤怠レポート・CSV エクスポート 2 種）・§4.13（`MonthlyAttendanceSummary` 列定義＝`paid_leave_days_used`/`total_leave_hours` の正本）・§5.5/§5.6（休暇日数・割増区分）・§6.2（休暇承認副作用・月跨ぎ per-day 分割計上）・§3.4（自分 + 部下 scope）・§3.6（テナント分離・ジョブの `with_tenant`）・§16.1（CSV はストリーミング応答）
- 前提エンジン: Phase 2-2b（`LeaveRequests::ApplyApproval`）・2-5（`LeaveRequests::Withdraw`・`Withdrawable`）・3-1（`MonthlySummaries::Aggregate`・`AttendancePeriod`・`MonthlyAttendanceSummary`）・3-2（締め状態機械・`MonthlyAttendanceSummariesController` 最小 UI・`MonthlyAttendanceSummaryPolicy`）はすべて据付・merge 済（main = 3-2 完了）
- **本設計のブレスト確定事項（2026-06-23・`superpowers:brainstorming`）**: 休暇集計の源泉＝A 案（D2）／`total_leave_hours` 換算＝所属パターン時間（D3）／CSV 粒度＝サマリ collection・明細 member（D4）／2 PR 分割（D1）をユーザー承認済み。設計全体（§1〜§7）もユーザー承認済み

## 0. スコープと前提

Phase 3-1 が `MonthlyAttendanceSummary`（永久保持）へ AR 由来の素材を冪等 upsert する `Aggregate` を、3-2 が締め状態機械を据えた。ただし **3-1 の素材は AttendanceRecord 由来のみ**（`aggregate.rb:11-12` の `WORKED_STATUSES` で `on_leave` を明示除外）で、§4.13 が定義し §6.4 月次サマリ CSV が要求する**休暇側 2 列（`paid_leave_days_used` / `total_leave_hours`）が MAS に存在しない**。3-3 はこの穴を塞ぎ、§6.4 の CSV 2 種を出して Phase 3（月次締め）を完了させる。完了条件:

> hr_admin / manager が「ある年月・scope 内全社員」の**月次サマリ CSV**（給与システム入力用・1 行=1 社員）を、本人/manager/hr_admin が「個人 1 ヶ月」の**日別明細 CSV**（1 行=1 日）を、UTF-8 BOM + CRLF + RFC 4180 でストリーミング DL でき、サマリには有給使用・総休暇時間を含む割増区分が網羅される。

### なぜ休暇集計が「どのスライスにも割り当たっていなかった」か（seam）

3-1 は「素材保存のみ」と銘打って AR 由来集計（労働/残業/深夜/遅刻早退）だけを保存し、3-3 は当初「CSV を描く」だけのスライスだった。だが §6.4 月次サマリ CSV の `有給使用`・`総休暇時間` は **AttendanceRecord に存在しない情報**（AR は `status` で休暇日と分かるが `leave_type`・paid/unpaid を持たない・`ApplyApproval` は `leave_type_id` を AR に焼かない）。ゆえに休暇集計はどちらのスライスにも属さず宙に浮いていた。本スライスがこれを 3-3a として明示的に owner にする。

### 設計判断ログ

| # | 論点 | 決定 | 根拠 |
|---|------|------|------|
| D1 | PR 分割 | **2 PR**＝3-3a（§1–§4: migration + 承認統合 + 集計）/ 3-3b（§5–§6: CSV + controller + UI） | 3-3a は承認 hot path（ApplyApproval/Withdraw）に触れ approval-engine + tenant-isolation レビューが重い。3-3b は読み取り専用の配管。観点が異なるため分割し各 PR をレビュー可能なサイズに保つ（2-2a/2-2b と同型） |
| D2 | 休暇集計の源泉 | **A 案＝AR に `leave_type_id` を持たせる**。`ApplyApproval` が休暇 AR 作成時に set、`Withdraw` が逆操作で整合。`Aggregate` は period 内の**凍結済み休暇 AR を読むだけ** | 単一ソース（AR の凍結日付）＝カレンダー再計算 drift も状態 drift も**構造的にゼロ**。pre-production ゆえ backfill は dev/test 再 seed のみで痛みが消える。**却下**: B 案（LeaveRequest 由来集計＝`counted_dates` 再計算でカレンダー変更 drift の窓・2-5 が潰した drift の再導入）／C 案（ハイブリッド＝日付→請求マップ構築が込み入る） |
| D3 | `total_leave_hours` の日→時間換算 | **所属パターン時間**＝その社員・その日の effective `WorkPattern.standard_work_hours`（半休は ÷2・`work_pattern.rb:60` の半休所定と一致）。未割当日は **0h** フォールバック（`Aggregate` の `\|\| false` 哲学と同型）+ Sentry note なし（集計は静かに 0） | 給与正確・既存 `standard_work_hours` を使う。**却下**: 固定 8h/4h（`standard_work_hours` が 8 でないパターン＝スキーマが明示サポートの組織で給与入力がずれる） |
| D4 | CSV の粒度と出力口 | **サマリ CSV = collection**（`?year_month=YYYY-MM`・`policy_scope` 内全社員を 1 行ずつ）/ **明細 CSV = member**（その社員の 1 ヶ月・1 行=1 日・AR 直） | §6.4/§16.1 の給与連携文脈（全社員分を 1 ファイルで給与へ）に最も沿う。明細は個人の監査導線 |
| D5 | 休暇集計の母数 | **period.range 内の leave-status AR を直接読む**（`status ∈ LEAVE_STATUSES`）。`counted_dates` を再計算しない | AR は in-effect 休暇の materialized truth（`ApplyApproval` が作成・`Withdraw` が逆操作）。直接読めば月跨ぎは period.range で切るだけ＝drift なし（2-5 の「counted_dates 非再計算で drift 解消」と同思想） |
| D6 | 集計の置き場 | **`MonthlySummaries::LeaveAggregator`（新 PORO）を `Aggregate` が合成**。`Aggregate` は MAS の単一 writer のまま | `Aggregate` を肥大させず休暇集計を独立テスト可能に。単一責務（小さく境界の明確な単位） |
| D7 | CSV ストリーミング | **Rack の Enumerator-body**（`ActionController::Live` のスレッドは使わない）。Ruby 標準 `CSV` で行生成 | §16.1「ストリーミング応答」を満たしつつ Live のスレッド/接続管理の複雑さを避ける。v1 規模では十分。**後置**: ジョブ非同期化 + DL リンク方式（§16.2・YAGNI） |
| D8 | AR の不変条件 | **CHECK 制約 `leave_type_id IS NULL OR status IN (2,3,4)`**（worked 行に休暇種別が紛れ込むのを DB 最終防衛）+ AR モデルに対称 validation | §3.6 の「DB 最終防衛 idiom」。アプリ層バグ（worked 行へ誤代入）を最終層で弾く |
| D9 | §4.13 残列 | **追加しない**（`absent_days` / `interval_violation_count` / `consecutive_work_days_max` / `is_medical_guidance_target` / `medical_guidance_on` / `medical_guidance_note`） | producer が Phase 4（欠勤確定 4-2・インターバル/連続勤務 4-2/4-4・産業医 4-3）かつ §6.4 CSV 列に非掲載。「消費する Phase の PR が列を同梱」原則（ROADMAP backlog #95） |
| D10 | CompanyCalendar destroy 制限 | **後送り**（本スライス対象外） | ROADMAP backlog line 88。CSV は読み取りのみで blocker でない。締め安全の loose end として Phase 4/5 で回収 |

### 本スライスに含めない（明示的後置）

- **§4.13 の Phase 4 列**（D9）→ 4-2/4-3/4-4
- **CompanyCalendar destroy の締め済み月制限**（D10・backlog line 88）→ Phase 4/5
- **CSV のジョブ非同期化 + DL リンク**（D7）→ §16.2 の本格非同期は YAGNI。v1 は同期ストリーミング
- **月次レポートのリッチ ViewComponent**（§6.4「Hotwire で表示」のサマリ + 日別明細の作り込み）→ 3-3b は既存 index/show に**最小の DL ボタン導線**のみ。表示画面の作り込みは Phase 5 ダッシュボード（§12.2）で再訪
- **通知**（§6.4 と無関係）→ 全 Phase 4-1

---

## 1. データモデル（3-3a）

### 1.1 マイグレーション

**(a) `attendance_records` に `leave_type_id` 追加（A 案の核）**

| カラム | 型 | 制約 |
|---|---|---|
| `leave_type_id` | bigint | NULL 可（worked 行は NULL） |

- 複合 FK `[organization_id, leave_type_id] → leave_types[organization_id, id]`（自己テナント強制・既存 `attendance_records → work_patterns` FK と同型＝`schema.rb:336`）。`/create-migration` 規約に沿う。
- partial index `index_attendance_records_on_org_and_leave_type`（`WHERE leave_type_id IS NOT NULL`）。
- **CHECK 制約**（D8）: `leave_type_id IS NULL OR status IN (2,3,4)`（status enum: morning_half=2/afternoon_half=3/on_leave=4）。制約名 `attendance_records_leave_type_only_on_leave_status`。

**(b) `monthly_attendance_summaries` に休暇 2 列追加（§4.13 の正本に一致）**

| カラム | 型 | 制約 |
|---|---|---|
| `paid_leave_days_used` | decimal(6,2) | NOT NULL, default 0 |
| `total_leave_hours` | decimal(7,2) | NOT NULL, default 0 |

既存テーブルへのカラム追加（複合 FK・unique index は 3-1 設置済）。新 FK なし。

**(c) backfill（冪等・dev/test 継続性）**

pre-production ゆえ本番データは無い（ROADMAP 5-3「デプロイ先決定後」）。dev/test の既存 leave-status AR を割れないまま残さないため、同一 migration 内 or 後続 data migration で:

```
既存の status ∈ (on_leave, morning_half, afternoon_half) かつ leave_type_id IS NULL の AR について、
その work_date を覆う in-effect（approval_status ∈ approved/withdrawal_requested）の LeaveRequest
（requester = AR.user・start_date ≤ work_date ≤ end_date）の leave_type_id を設定。
```

1 日 1 AR（unique `[user, work_date]`）かつ 1 日 1 in-effect 休暇ゆえ単射。覆う request が無い孤児 leave AR（理論上 dev のみ）は NULL のまま残し CHECK も満たす（集計で paid 0・hours は status から算出）。

### 1.2 `AttendanceRecord` モデル

- `belongs_to :leave_type, optional: true`。
- validation `validate :leave_type_only_on_leave_status`（CHECK と対称・`leave_type_id` 有り ⟹ `leave_status?`）。
- 既存の 8 計算列契約・`calculated` スコープ・`LEAVE_STATUSES` は不変。

---

## 2. 承認 hot path の統合（3-3a・2 点のみ）

いずれも `Approvals::Approve` の `with_lock` 内・同一 tx で呼ばれる既存サービス。**approval-engine-reviewer + tenant-isolation-reviewer 対象**。

### 2.1 `LeaveRequests::ApplyApproval#upsert_attendance_records`

per-day AR の `find_or_initialize_by(user_id, work_date)` 後、`record.status = leave_status` と並べて **`record.leave_type_id = @leave_request.leave_type_id`** を代入。§6.2 absence_to_paid（absent→on_leave 上書き）も同経路ゆえ自動でカバー。

### 2.2 `LeaveRequests::Withdraw#restore_attendance_records`

範囲内 leave-status AR の戻し 2 分岐のうち:
- `clock_in.blank?`（純休暇日）→ `record.destroy!`（**`leave_type_id` も自動消滅・追加コードなし**）。
- `else`（半休 + 打刻あり）→ `record.update!(status: ..., leave_type_id: nil)` と **`leave_type_id` のクリアを併せる**（worked へ戻る AR に休暇種別を残さない＝CHECK と整合）。

> これが A 案の唯一の追加整合点。`reject_withdrawal`（副作用なし・§13.6）は AR を触らないため対象外。

---

## 3. 集計エンジン拡張（3-3a）

### 3.1 `MonthlySummaries::LeaveAggregator`（新 PORO・D6）

```
LeaveAggregator.call(user:, period:) → { paid_leave_days_used:, total_leave_hours: }
```

- 母数（D5）: `AttendanceRecord.where(user:, work_date: period.range, status: AttendanceRecord::LEAVE_STATUSES).includes(:leave_type)`。**`.calculated` を課さない**（全休 AR は 8 計算列 NULL が正・leave 集計は計算列を読まない）。
- 日重み: `on_leave → 1.0` / `morning_half`・`afternoon_half → 0.5`。
- `paid_leave_days_used = Σ (record.leave_type&.paid_leave? ? weight : 0)`（BigDecimal）。
- `total_leave_hours = Σ hours(record)`、`hours = standard_work_hours`（半休は ÷2・未割当日は 0h・D3）。**全種別**（paid 不問）。
- パターン解決（N+1 回避）: `user.user_work_patterns.includes(:work_pattern).to_a` を 1 回ロードし、各 leave 日について effective（`active && start_date ≤ date && (end_date.nil? || end_date ≥ date)`）な assignment を in-memory で引いて `work_pattern.standard_work_hours` を読む。worked_records の `includes(:work_pattern)` と同思想。
- **テナント防御ラップ**: `Aggregate` 同型に `ActsAsTenant.with_tenant(user.organization)`（将来バッチ化に fail-closed・§3.6）。

### 3.2 `MonthlySummaries::Aggregate` の合成

`attributes` に `LeaveAggregator.call(user: @user, period: @period)` の 2 値をマージ。既存の AR 由来集計（労働/残業/深夜/遅刻早退）は不変。月跨ぎは AR 日付を period.range で切るだけ＝**counted_dates 再計算なし＝drift なし**。

---

## 4. §6.4 列マッピング（参照表）

| 月次サマリ CSV 列（§6.4） | 源泉 |
|---|---|
| 所定/実出勤日数 | `summary.scheduled_work_days` / `work_days` |
| 総労働 / 総残業 | `summary.total_work_hours` / `total_overtime_hours` |
| 60h 超 | `summary.overtime_hours_over_60` |
| 法定休日 | `summary.holiday_work_hours` |
| 深夜 | `summary.total_deep_night_hours` |
| 管理監督者フラグ | `summary.user.exempt_from_overtime`（join・preload） |
| 有給使用 | `summary.paid_leave_days_used`（**3-3a 新規**） |
| 遅刻 / 早退 | `summary.late_days` / `early_leave_days` |
| 総休暇時間 | `summary.total_leave_hours`（**3-3a 新規**） |

| 日別明細 CSV 列（§6.4・1 行=1 日） | 源泉 |
|---|---|
| 日付 | `record.work_date`（`YYYY-MM-DD`） |
| 出勤 / 退勤 | `record.clock_in` / `clock_out`（組織 TZ・`HH:MM`） |
| 実労働 / 残業 / 深夜 / 遅刻早退 | `record.actual_work_hours` / `legal_overtime_hours` / `deep_night_hours` / `late_minutes`・`early_leave_minutes` |
| status | `record.status`（i18n ラベル） |

---

## 5. CSV 出力層（3-3b）

### 5.1 exporter PORO

- `MonthlySummaries::Csv::SummaryExporter`（summary 群 → 行）/ `MonthlySummaries::Csv::DailyDetailExporter`（AR 群 → 行）。行生成を controller から分離し独立テスト可能に。
- 形式（§6.4・§16.1）: **UTF-8 BOM（先頭に `﻿`〔U+FEFF〕を 1 度だけ出力）+ CRLF（`CSV.new(row_sep: "\r\n")`）+ RFC 4180**（Ruby 標準 `CSV` の quoting に委譲）。日付 `YYYY-MM-DD`・時刻 `HH:MM`・小数ドット。
- ヘッダは i18n（`ja.yml` の専用キー群）。
- 時刻の TZ: 組織 TZ で `strftime`（既存 `Clockings.proxy_note_fragment` 同型）。

### 5.2 ストリーミング（D7）

controller で `response.headers["Content-Type"] = "text/csv; charset=utf-8"`・`Content-Disposition: attachment`、body に Enumerator を割り当て（BOM → ヘッダ行 → 各データ行を yield）。Live スレッド不使用。

---

## 6. controller / routes / policy（3-3b）

### 6.1 routes

```ruby
resources :monthly_attendance_summaries, only: %i[index show] do
  collection do
    patch :bulk_finalize   # 既存
    get   :summary_csv     # 新規（?year_month=YYYY-MM）
  end
  member do
    patch :submit; patch :finalize; patch :defer   # 既存
    get   :detail_csv      # 新規
  end
end
```

### 6.2 controller アクション

- `summary_csv`（collection）: `authorize MonthlyAttendanceSummary, :summary_csv?` → **`policy_scope` 起点**（manager=自分+部下／hr_admin=全社・§3.4・生 where 禁止 §16）→ `where(year_month: params[:year_month])`・`includes(:user)` で N+1 回避 → `SummaryExporter` をストリーミング。`year_month` は `AttendancePeriod` の YYYY-MM 検証を流用し、不正/欠落は **400**（空 CSV を返さず明示エラー）。
- `detail_csv`（member）: `set_summary`（`policy_scope.find` ＝ scope 外は 404・IDOR 対策）→ `authorize @summary, :detail_csv?` → `AttendancePeriod.new(year_month: @summary.year_month)` の `range` で `AttendanceRecord.where(user: @summary.user, work_date: period.range).order(:work_date)` → `DailyDetailExporter`。**記録の無い日は行を作らない**（1 行 = 1 実在 AR・休暇 status 行も含む）。

### 6.3 policy（`MonthlyAttendanceSummaryPolicy` 追加）

- `summary_csv? = index?`（= `user.present?`。実ゲートは `Scope` の交差）。
- `detail_csv? = show?`（= `own? || manages? || hr_admin?`・既存述語を再利用）。

### 6.4 UI（最小導線）

- `index.html.erb`: 年月セレクタ + 「月次サマリ CSV」DL ボタン（`summary_csv` へ）。
- `show.html.erb`: 「日別明細 CSV」DL ボタン（`detail_csv` へ）。

---

## 7. エッジケース / テスト

### 7.1 エッジケース

- **半休 + 打刻**: `morning_half`/`afternoon_half` は `WORKED_STATUSES`（worked 集計）と `LEAVE_STATUSES`（leave 集計）の両方に属す → 0.5 出勤日 + 0.5 休暇を両側に正しく計上（意図通り）。
- **未割当日の leave**: `total_leave_hours` 寄与 0h（`paid_leave_days_used` は leave_type で判定ゆえ日数は計上）。
- **撤回済 leave**: `withdrawn` は AR が destroy or status 復元 + `leave_type_id` クリア → 集計から自動的に非計上（D2 の drift ゼロ）。`withdrawal_requested` は AR が残るため**計上される**（撤回承認前は効力継続・正）。
- **孤児 leave AR**（backfill で覆う request 無し）: `leave_type_id` NULL → paid 0・hours は status から算出。
- **60h 超・法定休日**: 不変（worked 集計のまま）。
- **空の年月**（該当 summary/AR ゼロ）: ヘッダのみの CSV（BOM + ヘッダ行）。

### 7.2 テスト（`/gen-spec` 雛形・テナント文脈規約）

**3-3a**: migration（FK 複合・partial index・CHECK）/ AR model validation（leave_type 整合）/ `ApplyApproval`（leave_type_id set）/ `Withdraw`（destroy 分岐・半休戻し分岐で leave_type_id クリア）/ `LeaveAggregator`（paid vs unpaid・full/half・`standard_work_hours` 変動・未割当 0h・撤回非計上）/ `Aggregate` 統合。

**3-3b**: `SummaryExporter`/`DailyDetailExporter`（BOM・CRLF・RFC 4180 quoting・列順・format・i18n ヘッダ）/ request（`summary_csv` の scope 絞り＝manager は部下+自分のみ・hr_admin 全社・`detail_csv` の 404 IDOR・`year_month` 不正）/ policy。

**完了条件**: 各 PR で `bundle exec rspec`・`bundle exec rubocop --force-exclusion`、app/ 変更ゆえ `bin/brakeman --no-pager`。3-3a は `tenant-isolation-reviewer` + `approval-engine-reviewer`、`/preflight` 後 PR。

---

## 付録: ROADMAP 反映

- 3-3a / 3-3b 各 PR で ROADMAP の Phase 3-3 行を更新（チェック + PR 番号）。両 PR マージで Phase 3 完了 → `/spec-check` で §6.4 含む乖離確認。
- backlog の「Phase 3-1 の 35% 母数」「代休 LeaveBalance の繰越除外」等は本スライス範囲外（Phase 4）。CompanyCalendar destroy 制限（line 88）は D10 で後送り明記。
