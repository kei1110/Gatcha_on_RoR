# Phase 3-1 MonthlyAttendanceSummary + 集計 — 設計

- 日付: 2026-06-20
- スライス: ROADMAP Phase 3-1（1 スライス = 1 ブランチ = 1 PR・`feat/phase3-1-monthly-summary`）
- 典拠: SPEC §4.13（MonthlyAttendanceSummary）・§5.2（OvertimeCalculator・週 40h 超）・§6.4（月次勤怠レポート / 提出時全件再集計）・§8.1（月 60h 超）・§8.2（36 協定 2 系統）・§8.3（管理監督者除外）・§3.6（テナント分離）。ROADMAP バックログ #108（35% 母数 = `is_holiday_work AND day_type==legal_holiday`）
- 前提エンジン: Phase 1（AttendanceRecord・計算 8 列・`Clockings::Recalculate`・calculators §5）+ 0b-3（`CompanyCalendarResolver`・`day_types`）+ 0b-4（`Organization#today` / `fiscal_year_for`）はすべて据付・merge 済（main = 2-5 完了）
- **本設計のブレスト確定事項（2026-06-20・`superpowers:brainstorming`）**: 下記 D1–D5 をユーザー承認済み

## 0. スコープと前提

Phase 1 で「日次・1 レコード単位」の計算（`Clockings::Recalculate` が AR の計算 8 列を埋める）が確立した。3-1 は**初めて「月をまたいで AR 群を横断集計する層」**を投入し、対象月の確定集計値を `MonthlyAttendanceSummary`（永久保持）へ貯める。calculator（値→値・DB なし）でも日次 service でもない、新しい**集計サービス層**である。

完了条件: ある `(user, year_month)` について、対象月の AR を窓 fetch して **AR 由来の集計列（実労働・残業 2 系統・60h 超・法定休日・深夜・遅刻早退・出勤日数）を正しく算出し、summary 行へ冪等に upsert** できる。提出トリガー・状態機械・UI は範囲外（3-2/3-3）。本スライスは **service spec で直接駆動**して検証する。

§8.2 の肝は **2 系統を別々に保存**すること: `total_overtime_hours`（legal・**法定休日労働を除く**）と `holiday_work_hours`（35%・**60h カウント外**）。45h/360h は前者だけ、80h 平均/100h は両者の合算で後段（Phase 4-3 ComplianceService）が判定できるよう、3-1 は**素材を正しく貯める**役目に徹する（判定はしない）。

### 設計判断ログ

| # | 論点 | 決定 | 根拠 |
|---|------|------|------|
| D1 | スライス境界 | **集計エンジンのみ**。Model + migration + `MonthlySummaries::Aggregate`（全件再集計・upsert 保存）+ 週 40h + 2 系統保存 + spec。状態機械(AASM)・提出 UI・締め申請制限・レポート画面・コンプラ判定は範囲外 | ROADMAP「2 系統集計の保存」に最も忠実。状態機械=3-2、CSV/レポート=3-3、判定=4-3。service spec で駆動でき UI 不要 |
| D2 | 週 40h の「週」起算 | **日曜起算・calculator 内定数固定** | 昭和 63.1.1 基発 1 号: 就業規則に定めなき場合 週=日曜〜土曜が原則。法定値でなく運用値ゆえ将来 `organization_setting` へ逃がせる(YAGNI で v1 は定数) |
| D3 | 月跨ぎ週の週次 OT 帰属 | **週末日(土曜)が属する月へ全額計上**。日次 legal_overtime は各日が属する月へ | 決定的・賃金計算期間の慣行に近い。日割り按分は正確だが配分ルール+実装が複雑(後送り)。境界週の合計が月境界でわずかにズレ得るが決定済み規則(§5 既知の限界に明記) |
| D4 | migration / 埋めるカラム範囲 | **AR 由来の集計列のみ**。`paid_leave_days_used`/`total_leave_hours`(休暇由来)・`absent_days`(absent status 不在)・コンプラフラグ・`status`/`deferral_reason` は各消費 Phase が同梱追加 | 本リポの「カラムは消費 Phase が検証・既定値ごと同梱」規約(OrganizationSetting 前例)。スライスが小さく純粋。`absent`(enum 5)は 4-2、status/AASM は 3-2 で追加 |
| D5 | 管理監督者(exempt_from_overtime) | **生値で保存**(ゼロ化しない) | §8.3「法定/所定外残業の記録: する(客観的把握義務)」。割増対象除外・36 協定除外の*判定*は下流(CSV 3-3・コンプラ 4-3)が `user.exempt_from_overtime` で分岐。summary に exempt 列は置かない(User が源) |
| D6 | 週 40h 計算の単位 | **時間(BigDecimal)で統一**(分へ再導出しない) | 入力は AR の `actual_work_hours`/`legal_overtime_hours`＝2dp 丸め済みの時間。分は AR に無く再導出は lossy。ストレージと同単位で計算し週境界の分未満 drift は許容(社労士確認候補・§2/§5) |

### 本スライスに含めない（明示的後置）

- **状態機械(AASM `status`)・提出/確定/差戻し・締め申請制限**（§6.6/§6.7/§13.4）→ **3-2**。`status`/`deferral_reason` 列も 3-2 が追加
- **月次レポート画面（ViewComponent 表示）・CSV 2 種**（§6.4）→ **3-3**
- **日次積み上げバッチ・SolidQueue recurring・全社一括**（§6.4 日次・§6.6 一括確定）→ **3-2/4-2**（本サービスは per-user。3-2 のジョブが loop する）
- **36 協定・60h・産業医面談・連続勤務・インターバルの*判定***（ComplianceService 群）→ **4-3/4-4**。3-1 は素材保存のみ
- **`paid_leave_days_used`・`total_leave_hours`**（LeaveRequest 結合要）・**`absent_days`**（absent status 不在）・**`interval_violation_count`/`consecutive_work_days_max`/`is_medical_guidance_target`/`medical_guidance_*`**（Phase 4 バッチ/コンプラが母数を持つ）→ 各消費 Phase で同梱

---

## 1. モデル / スキーマ

### 1.1 `MonthlyAttendanceSummary`（§4.13・`acts_as_tenant`）

#### マイグレーション `monthly_attendance_summaries`（`/create-migration` 規約）

| カラム | 型 | 制約 | 説明 |
|---|---|---|---|
| `organization_id` | bigint | NOT NULL | テナント（§3.6） |
| `user_id` | bigint | NOT NULL | 対象社員 |
| `year_month` | string | NOT NULL | 対象年月 `"YYYY-MM"`（例 `2026-03`） |
| `scheduled_work_days` | integer | NOT NULL default 0 | 所定出勤日数（resolver で `weekday` 判定の月内日数） |
| `work_days` | integer | NOT NULL default 0 | 実出勤日数（clock_in present の月内日数） |
| `total_work_hours` | decimal(7,2) | NOT NULL default 0 | 月合計実労働（休日労働込み） |
| `total_overtime_hours` | decimal(7,2) | NOT NULL default 0 | legal 基準・**法定休日労働を除く**（§8 冒頭・コンプラ判定基準） |
| `overtime_hours_over_60` | decimal(7,2) | NOT NULL default 0 | `max(0, total_overtime_hours − 60)`（50% 対象・法定休日含まない） |
| `holiday_work_hours` | decimal(7,2) | NOT NULL default 0 | 法定休日労働（35% 対象・60h カウント外・母数 #108） |
| `total_deep_night_hours` | decimal(7,2) | NOT NULL default 0 | 月間深夜労働（全社員・除外なし） |
| `late_days` | integer | NOT NULL default 0 | 遅刻回数（`is_late==true`） |
| `early_leave_days` | integer | NOT NULL default 0 | 早退回数（`is_early_leave==true`） |

> hour 系は `decimal(7,2)`（月合計 ≤ ~744h に十分な余裕・自己文書化）。day 系 integer。後置カラム（D4）はここに**置かない**＝消費 Phase が同梱追加。

#### インデックス & 参照整合（§3.6 二層防御）

- unique index `[organization_id, user_id, year_month]`（1 社員 1 月 1 行・upsert キー）
- composite 標的 unique index `[organization_id, id]`（複合 FK 最終防衛 idiom）
- users への複合 FK `[organization_id, user_id] → users[organization_id, id]`（自テナント強制・§3.6）

#### モデル（`app/models/monthly_attendance_summary.rb`）

- `acts_as_tenant(:organization)` / `belongs_to :user`
- **`status` / AASM は持たない**（3-2 が追加）。本スライスのモデルは集計値＋識別子のみ
- 検証:
  - `year_month` presence + `format: { with: /\A\d{4}-\d{2}\z/ }`
  - `validates_uniqueness_to_tenant :year_month, scope: :user_id`
  - 集計列 `numericality: { greater_than_or_equal_to: 0 }, allow_nil: true`（service は 0 埋めだが防御）

---

## 2. Calculator: `WeeklyOvertimeCalculator`（§5.2・値→値・DB なし）

`app/calculators/weekly_overtime_calculator.rb`。**1 週分**の純粋関数。週グルーピング・月帰属・法定休日除外は service が済ませた状態で呼ぶ（calculator は規則だけ持つ）。

```
入力: week_days = [{ actual_hours:, daily_legal_overtime_hours: }, ...]  # BigDecimal・法定休日労働日は service が除外済
規則: weekly_extra_hours = [Σactual_hours − WEEKLY_LEGAL_HOURS − Σdaily_legal_overtime_hours, 0].max
      WEEKLY_LEGAL_HOURS = BigDecimal("40")   # 労基法 32 条 1 項・法定値固定(テナント改変不可)
返り値: BigDecimal 時間（service が合算）
```

- **単位は時間(BigDecimal)で統一**（D6）。入力は AR の `actual_work_hours` / `legal_overtime_hours`＝**2dp 丸め済みの時間**そのもの。分へ再導出する経路は lossy（AR は分を保持しない）ので、ストレージと同じ時間単位で計算する。§5 の分基準 calculator 群とは入力源が異なる（あちらは生 timestamp、こちらは確定済み AR 値）。
- `Σdaily_legal_overtime_hours` を引くことで、日次 8h 超で既に数えた分を二重計上しない。週内丸ごとで `max(日次 8h 超合計, 週 40h 超)` に一致する。
- 出典: 労基法 32 条（<https://laws.e-gov.go.jp/law/322AC0000000049>・原典照合 2026-06-13）

> **実装ノート（learning）:** この `weekly_extra` の重複控除式は本スライスの中核的な業務ロジック。実装フェーズでユーザー寄稿ポイント候補（5–10 行）。

### 精度（既知の限界・§5 にも再掲）

入力の AR 時間値は **2dp 丸め済み(HALF_UP)** ゆえ、週合計を 40h と比較する際に分未満の drift があり得る。**v1 はシステム全体の HALF_UP・2dp 方針に合わせ時間基準で統一**し、この drift は許容する（社労士確認候補）。分精度要件が出た場合は AR に分を保持する設計へ後送り。

---

## 3. Service: `MonthlySummaries::Aggregate`（DB・テナント・resolver）

`app/services/monthly_summaries/aggregate.rb`。SPEC §6.4 の「MonthlySummaryService」の実体（リポの名前空間付き動詞サービス規約に合わせた名称）。

```
MonthlySummaries::Aggregate.call(user:, year_month:) → MonthlyAttendanceSummary（upsert 済）
```

### 3.1 窓 fetch（月跨ぎ週への対応）

```
month_start  = Date.parse("#{year_month}-01")
month_end    = month_start.end_of_month
month_range  = month_start..month_end
window_start = month_start.beginning_of_week(:sunday)   # 当月初日を含む週の日曜(前月に食い込み得る)
window_end   = month_end                                 # 当月末まで(末尾の翌月帰属週は除外で対応)

ActsAsTenant.with_tenant(user.organization) do
  records   = AttendanceRecord.where(user:, work_date: window_start..window_end).to_a   # 1 クエリ
  day_types = CompanyCalendarResolver.new(organization:).day_types(window_start, window_end)  # 1 クエリ
  ...
end
```

- `with_tenant` ラップ: 本サービスはリクエスト文脈前提だが、3-2 でジョブ化する際の `with_tenant` 必須（§3.6）に備え**サービス側で防御的にラップ**（`Recalculate` 同型）。
- resolver は 0b-3 既存。`day_types(from, to)` で範囲一括（N+1 回避）。

### 3.2 日次集計（`month_range` のみ）

| 集計 | 規則 |
|---|---|
| `total_work_hours` | `Σ actual_work_hours`（`calculated` 行・月内） |
| `total_deep_night_hours` | `Σ deep_night_hours`（全日・管理監督者も対象＝深夜は除外されない §8.3） |
| `holiday_work_hours` | `Σ actual_work_hours` WHERE `is_holiday_work AND day_types[date]==:legal_holiday`（#108・§8.1。所定休日土曜の出勤は含めない） |
| 日次 legal OT 寄与 | `Σ legal_overtime_hours` WHERE **NOT(法定休日労働日)**（法定休日日の 8h 超は残業でなく 35% 側へ・§8.1） |
| `work_days` | clock_in present の月内日数 |
| `scheduled_work_days` | `day_types[date]==:weekday` の月内日数（土 working 運用組織の精緻化は後送り・§5 明記） |
| `late_days` / `early_leave_days` | `is_late==true` / `is_early_leave==true` の月内日数（`calculated` 行） |

- **未計算行（計算 8 列 NULL・未割当 pattern）:** 時間合計は `calculated` スコープで除外（=0 扱い）。`work_days` は clock_in があれば計上。既存 `calculated` 規約と整合（boolean を直接 where しない・1-2 設計 R9）。

### 3.3 週次 OT（週末∈当月の週のみ）

```
window の日を日曜週でグルーピング（各週 = その週の日曜〜土曜）
for each week:
  next unless 週末日(土曜) ∈ month_range          # 末尾の翌月帰属週を除外
  days = week 内 AR から { actual_hours, daily_legal_overtime_hours }  # BigDecimal
         （day_types[date]==:legal_holiday の is_holiday_work 日は除外）
  weekly_extra += WeeklyOvertimeCalculator.call(week_days: days)
total_overtime_hours = (Σ日次 legal OT[月内・法定休日除く]) + (Σweekly_extra[週末∈当月])
overtime_hours_over_60 = [total_overtime_hours − 60, 0].max
```

- window_start を日曜にしているため、window 内の各週の土曜は必ず `>= month_start`。末尾は土曜 `> month_end` の週のみ除外され、その週の日次集計は当月分のみ計上済み（翌月の Aggregate がその週の週次 OT を拾う）。

### 3.4 保存（冪等 upsert）

```
summary = MonthlyAttendanceSummary.find_or_initialize_by(user:, year_month:)
summary.update!(集計値ハッシュ)   # 全列上書き = 再実行で同値(冪等)
summary
```

- 全件再集計ゆえ毎回フル上書き。`find_or_initialize` + `update!` で検証も通る。
- exempt 社員も**生値で**保存（D5）。

---

## 4. テスト（`/gen-spec` 雛形・TDD）

- `spec/calculators/weekly_overtime_calculator_spec.rb`
  - 40h 未満 → 0／所定 7h×6 日 = 42h・日次 OT 0 → weekly_extra 2h／日次 OT との重複控除（週実労働 50h・日次 OT 合計 6h → extra = max(0,50−40−6)=4h）／空週 → 0
- `spec/models/monthly_attendance_summary_spec.rb`
  - `year_month` 形式・presence／`validates_uniqueness_to_tenant`（同 user 同月で衝突）／テナントスコープ（他社行が見えない）／numericality
- `spec/services/monthly_summaries/aggregate_spec.rb`（中核）
  - 法定休日労働の **total_overtime 除外 ＆ holiday_work 計上**（#108）
  - **境界週の土曜月帰属**（月末が週中で切れる週は翌月へ／月初が週中の週は前月日を窓に含め週次 OT へ）
  - 60h 超／深夜合算（全日）／遅刻早退カウント
  - **冪等性**（2 回 call で同値）
  - exempt 社員の生値保存（D5）
  - NULL 計算行スキップ（時間 0・work_days は clock_in 有で計上）
  - テナント分離（他社 AR を集計に混ぜない）

---

## 5. 既知の限界・社労士確認候補（docs 明記 ＋ ROADMAP バックログ化）

1. **境界週の帰属ズレ:** 日次 OT は日ごとの月・週次 OT は土曜の月へ帰属するため、月境界週で合計がわずかにズレ得る（D3 の決定的規則）。日割り按分への精緻化はバックログ。
2. **分精度:** 週 40h は 2dp 丸め済みの時間を合算して 40h と比較（AR は分を保持しない）。週境界で分未満 drift があり得る。v1 は時間基準で統一。分精度要件が出れば後送り（§2 精度ノート）。
3. **カレンダー遡及:** day_type は集計時点の CompanyCalendar を参照。締め済み月のカレンダー改変による遡及的な day_type 書換は **3-2 のカレンダー編集制限**で封じる（既存バックログ「締め済み月の CompanyCalendar destroy 制限」と同根）。
4. **`scheduled_work_days` の所定判定:** v1 は resolver の `weekday` 判定。土曜等を所定労働日とする組織の精緻化（WorkPattern の稼働曜日連動）は後送り。
5. **35% 母数の登録漏れ連動:** legal_holiday 未登録の日曜が resolver フォールバックで `:sunday` 降格すると holiday_work_hours から漏れる。§4.7「要確認」化・既存バックログ「legal_holiday カバレッジ失効」と同根（4-1 通知基盤で接続）。

---

## 6. レビュー方針

- models / migration に触れる → `tenant-isolation-reviewer`（merge 前）
- §8 法定値（残業 2 系統・60h・週 40h・法定休日 35% 母数）に触れる → `labor-law-compliance-reviewer` + `/legal-citation-audit`（merge 前）
- 大物スライスゆえ本設計を `/multi-perspective-review` に通してから writing-plans へ
