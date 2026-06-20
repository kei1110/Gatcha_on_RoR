# Phase 3-1 MonthlyAttendanceSummary + 集計 — 設計

- 日付: 2026-06-20
- スライス: ROADMAP Phase 3-1（1 スライス = 1 ブランチ = 1 PR・`feat/phase3-1-monthly-summary`）
- 典拠: SPEC §4.13（MonthlyAttendanceSummary）・§5.2（OvertimeCalculator・週 40h 超）・§6.4（月次勤怠レポート / 提出時全件再集計）・§8.1（月 60h 超）・§8.2（36 協定 2 系統）・§8.3（管理監督者除外）・§3.6（テナント分離）。ROADMAP バックログ #108（35% 母数 = `is_holiday_work AND day_type==legal_holiday`）
- 前提エンジン: Phase 1（AttendanceRecord・計算 8 列・`Clockings::Recalculate`・calculators §5）+ 0b-3（`CompanyCalendarResolver`・`day_types`）+ 0b-4（`Organization#today` / `fiscal_year_for`）はすべて据付・merge 済（main = 2-5 完了）
- **本設計のブレスト確定事項（2026-06-20・`superpowers:brainstorming`）**: D1–D6 をユーザー承認済み。D7–D8 は `/multi-perspective-review`（6 視点）、**D9–D10 は集計業務の全体フロー熟慮**で追加（いずれもユーザー承認済み）

## 0. スコープと前提

Phase 1 で「日次・1 レコード単位」の計算（`Clockings::Recalculate` が AR の計算 8 列を埋める）が確立した。3-1 は**初めて「月をまたいで AR 群を横断集計する層」**を投入し、対象月の確定集計値を `MonthlyAttendanceSummary`（永久保持）へ貯める。calculator（値→値・DB なし）でも日次 service でもない、新しい**集計サービス層**である。

完了条件: ある `(user, year_month)` について、`AttendancePeriod`（締め期間・`closing_day` 基準）の AR を窓 fetch して **AR 由来の集計列（実労働・残業 2 系統・60h 超・法定休日・深夜・遅刻早退・出勤日数）を正しく算出し、summary 行へ冪等に upsert** できる。提出トリガー・状態機械・UI は範囲外（3-2/3-3）。本スライスは **service spec で直接駆動**して検証する。

> **集計の期間は暦月でなく「締め期間」**（D9）。`closing_day` は 0b-5 で出荷済・admin 編集可ゆえ、暦月固定は賃金計算期間とズレる。`AttendancePeriod` を背骨に、3-1/3-2/3-3/4-x が単一の期間定義を共有する。

§8.2 の肝は **2 系統を別々に保存**すること: `total_overtime_hours`（legal・**法定休日労働を除く**）と `holiday_work_hours`（35%・**60h カウント外**）。45h/360h は前者だけ、80h 平均/100h は両者の合算で後段（Phase 4-3 ComplianceService）が判定できるよう、3-1 は**素材を正しく貯める**役目に徹する（判定はしない）。

### 設計判断ログ

| # | 論点 | 決定 | 根拠 |
|---|------|------|------|
| D1 | スライス境界 | **集計エンジンのみ**。Model + migration + `MonthlySummaries::Aggregate`（全件再集計・upsert 保存）+ 週 40h + 2 系統保存 + spec。状態機械(AASM)・提出 UI・締め申請制限・レポート画面・コンプラ判定は範囲外 | ROADMAP「2 系統集計の保存」に最も忠実。状態機械=3-2、CSV/レポート=3-3、判定=4-3。service spec で駆動でき UI 不要 |
| D2 | 週 40h の「週」起算 | **日曜起算・calculator 内定数固定** | 昭和 63.1.1 基発 1 号原文「一週間とは…日曜日から土曜日までのいわゆる暦週」（labor-law レビューが原典 MCP で照合）。法定値でなく運用値ゆえ起算曜日の設定化余地はあるが **v1 は定数固定（設定化は消費者が現れてから・YAGNI）** |
| D3 | 期跨ぎ週の週次 OT 帰属 | **週末日(土曜)が属する締め期間へ全額計上**。日次 legal_overtime は各日が属する締め期間へ（境界は D9 で暦月→締め期間に一般化） | 決定的・賃金計算期間の慣行に近い。日割り按分は正確だが配分ルール+実装が複雑(後送り)。境界週の合計が期境界でわずかにズレ得るが決定済み規則(§5 既知の限界に明記・賃金期ズレは社労士確認 案②) |
| D4 | migration / 埋めるカラム範囲 | **AR 由来の集計列のみ**。`paid_leave_days_used`/`total_leave_hours`(休暇由来)・`absent_days`(absent status 不在)・コンプラフラグ・`status`/`deferral_reason` は各消費 Phase が同梱追加 | 本リポの「カラムは消費 Phase が検証・既定値ごと同梱」規約(OrganizationSetting 前例)。スライスが小さく純粋。`absent`(enum 5)は 4-2、status/AASM は 3-2 で追加。`scheduled_work_days` は **3-3 の月次サマリ CSV「所定/実出勤日数」が直接消費**ゆえ work_days と対で今入れる |
| D5 | 管理監督者(exempt_from_overtime) | **生値で保存**(ゼロ化しない) | §8.3「法定/所定外残業の記録: する(客観的把握義務)」。割増対象除外・36 協定除外の*判定*は下流(CSV 3-3・コンプラ 4-3)が `user.exempt_from_overtime` で分岐。summary に exempt 列は置かない(User が源) |
| D6 | 週 40h 計算の単位 | **時間(BigDecimal)で統一**(分へ再導出しない) | 入力は AR の `actual_work_hours`/`legal_overtime_hours`＝2dp 丸め済みの時間。分は AR に無く再導出は lossy。ストレージと同単位で計算し週境界の分未満 drift は許容(社労士確認 案③・§2/§5)。**§2.2-1 の「分単位中間計算」規約からの明示的逸脱**＝calculator に理由コメントを残し `MinuteConversion` を使わない(将来「分へ揃える」手戻り防止) |
| D7 | フレックス(flextime)社員の週 40h | **v1 は週 40h 計算から除外**(flextime 日は週次 OT の母数に入れない)。日次値は Phase 1 の既存挙動を踏襲 | 昭和 63.1.1 基発 1 号「フレックスタイム制…時間外労働となるのは清算期間における法定労働時間の総枠を超えた時間」＝週 40h 単位と母数が異なる。SPEC §5.2「変形は v2(清算期間判定)」と同じ線引きへ flextime も寄せる。一律適用は**過大/過少計上の労務リスク**（labor-law Warning・社労士確認 案①）。flextime の清算期間 OT 適正化は v2 |
| D8 | 週次ロジックの置き場所 | **週グルーピング+期間帰属+法定休日/flextime 除外+重複控除式を `WeeklyOvertimeCalculator`(値→値・純粋) へ集約**。service は AR→値の変換と日次集計・upsert に徹する | 最も間違えやすい日付分配を **DB 非依存で単体テスト可能**にする(test 視点 High・pragma 視点 High)。§2.2-1「計算は PORO・値→値」に最も忠実。service の private に埋もれると境界 off-by-one が追えない |
| D9 | 集計の**期間粒度** | **締め期間（`closing_day` 基準）を `AttendancePeriod` 値オブジェクトで一級化**。`range`/`week_window`/`prev`/`next`/`fiscal_year`/`label` を集約し、3-1/3-2/3-3/4-x が**単一の期間定義**を共有 | 暦月ハードコードは `closing_day≠31`（0b-5 出荷済・admin 編集可）で締め・給与の賃金計算期間とズレる silent bug。週・日次・締め・CSV・コンプラが食い違わない**背骨**。F2 カスケード=`period.next`・F4 単一エンジン・④ 組織レベル解決の一度化を構造で吸収（全体フロー熟慮で確定） |
| D10 | AR 由来集計の**母数 status** | **出勤系 status（`working`/`clocked_out`/`morning_half`/`afternoon_half`）でゲート**。`on_leave` 行（バックログ #104 の stale 非NULL 含む）は 3-1 の集計列に一切寄与しない | 打刻済日への全休承認で計算列が stale 残留（#104）→ `work_days`/`total_work_hours` の過大計上を構造的に弾く。休暇由来の値は後置列（D4）の領分（全体フロー F3） |

### 本スライスに含めない（明示的後置）

- **状態機械(AASM `status`)・提出/確定/差戻し・締め申請制限**（§6.6/§6.7/§13.4）→ **3-2**。`status`/`deferral_reason` 列も 3-2 が追加
- **月次レポート画面（ViewComponent 表示）・CSV 2 種**（§6.4）→ **3-3**
- **日次積み上げバッチ・SolidQueue recurring・全社一括**（§6.4 日次・§6.6 一括確定）→ **3-2/4-2**（本サービスは per-user。3-2 のジョブが loop する）
- **36 協定・60h・産業医面談・連続勤務・インターバルの*判定***（ComplianceService 群）→ **4-3/4-4**。3-1 は素材保存のみ
- **`paid_leave_days_used`・`total_leave_hours`**（LeaveRequest 結合要）・**`absent_days`**（absent status 不在）・**`interval_violation_count`/`consecutive_work_days_max`/`is_medical_guidance_target`/`medical_guidance_*`**（Phase 4 バッチ/コンプラが母数を持つ）→ 各消費 Phase で同梱
- **休暇集計（`paid_leave_days_used`/`total_leave_hours`）の扱い（F5・全体フロー）:** §6.4 の月次サマリ CSV は「有給使用・総休暇時間」を要求するが、これらは LeaveRequest 結合ゆえ D4 で後置。**3-3（CSV）が休暇集計列を同梱追加して埋める**（3-3 は整形＋休暇集計の二役）。3-1 は AR 由来の純粋エンジンに保つ（休暇は LeaveBalance ドメイン寄り）。3-3 着手時にこの責務拡大を再確認。
- **`fiscal_year` 列:** `AttendancePeriod#fiscal_year`（= `organization.fiscal_year_for(period.range.last)`）で一意に導出可能だが、**36 協定の年度集計を行う 4-3 が消費**ゆえ列追加は 4-3（D4）。3-1 は period 経由で導出可能にするのみ（列は持たない）。

---

## 1. モデル / 期間オブジェクト / スキーマ

### 1.1 `MonthlyAttendanceSummary`（§4.13・`acts_as_tenant`）

#### マイグレーション `monthly_attendance_summaries`（`/create-migration` 規約）

| カラム | 型 | 制約 | 説明 |
|---|---|---|---|
| `organization_id` | bigint | NOT NULL | テナント（§3.6） |
| `user_id` | bigint | NOT NULL | 対象社員 |
| `year_month` | string | NOT NULL | 締め期間ラベル `"YYYY-MM"`＝締め日が属する暦月（例 `2026-03`・`AttendancePeriod#label`） |
| `scheduled_work_days` | integer | NOT NULL default 0 | 所定出勤日数（resolver で `weekday` 判定の締め期間内日数） |
| `work_days` | integer | NOT NULL default 0 | 実出勤日数（clock_in present の締め期間内日数） |
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
  - `validates_uniqueness_to_tenant :year_month, scope: :user_id` — **UX 用の二次防衛**。並行 upsert は TOCTOU で勝てず、一次防衛は DB unique index `[organization_id, user_id, year_month]`（3-2 ジョブ化時に `RecordNotUnique` rescue / 冪等再試行を補う・§5 限界 6）
  - 集計列 `numericality: { greater_than_or_equal_to: 0 }`（NOT NULL + default 0 ゆえ `allow_nil` は不要＝付けない）
  - **`validate :user_must_belong_to_same_organization`（Critical・テナント分離レビュー）** — 本リポの全 user 帰属モデル（`LeaveBalance`/`AttendanceHistory`/`LeaveRequest`/`ClockChangeRequest`/`HolidayWorkRequest`）が例外なく持つ ID 基点 fail-closed 検証。`find_or_initialize_by(user:, year_month:)` で `organization_id`(tenant 由来) と `user_id`(引数由来) が**別経路で決まる**ため、両者の不一致を model 層で能動検証する。実装は `LeaveBalance#user_must_belong_to_same_organization`（`app/models/leave_balance.rb:27`）と同型（`return if user_id.nil?` / `return if user&.organization_id == organization_id` / 不一致で `errors.add`）

### 1.2 `AttendancePeriod`（締め期間・値オブジェクト・集計の背骨・D9）

`app/models/attendance_period.rb`。AR ではない**不変の値オブジェクト**。`(organization, year_month)` を与えると締め期間の全属性を導出する。3-1/3-2/3-3/4-x が**この一個の定義を共有**し、期間境界の場当たり再導出（drift 源）を排する。

```
AttendancePeriod.new(organization:, year_month:)   # year_month = 締め日が属する暦月のラベル "YYYY-MM"
  closing_day = organization.setting.closing_day    # 1..31（31 = 月末扱い・0b-5 出荷済）

  range        # 締め期間 [start, last]（Date の Range）
               #   period_end   = Date.new(y, m, [closing_day, ラベル月の末日].min)   # 31→月末・25→25日
               #   period_start = (前ラベル月の period_end) + 1 日
               #   例 closing_day=31: 2026-03 → 3/1..3/31（暦月）
               #      closing_day=25: 2026-03 → 2/26..3/25
  week_window  # 週次 OT 用 fetch 窓 = range.first.beginning_of_week(:sunday) .. range.last
  prev / next  # 前後の AttendancePeriod（ラベル月の prev_month/next_month）
               #   F2: 当期の tail を編集 → next の週次 OT が変わる（締め差戻しの再集計カスケード単位）
  fiscal_year  # organization.fiscal_year_for(range.last)（締め日基準で一意・暦月跨ぎの曖昧さを排除）
  label        # "YYYY-MM"（= year_month）
```

- **closing_day=31 を月末として一様化:** `[closing_day, ラベル月の末日].min` で 31→各月末・30→Feb は 28/29 にクランプ・25→25 日。`period_start` が前ラベル月の `period_end + 1` ゆえ、31 のとき暦月に一致する（特別分岐不要）。
- **週は暦週のまま（日〜土）・期間は選択/帰属のみ:** 法定の週（労基法 32 条・日曜起算）は `closing_day` で歪めない。`AttendancePeriod` は「どの週の OT が当期に落ちるか（週末土曜 ∈ range）」「どの日が当期か（日 ∈ range）」を決めるだけ。calculator は純粋な暦週ロジックを保つ。
- **依存:** `organization.setting`（`Organization#setting` アクセサ経由・未生成は既定値 lazy 生成）。テナント安全は `setting` が自前で担保。値オブジェクトゆえ DB 書き込みなし。
- 検証は `MonthlyAttendanceSummary` 側（`year_month` format）。`AttendancePeriod` は不正 `year_month` を `Date.parse` 失敗で早期に弾く（spec で固定）。

---

## 2. Calculator: `WeeklyOvertimeCalculator`（§5.2・値→値・DB なし・D8）

`app/calculators/weekly_overtime_calculator.rb`。**当該締め期間に帰属する週次法定時間外の合計**を返す純粋関数。週グルーピング・期間帰属・法定休日/flextime 除外・重複控除を**すべて値→値で**内包し、service は AR→値の写像だけ担う（§2.2-1「計算は PORO」に最も忠実・最も間違えやすい日付分配を DB 非依存で単体テスト可能にする）。

```
入力:
  period_range : Range<Date>   # 締め期間 = AttendancePeriod#range（土曜の帰属判定に使う）
  days         : [{ date:, actual_hours:, daily_legal_overtime_hours:,
                    legal_holiday_work: bool, flextime: bool }, ...]
                 # 窓 = AttendancePeriod#week_window 全日・BigDecimal

規則:
  WEEKLY_LEGAL_HOURS = BigDecimal("40")   # 労基法 32 条 1 項・法定値固定(テナント改変不可)
  日曜起算で週グルーピング（Date#beginning_of_week(:sunday)）
  各週について:
    next unless 週末日(その週の土曜) ∈ period_range         # 翌期帰属週/前期帰属週を除外
    countable = 週内日のうち !legal_holiday_work && !flextime  # 35%側と清算期間側を母数から外す(D7)
    extra = [ Σcountable.actual_hours − WEEKLY_LEGAL_HOURS − Σcountable.daily_legal_overtime_hours, 0 ].max
  返り値 = Σ extra（当期帰属週の合計・BigDecimal）
```

- **重複控除:** `Σdaily_legal_overtime_hours` を引くことで日次 8h 超で既に数えた分を二重計上しない。週内丸ごとで `max(日次 8h 超合計, 週 40h 超)` に一致（labor-law レビューが労基法 32 条 1 項/2 項・基発 1 号で適合確認）。
- **法定休日労働日の除外:** 35% 側（`holiday_work_hours`）へ回る日は週 40h の母数に入れない（§8.1）。
- **flextime 日の除外（D7）:** 清算期間ベースゆえ週 40h 単位と母数が異なる（基発 1 号）。v1 は週次計算から外す。
- **単位は時間(BigDecimal)で統一（D6）:** 入力は AR の確定済み 2dp 値。`MinuteConversion`（分単位規約・§2.2-1）は**使わない**＝本 calculator は分単位中間計算規約からの明示的逸脱。クラス冒頭コメントに理由（入力が分を保持しない確定 AR 値）を残し、将来「分へ揃える」手戻りを防ぐ。
- 出典: 労基法 32 条（<https://laws.e-gov.go.jp/law/322AC0000000049>）・昭和 63.1.1 基発 1 号（<https://www.mhlw.go.jp/web/t_doc?dataId=00tb1899&dataType=1&pageNo=1>）・原典照合 2026-06-20。

> **実装ノート（learning）:** 重複控除＋母数除外＋月帰属の組み立てが本スライスの中核業務ロジック。実装フェーズでユーザー寄稿ポイント候補（5–10 行）。

### 精度（既知の限界・§5 にも再掲）

入力の AR 時間値は **2dp 丸め済み(HALF_UP)** ゆえ、週合計を 40h と比較する際に分未満の drift があり得る。**v1 はシステム全体の HALF_UP・2dp 方針に合わせ時間基準で統一**し、この drift は許容する（社労士確認 案③）。分精度要件が出た場合は AR に分を保持する設計へ後送り。

---

## 3. Service: `MonthlySummaries::Aggregate`（DB・テナント・resolver）

`app/services/monthly_summaries/aggregate.rb`。SPEC §6.4 の「MonthlySummaryService」の実体（リポの名前空間付き動詞サービス規約に合わせた名称）。`self.call(...) = new(...).call`（`Recalculate` 同型の委譲）。

```
MonthlySummaries::Aggregate.call(user:, period:, day_types: nil) → MonthlyAttendanceSummary（upsert 済）
  period    : AttendancePeriod（呼び出し元が構築。3-2 一括では tenant×period で 1 度だけ作り全社員へ使い回す）
  day_types : Hash<Date,Symbol>（省略可）。nil なら service が period.week_window を resolver で解決。
              3-2 一括は tenant×period で 1 度解決して注入（④ 組織レベル解決の一度化）
```

> **単一エンジン（F4・全体フロー）:** 本サービスは per-user・冪等・全件再集計ゆえ、4-2 の日次バッチも**同サービスを毎晩呼ぶ**＝「概算」が「現データの正確なスナップショット」になり、積み上げ加算という別アルゴリズム（drift 源）を作らない。§6.4 の「前日積み上げ」文言は 4-2 着手時に再訪（4-2 ハンドオフ）。

**メソッド骨子（`call` は組み立てに徹する・pragma 視点 High）:**

```
call
  → with_tenant(user.organization) { persist(daily_attributes.merge(overtime_attributes)) }
private:
  worked_records   # 窓 fetch を出勤系 status でゲート（D10）：status ∈ {working,clocked_out,morning_half,afternoon_half}
  resolved_day_types  # 引数 day_types || resolver.day_types(period.week_window 両端)
  daily_attributes # period.range 内日のみ：work_days / scheduled_work_days / total_work_hours / total_deep_night_hours / holiday_work_hours / late_days / early_leave_days / 日次 legal OT 寄与
  overtime_attributes # total_overtime_hours(= 日次寄与 + 週次) / overtime_hours_over_60
  weekly_overtime_hours  # days 配列を組み WeeklyOvertimeCalculator.call(period_range: period.range, days:)
  persist(attrs)   # find_or_initialize_by(user:, year_month: period.label) + update!
```

### 3.1 窓 fetch（締め期間・期跨ぎ週への対応）

```
window = period.week_window      # = period.range.first.beginning_of_week(:sunday) .. period.range.last

ActsAsTenant.with_tenant(user.organization) do
  worked_records = AttendanceRecord
    .where(user:, work_date: window, status: %i[working clocked_out morning_half afternoon_half])  # D10
    .includes(:work_pattern)                                                                       # flextime 判定の N+1 回避
    .to_a                                                                                          # 1 クエリ
  day_types = day_types ||                                                                         # 注入優先（④）
    CompanyCalendarResolver.new(organization: user.organization).day_types(window.first, window.last)  # 1 クエリ
  ...
end
```

- **出勤系 status ゲート（D10・F3）:** `on_leave` 行（バックログ #104 で計算列が stale 非NULL になり得る）を窓 fetch 段階で除外。3-1 の集計列は「実際に働いた行」だけを母数にする。休暇由来の値は後置列（D4）の領分。
- **`with_tenant(user.organization)` ラップ — 現スライスで必要:** 完了条件が「service spec で直接駆動」＝`ActsAsTenant.current_tenant` 未設定の素文脈から呼ばれ得る。ラップが無いと窓 fetch が `NoTenantSet` で落ちる。`Recalculate` 同型。3-2 ジョブ化時も同じラップがそのまま効く。
- **resolver の `organization:` は `user.organization`**（with_tenant に渡した同一インスタンス）を明示し `current_tenant` 暗黙依存への退行を防ぐ（`holiday_work_requests/apply_approval.rb` 前例）。`day_types` は注入されなければ範囲一括で解決（N+1 回避）。
- 呼び出し元（3-2 ジョブ）は per-user で正しいテナントの user・同一 period を渡す責務を負う（ディスパッチャが `Organization` 列挙 → tenant×period の `day_types` を 1 度解決 → 子ジョブが per-user 呼び出し・§3.6・④）。

### 3.2 日次集計（`period.range` 内日のみ・出勤系 status の `worked_records`）

| 集計 | 規則 |
|---|---|
| `total_work_hours` | `Σ actual_work_hours`（`calculated` 行・`period.range` 内） |
| `total_deep_night_hours` | `Σ deep_night_hours`（全 worked 行・管理監督者も対象＝深夜は除外されない §8.3） |
| `holiday_work_hours` | `Σ actual_work_hours` WHERE `is_holiday_work AND day_types[date]==:legal_holiday`（#108・§8.1。所定休日土曜の出勤は含めない） |
| 日次 legal OT 寄与 | `Σ legal_overtime_hours` WHERE **NOT(法定休日労働日)**（法定休日日の 8h 超は残業でなく 35% 側へ・§8.1） |
| `work_days` | clock_in present の `period.range` 内日数（`worked_records` ゆえ on_leave は既に除外済） |
| `scheduled_work_days` | `day_types[date]==:weekday` の `period.range` 内日数（土 working 運用組織の精緻化は後送り・§5 明記） |
| `late_days` / `early_leave_days` | `is_late==true` / `is_early_leave==true` の `period.range` 内日数（`calculated` 行） |

- **未計算行（計算 8 列 NULL・未割当 pattern）:** 時間合計は `calculated` スコープで除外（=0 扱い）。`work_days` は clock_in があれば計上。既存 `calculated` 規約と整合（boolean を直接 where しない・1-2 設計 R9）。
- **`scheduled_work_days` のみ AR 非依存:** 暦（`day_types`）由来ゆえ `worked_records` でなく `period.range` の全日を resolver で数える（出勤実態と独立）。

### 3.3 週次 OT（service は値写像のみ・分配は calculator）

service は窓内の `worked_records` を **calculator が食える値配列**へ写すだけ。週グルーピング・期間帰属（週末∈`period.range`）・法定休日/flextime 除外・重複控除は `WeeklyOvertimeCalculator` が内包（D8）。

```
days = worked_records.map { |r|
  { date:                       r.work_date,
    actual_hours:               r.actual_work_hours      || 0,   # 未計算(working 等)は 0
    daily_legal_overtime_hours: r.legal_overtime_hours   || 0,
    legal_holiday_work:         r.is_holiday_work && day_types[r.work_date] == :legal_holiday,
    flextime:                   r.work_pattern&.flextime? || false }   # D7・未割当は false
}
weekly = WeeklyOvertimeCalculator.call(period_range: period.range, days:)

total_overtime_hours   = daily_legal_overtime_contribution + weekly  # 日次寄与は §3.2(period.range 内・法定休日除く)
overtime_hours_over_60 = [total_overtime_hours − 60, 0].max
```

- **二重の帰属軸（保守者の直感に反するため要コメント・pragma 視点 Med）:** 日次 legal OT 寄与は**各日が属する締め期間**（§3.2・`period.range` 内のみ）、週次 extra は**週末土曜が属する締め期間**（calculator）。windowing と calculator 呼び出しの両所に「日次=各日の期間／週次=土曜の期間」を 1 行注記する。
- 窓は `period.week_window`。`worked_records` は §3.1 で `includes(:work_pattern)` 済（flextime 判定の N+1 回避）。

### 3.4 保存（冪等 upsert）

```
summary = MonthlyAttendanceSummary.find_or_initialize_by(user:, year_month: period.label)
summary.update!(集計値ハッシュ)   # 全列上書き = 再実行で同値(冪等)
summary
```

- 全件再集計ゆえ毎回フル上書き。`find_or_initialize` + `update!` で検証も通る。
- exempt 社員も**生値で**保存（D5）。
- これは DB の `upsert`(ON CONFLICT) ではなく read-modify-write。v1 は per-user・service spec 直接駆動で**並行前提なし**ゆえ妥当。3-2 でジョブ loop 化する際に並行 upsert の `RecordNotUnique` rescue / 冪等再試行を補う（§5 限界 6・今 `with_lock` を入れるのは YAGNI で不要）。
- **無条件上書き契約（F1・全体フロー）:** 本サービスは status を見ず**毎回フル上書き**する純関数 `(user, period, AR, calendar) → summary 値`。3-1 に status 列は無く実害はないが、3-2 で status 列が入った後は **`submitted`/`finalized` 月を黙って上書きしない**ことが**呼び出し側の責務**になる（3-2 の submit=意図的再集計・4-2 の夜間バッチは `aggregating` 月のみ対象）。再集計（派生値）と状態遷移（権威）を分離する契約として 3-2/4-2 ハンドオフへ明記。

---

## 4. テスト（`/gen-spec` 雛形・TDD）

既存 calculator spec の作法（**3 点境界 n−1/n/n+1 ＋ 負例 ＋ クランプ判別値**）に揃える（test 網羅視点 High）。

### 4.1 `spec/calculators/weekly_overtime_calculator_spec.rb`（DB 非依存・分配ロジックの本丸）

D8 で週次ロジックを calculator へ集約したため、**境界 off-by-one はここで値テスト**できる（DB fixture 不要）。
- **40h 境界 3 点:** 週 39.99 / 40.00 / 40.01h（日次 OT 0）→ extra 0 / 0 / 0.01
- **7h×6 日 = 42h・日次 OT 0** → extra 2.00
- **重複控除:** 週 50h・日次 OT 合計 6h → extra max(0, 50−40−6)=4.00
- **負クランプ:** 日次 OT 過大（週 50h・日次 OT 15h）→ max(0, 50−40−15)=0
- **空配列 `days: []`** → 0（nil/ゼロ除算なし）
- **期間帰属:** 週末土曜が `period_range` 内の週のみ計上／土曜が翌期 or 前期の週は **0 寄与**（同一 days で period_range だけ変えて確認）
- **法定休日労働日の除外:** `legal_holiday_work: true` の日は actual/日次 OT 両方の母数から外れる
- **flextime 除外（D7）:** `flextime: true` の日は週 40h 母数から外れる（混在週で fixed 日のみ集計）

### 4.2 `spec/models/attendance_period_spec.rb`（締め期間の境界・closing_day 依存の本丸）

- **closing_day=31（月末）:** `"2026-03"` → range 3/1..3/31（暦月に一致）／`"2026-02"` → 2/1..2/28（うるう非年）／`"2024-02"` → 2/1..2/29
- **closing_day=25:** `"2026-03"` → range 2/26..3/25／`prev` の range 末日 +1 が start（連続性）
- **closing_day=30 が Feb をまたぐクランプ:** `"2026-03"`(d=30) period_start = Feb の period_end(2/28 にクランプ)+1 = 3/1／`"2026-02"`(d=30) period_end = 2/28
- **week_window:** range.first の直前日曜 .. range.last
- **prev/next 連続性:** `period.prev.range.last + 1 == period.range.first`・`period.range.last + 1 == period.next.range.first`（隙間/重複なし＝全日が一意に 1 期間へ）
- **fiscal_year:** `organization.fiscal_year_for(range.last)`（締め期間が年度境界をまたぐケースで末日基準の一意性）
- **不正 year_month:** `"2026-13"` 等は `Date.parse` 失敗で弾く

### 4.3 `spec/models/monthly_attendance_summary_spec.rb`

- `year_month` format **負例**: `"2026-13"` / `"2026-3"` / `"2026-00"` / `"202603"` が invalid・`"2026-03"` valid
- presence／`validates_uniqueness_to_tenant`（同 user 同月で衝突・他社の同 user_id 同月は衝突しない）
- **同一組織検証（Critical）:** 他組織 user を代入で invalid（`user_must_belong_to_same_organization`）
- テナントスコープ（他社行が `default_scope` で見えない）／numericality（負値 invalid）

### 4.4 `spec/services/monthly_summaries/aggregate_spec.rb`（中核・負例を意図として固定）

**締め期間（closing_day≠31 を必ず 1 本）:**
- `closing_day=25` の組織で `"2026-03"` を集計 → 2/26..3/25 の AR のみ計上・3/26 以降と 2/25 以前は当期に**入らない**（暦月ハードコードなら落ちる回帰テスト）

**2 系統分離（本スライスの存在意義）:**
- 法定休日 10h 勤務（2h 超）→ その日が **日次 OT 寄与に入らない ＆ weekly 母数からも除外**・`holiday_work_hours` に 10h・`total_overtime_hours` に寄与 0（2 経路の除外を別 example で）
- holiday_work **負例 3 種**: ① `is_holiday_work` だが day_type が `:sunday` フォールバック（#108 母数漏れ・限界 5 の回帰）② day_type `:legal_holiday` だが `is_holiday_work=false` ③ 所定休日土曜(`:saturday`)出勤 — いずれも `holiday_work_hours` 0
- `total_work_hours == holiday_work_hours > 0` かつ `total_overtime_hours == 0`（法定休日のみ勤務期・2 系統独立の文書化テスト）

**期跨ぎ境界（前期日が weekly 控除項にだけ効き加算されない不変条件）:**
- 期初=日曜（window_start==period.range.first・前期食い込み 0）
- 期末=土曜（末尾週が当期で閉じ**除外されない**）／期末≠土曜（末尾週が翌期へ・その分 `total_overtime` から抜ける）
- 期初週に前期の 8h 超勤務日 → 前期日次 OT は当期 `total_overtime` に**加算されない**が weekly 控除には効く（D3 の核）
- **暦年跨ぎ:** `"2026-01"` で window が 2025-12 へ食い込む（closing_day=31）／年度(3→4 月)跨ぎ期初週

**#104 stale 行の除外（D10・F3）:** 打刻済(`clocked_out`・計算列 non-NULL)の日に全休承認で `status=on_leave` に上書き＋計算列 stale 残留 → 集計は `worked_records` ゲートで**この行を除外**し `work_days`/`total_work_hours` に乗らない（過大計上を弾く負例）

**60h 境界 3 点:** `total_overtime` 59.99 / 60.00 / 60.01 → over_60 0 / 0 / 0.01

**管理監督者(exempt)×深夜（同一 example でゼロ化バグを殺す）:** exempt 社員が深夜+8h 超 → `total_deep_night_hours > 0` かつ `total_overtime_hours > 0`（生値・D5）

**未計算/未割当:** 計算 8 列 NULL 行（`working`）→ `total_work_hours` 不変(0 寄与)・`work_days` は clock_in 有で +1・`scheduled_work_days` は weekday なら +1・`late/early` 0。flextime 未割当(pattern nil)は flextime=false 扱い

**work_days vs scheduled_work_days 乖離:** 法定休日出勤のみ期 → work_days 1 / scheduled 0／平日全欠勤 → scheduled>0 / work_days 0

**夜勤 work_date:** 期末日 work_date の夜勤 AR（深夜が翌日跨ぎ）が当期 deep_night に計上され翌期に漏れない

**day_types 注入（④）:** `day_types:` を渡した呼び出しが resolver を**叩かない**（注入優先の確認・3-2 一括の共有経路）

**冪等性（同値でなく行数不変＋追従性）:** 2 回 call で `count` 不変 ＆ `summary.id` 不変／AR を 1 件足して再 call → 値が追従（古い値が残らない＝フル上書きの証明）

**テナント分離 負例:** 他社 org+他社 user に同期間 AR 大量投入 → 当社 summary は当社分のみ／`current_tenant=nil` の素文脈から直接 call 成功（防御ラップ回帰）

---

## 5. 既知の限界・社労士確認候補（docs 明記 ＋ ROADMAP バックログ化）

1. **境界週の帰属ズレ:** 日次 OT は日ごとの締め期間・週次 OT は土曜の締め期間へ帰属するため、期境界週で合計がわずかにズレ得る（D3 の決定的規則）。日割り按分への精緻化はバックログ・賃金期帰属は社労士確認 案②。
2. **境界週の前方カップリング（F2・全体フロー）:** 締め期間 P のサマリは **P.prev の tail 日**（P の初週に食い込む前期日）を週次 OT の母数に読む。月は順に締まるので通常は無害だが、**finalized の P.prev を差戻し→編集すると P の週次 OT が stale 化**する。締め差戻し時に **`period.next` も再集計するカスケード**（1 期間・有界）が要る。週×期間サマリの本質的カップリングゆえどの帰属規則でも生じる。**3-2 締めロジックへのハンドオフ**。
3. **分精度:** 週 40h は 2dp 丸め済みの時間を合算して 40h と比較（AR は分を保持しない）。週境界で分未満 drift があり得る。v1 は時間基準で統一。分精度要件が出れば後送り（§2 精度ノート・社労士確認 案③）。
4. **カレンダー遡及:** day_type は集計時点の CompanyCalendar を参照。締め済み期間のカレンダー改変による遡及的な day_type 書換は **3-2 のカレンダー編集制限**で封じる（既存バックログ「締め済み月の CompanyCalendar destroy 制限」と同根）。
5. **`scheduled_work_days` の所定判定:** v1 は resolver の `weekday` 判定。土曜等を所定労働日とする組織の精緻化（WorkPattern の稼働曜日連動）は後送り。
6. **35% 母数の登録漏れ連動:** legal_holiday 未登録の日曜が resolver フォールバックで `:sunday` 降格すると holiday_work_hours から漏れる。§4.7「要確認」化・既存バックログ「legal_holiday カバレッジ失効」と同根（4-1 通知基盤で接続）。
7. **無条件上書き × 締め状態（F1・全体フロー）:** 本サービスは status を見ず毎回フル上書き。3-1 では status 列が無く無害だが、3-2 以降 **`submitted`/`finalized` 期を上書きしないゲートは呼び出し側責務**（submit=意図的再集計・夜間バッチは `aggregating` のみ）。再集計（派生値・キャッシュ）と状態遷移（権威）を分離する契約として **3-2/4-2 へハンドオフ**。
8. **単一集計エンジン（F4・全体フロー）:** 本サービスを 4-2 の日次バッチも再利用（毎晩フル再集計＝現データのスナップショット）。積み上げ加算の別アルゴリズムを作らない。§6.4「前日積み上げ」文言の再訪は **4-2 ハンドオフ**。
9. **並行 upsert:** `find_or_initialize_by + update!` は read-modify-write。v1 は per-user・並行前提なしで妥当だが、3-2 でジョブ loop 化時に同一 (user, year_month) 並行起動が model 検証をすり抜け得る。DB unique index が一次防衛・`RecordNotUnique` rescue / 冪等再試行を 3-2 で補う（`AttendanceRecord` の index+rescue 思想と同型）。
10. **フレックスの週 40h（D7・社労士確認 案①）:** flextime は清算期間ベースゆえ v1 は週 40h 計算から除外。日次 legal OT は Phase 1 の既存挙動を踏襲（flextime 日も `legal_overtime_hours` を持ち得る＝Phase 1 の既知の割り切り）。flextime/変形の清算期間 OT 適正化は v2。
11. **`fiscal_year` 列の後置（D4）:** `AttendancePeriod#fiscal_year`（締め期間末日基準で一意）で導出可能。36 協定の年度集計を行う **4-3 が列を同梱追加**して埋める。3-1 は period 経由で導出可能にするのみ。

> **社労士確認 案①②③** を `docs/LABOR_LAW_REVIEW_NOTES.md` へ追記（labor-law レビュー反映・writing-plans 前）: ①フレックスへの週 40h 適用可否 ②締め期間をまたぐ週の賃金期帰属（賃金計算期間ズレ・労基法 37 条）③時間 2dp 丸めの週 40h 比較精度（割増 1 分単位原則・端数処理通達 昭和 63.3.14 基発 150 号系は未照合）。**いずれも 3-1 はブロッカーでなく、既知の限界として隔離済み**（原典照合で Critical ゼロ）。

> **未照合（混同防止）:** 法定休日 35% の率を定める政令（平成 6 年政令第 5 号）本文数値・割増端数処理通達は MCP 未取得。本スライスは率でなく**時間数の保存**ゆえ 35% 数値自体を持たず、正確性判定に影響しない。

---

## 6. レビュー方針

- models / migration に触れる → `tenant-isolation-reviewer`（merge 前・本設計で Critical 1 件指摘済＝同一組織検証を §1.1 へ反映済）
- §8 法定値（残業 2 系統・60h・週 40h・法定休日 35% 母数）に触れる → `labor-law-compliance-reviewer` + `/legal-citation-audit`（merge 前・本設計で原典照合済＝Critical ゼロ・案①②③ を NOTES へ）
- 大物スライスゆえ本設計を `/multi-perspective-review`（6 視点）に通済（2026-06-20・反映済）→ writing-plans へ
