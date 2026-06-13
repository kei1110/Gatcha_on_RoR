# Phase 1-2 計算オブジェクト 4 種（WorkTime / Overtime / DeepNight / LateEarly）設計

日付: 2026-06-13 ／ 対象スライス: ROADMAP 1-2 ／ SPEC: §5.1〜5.4・§4.8 計算列・§2.2-1・§2.3
多視点レビュー（5 視点・2026-06-13）反映済み — 反映一覧は §0 末尾。

## §0 方針

**スコープ:**
- `app/calculators/` に 6 ファイル: `scheduled_window.rb`（入力合成）+ 4 calculator + `minute_conversion.rb`（丸め規則の単一ソース）
- `attendance_records` へ計算 8 列追加（migration）
- `Clockings::Recalculate`（8 列書き戻しの唯一経路）+ `Clockings::ClockOut` からの呼び出し
- **ClockIn / ClockOut の打刻書き込みを秒精度へ切り詰め**（`Time.current.change(usec: 0)` — レビュー反映 R2）
- **WorkPattern の夜勤 start_time == end_time 等値拒否**（検証の隙間 — 長さ 0 窓の入口封鎖。レビュー反映 R6）
- SPEC §5.2 法定残業式の補正（後述）+ `/legal-citation-audit` 原典照合（労基法 32 条・37 条 4 項 — 設計レビューで照合済み・実装 PR で再確認）

**スコープ外（継ぎ目は §6）:**
- 週 40h 週次算出（Phase 3）／ LeaveDaysCalculator §5.5（Phase 2 休暇）／ 通知（Phase 2）／ 35% 暦日振り分け・is_holiday_work（2-4・労務 NOTES #14 の確認期限維持）

**brainstorm 決定（2026-06-13・全 A）:**
1. 半休ルール（§5.1/§5.4）は PORO 仕様完全実装。呼び出し側は Phase 2 まで `day_part: :full` 固定。※ただし「半休の所定労働分（standard ÷ 2）」は 1-2 のどの計算も消費しないことがレビューで判明 — 実装対象は休憩 3 系と遅刻早退の片側免除のみ（R3）
2. mode_conflict（night_shift × flextime）は**役割分担で両立**: WorkTime/Overtime は night_shift の翌日換算を適用、LateEarly は flextime のコアタイム判定を適用。両者は別カラムを読むため矛盾なく共存（WorkPattern 側の先送りコメントの宿題回収。SPEC §4.4 へも明記 — R5）
3. 未割当（work_pattern_id NULL）の退勤は**全計算列 NULL のまま skip**（NULL = 未計算の意味論。0 埋めは「残業ゼロ」と区別不能で監査上の欠陥）。通知は Phase 2 — 1-1 のホーム未割当バナーが当面の代替警告
4. NOTES #14 未確認のまま進行 — 1-2 の 4 計算は労基法 32 条の労働時間集計（work_date = 出勤日・昭 63.1.1 基発 1 号と整合）のみで暦日振り分けに触れない

**triage 決定（2026-06-13）: 失敗時方針 = 打刻保全 + rescue 報告**
Recalculate の例外で退勤打刻をロールバックすると、決定論的な計算バグの場合に該当社員が修正デプロイまで退勤不能になる（打刻ブロック禁止の原則と衝突）。clock_out の update! は守り、Recalculate 例外は ClockOut 側で rescue → `Rails.error.report` で顕在化 + 8 列 NULL 維持（NULL = 未計算の意味論を活用）。

**設計中に発見した SPEC 矛盾（本スライスで補正）:**
§5.2 の式は「法定残業 = max(0, 実労働時間 − **所定**労働時間)」だが、用語集 §0.3 と §5.2 週 40h 注記は「legal_overtime_hours（**1 日 8h 超**）」と明言しており、所定 ≠ 8h の組織で食い違う。労基法 32 条 2 項「休憩時間を除き一日について八時間」（原典照合済み <https://laws.e-gov.go.jp/law/322AC0000000049>）の法定時間外は 8h 基準が正（§8 コンプラ判定・36 協定カウントの母数）。**式を `max(0, 実労働 − 8h)` へ補正**し、所定基準の超過は scheduled 系統（所定外残業）が担う。8h = 480 分は法定値定数（テナント設定で改変不可・SPEC §8 原則）。

**新規決定 — 秒の扱い（SPEC §5 前文へ追記）:**
- **打刻はちょうど秒精度で保存**: ClockIn/ClockOut の書き込みを `Time.current.change(usec: 0)` で切り詰める（PG timestamptz はマイクロ秒精度を持つため、放置すると「9:00:00 ちょうど打刻」がサブ秒差で遅刻扱いになる — R2）
- **全ての分換算は「差分秒 ÷ 60 の整数除算（floor）」で統一**。深夜 2 窓の重複は**秒で合算してから 1 回だけ floor**（窓ごと floor は最大 1 分強の追加切り捨て = 労働者不利 — R1）
- §5.3 境界仕様（22:00:00 退勤含まず・22:00:01 以降含む）と整合: 22:00:01 退勤の深夜重複は 1 秒 → floor で 0 分
- 遅刻 1 分未満は `is_late=true` + `late_minutes=0`（判定は秒厳密・分数は floor）
- 日次 floor は労働者不利方向の端数処理 → **NOTES #16 として社労士確認に追加**。なお昭 63.3.14 基発 150 号は MHLW 法令等 DB で**原典取得不能・未照合**（後継解釈例規 平 21.10.5 基発 1005 第 1 号には端数処理の定めなし）— NOTES #16 文案に未照合の旨を明記する

**多視点レビュー反映一覧（R 番号は本文参照用）:**
- R1: DeepNight の floor 粒度を「2 窓合算後 1 回」へ（4 視点一致）
- R2: 打刻のサブ秒切り詰め（ClockIn/ClockOut 改修同梱）
- R3: `standard_work_minutes_for` は死蔵 — 削除（YAGNI・消費者ゼロ）
- R4: Recalculate 失敗時 = 打刻保全 + rescue 報告（triage A）
- R5: SPEC 逆反映の取り切り（§0.3 用語集・§4.8 列説明・§4.4 mode_conflict・§2.3 ファイル一覧・§5.3 分母と floor 粒度・§4.8 NULL 注記）
- R6: WorkPattern 夜勤等値（start == end）拒否の入口封鎖
- R7: コア翌日換算の条件に `night_shift?` を明示（SPEC 入力契約どおり）
- R8: Overtime/LateEarly の戻り値を `Data.define` へ（Hash キー typo の黙殺防止）
- R9: `scope :calculated` + is_late 直接 where 禁止コメント（SQL 3 値論理の罠封じ）
- R10: §8 コンプラ判定は週 40h 合算完了が前提（過少評価ガードを継ぎ目へ）
- R11: テスト計画を丸めモード判別可能な発火値へ全面差し替え
- R12（品質レビュー②・実装後反映）: Recalculate 呼び出しを with_lock の**外**（commit 後）へ — tx 内で SQL 例外を rescue すると PG が aborted になり「偽 success + 退勤消失」（実験で実証・GOTCHAS 追記済み）。Rails.error.report は severity: :error 明示

## §1 データモデル（migration）

`attendance_records` へ 8 列。**全列 NULL 許容・default なし**（NULL = 未計算）:

| 列 | 型 | 備考 |
|---|---|---|
| actual_work_hours | decimal(6,2) | §5.1 実労働（退勤−出勤−休憩） |
| legal_overtime_hours | decimal(6,2) | §5.2 法定残業（実労働 − 8h・負は 0） |
| scheduled_overtime_hours | decimal(6,2) | §5.2 所定外残業（退勤 − 所定終業・負は 0） |
| deep_night_hours | decimal(6,2) | §5.3 深夜（22:00–05:00・休憩按分控除後） |
| is_late / is_early_leave | boolean | 3 値運用 — NULL = 未判定（default なしを意図） |
| late_minutes / early_leave_minutes | integer | フレックスは 0 固定（§5.4 二値管理） |

モデル（attendance_record.rb）:
- 時間 4 列 + 分 2 列に `numericality: { greater_than_or_equal_to: 0 }, allow_nil: true`
- `scope :calculated, -> { where.not(actual_work_hours: nil) }` — **未計算判定はこのスコープ経由・is_late 等の直接 where 禁止**のコメント明記（`where(is_late: false)` は NULL 行を落とす SQL 3 値論理の罠 — R9。8 列は Recalculate が一括書き込みするため「一括 NULL か一括非 NULL」が不変条件）
- 書き込みは `Clockings::Recalculate` 限定の意図コメント（1-1 の work_pattern_id と同方式）

**WorkPattern（R6）:** `times_must_not_invert_without_night_shift` は夜勤で early return するため `night_shift=true && start_time == end_time` がすり抜け、ScheduledWindow が長さ 0 の窓になる。夜勤側にも等値拒否を追加（非夜勤は既存の `start < end` 必須のまま）。

## §2 ScheduledWindow（入力合成の単一ソース・app/calculators/scheduled_window.rb）

§5 入力契約（組織 TZ 合成・夜勤 +1.day・日跨ぎコア翌日換算）を**一箇所だけ**に実装する値オブジェクト。

```ruby
ScheduledWindow.for(pattern:, work_date:, zone:)
```

- `pattern` は duck（`start_time` `end_time` `night_shift?` `flextime?` `core_time_start` `core_time_end` `break_minutes` `effective_morning_half_break_minutes` `effective_afternoon_half_break_minutes` に応答 — R3 で `standard_work_hours` を削除）。テストは Struct で DB 不要（述語名 `night_shift?` / `flextime?` に応答させること）、実運用は WorkPattern AR。effective ヘルパ参照は 0b-4 WorkPattern コメントの指示どおり（フォールバック規則の単一ソース維持）
- `zone` は `ActiveSupport::TimeZone`（v1 は組織の `time_zone` = Asia/Tokyo 固定・DST 無）

公開インターフェース:

| メソッド | 内容 |
|---|---|
| `start_at` / `end_at` | `zone.local(...)` で work_date + time 合成。`night_shift? && start_time > end_time` のとき `end_at` を `+ 1.day`（Time.zone 上の加算 — §5 入力契約） |
| `core_start_at` / `core_end_at` | flextime 時のみ非 nil。**`night_shift? && core_time_start > core_time_end`** のとき end を `+ 1.day`（R7 — SPEC 入力契約の条件をそのまま。start/end 側と対称） |
| `break_minutes_for(day_part)` | `:full` → `break_minutes` ／ `:morning_half` → `effective_morning_half_break_minutes` ／ `:afternoon_half` → `effective_afternoon_half_break_minutes` |

`day_part` は `:full | :morning_half | :afternoon_half`（§4.8 の将来 status 名と揃える）。不正値は `fetch` ベースで即例外（fail-fast — 1-1 CalendarComponent と同方式）。

## §3 計算 4 種（純粋 PORO・キーワード引数）

共通規約: 入力は組織 TZ 変換済み `TimeWithZone` と整数分。出力は整数分（単値）または `Data.define`（複値 — R8）。時間化は §4 で最終 1 回のみ。`#call` は class method `call` → instance の 1-1 サービス規約と同形。分換算は `MinuteConversion.minutes_between(from, to)`（§0 の floor 統一）。

### 3.1 WorkTimeCalculator（§5.1）

```ruby
WorkTimeCalculator.call(clock_in:, clock_out:, window:, day_part:) # => Integer（実労働分）
presence  = MinuteConversion.minutes_between(clock_in, clock_out)
actual    = [presence - window.break_minutes_for(day_part), 0].max
```

- 在席 < 休憩は 0 に clamp（30 分勤務・休憩 60 分 → 0）
- 夜勤の翌日換算は**打刻側には不要**（clock_in/clock_out は実時刻 — 差分が自然に正）。window 側の換算は Overtime/LateEarly が使う

### 3.2 OvertimeCalculator（§5.2 補正後）

```ruby
OvertimeCalculator.call(actual_work_minutes:, clock_out:, window:)
# => Result（Data.define(:legal_overtime_minutes, :scheduled_overtime_minutes)）
LEGAL_DAILY_MINUTES = 480  # 労基法 32 条 2 項「一日について八時間」— 法定値・テナント改変不可
legal     = [actual_work_minutes - LEGAL_DAILY_MINUTES, 0].max
scheduled = [MinuteConversion.minutes_between(window.end_at, clock_out), 0].max
```

- legal は半休でも 480 のまま（法定閾値は所定に依存しない — 原典照合済み）。day_part 不要
- scheduled は時刻基準（§5.2 の定義そのまま）。半休・フレックスでも同式 — 所定終業の定義は `end_at` が唯一（午後半休の中間終業時刻はスキーマに存在しないため定義しない。早帰りは max(0) で 0 になるのみ）
- 変形労働時間制（清算期間判定）は v2 — SPEC §5.2 既記載

### 3.3 DeepNightCalculator（§5.3）

```ruby
DeepNightCalculator.call(clock_in:, clock_out:, break_minutes:, work_date:, zone:)
# => Integer（深夜分・按分控除後）
```

- 隣接 2 窓: `[zone.local(D-1, 22:00), zone.local(D, 5:00)]` と `[zone.local(D, 22:00), zone.local(D+1, 5:00)]`（D = work_date）。各窓と `[clock_in, clock_out]` の**重複秒を合算してから 1 回だけ floor** で分化（R1 — 2 窓は重ならない区間ゆえ秒合算は安全）
- 休憩按分: `deep_night_break = (break_minutes * overlap_minutes / presence_minutes).floor`（FLOOR = 労働者有利・§5.3）。presence_minutes = 退勤−出勤の gross 分（休憩込み在席 — SPEC §5.3 の total_work_minutes をこの解釈で明文化 — R5。0 分なら按分 0 のガード）
- 結果 = `[overlap_minutes - deep_night_break, 0].max`
- 境界: 22:00:00 ちょうど退勤 → 重複 0 秒 → 0 分。22:00:01 退勤 → 1 秒 → floor 0 分。22:01:00 → 1 分。出勤側も対称（5:00:00 出勤 → 0）
- **定義域**: clock_out が D+1 22:00 を超える（第 3 窓到達）入力は対象外 — ClockOut の window 探索（前日まで）と 4-2 打刻漏れバッチが上流で抑止する前提をコメント明記し、現挙動（第 3 窓は数えない）をテストで pin
- window（ScheduledWindow）非依存 — 深夜帯は法定帯でパターンと無関係。フレックス・夜勤・mode_conflict すべてロジック同一（§5.3「免除されない」・労基法 37 条 4 項原典照合済み）

### 3.4 LateEarlyCalculator（§5.4）

```ruby
LateEarlyCalculator.call(clock_in:, clock_out:, window:, flextime:, day_part:)
# => Result（Data.define(:is_late, :late_minutes, :is_early_leave, :early_leave_minutes)）
```

**固定時間制（flextime=false）:**
- 遅刻: `clock_in > window.start_at`（秒厳密・等値は遅刻でない）→ `late_minutes = minutes_between(start_at, clock_in)`（floor）
- 早退: `clock_out < window.end_at`（等値は早退でない）→ `early_leave_minutes = minutes_between(clock_out, end_at)`
- 夜勤は `end_at` が +1.day 換算済みゆえ「日跨ぎ退勤 = 早退でない」が自然に成立

**フレックス（flextime=true）:**
- 遅刻: `clock_in > window.core_start_at` ／ 早退: `clock_out < window.core_end_at`
- 分数は **0 固定**（§5.4 二値管理）

**半休の片側免除（両制度共通）:**
- `:morning_half`（午前休む）→ 遅刻判定 skip（is_late=false, 0 分）・早退のみ判定
- `:afternoon_half`（午後休む）→ 早退判定 skip・遅刻のみ判定

**mode_conflict:** flextime=true ならコア判定（night_shift の有無に関わらず）。日跨ぎコアは window 側で換算済み。

### 3.5 MinuteConversion（共有・app/calculators/minute_conversion.rb）

```ruby
MinuteConversion.minutes_between(from, to)  # ((to - from) / 60).floor — Integer
MinuteConversion.to_hours(minutes)          # (minutes.to_d / 60).round(2, half: :up) — §5 前文の HALF_UP
```

- 丸め規則（floor / HALF_UP）の単一ソース。第 3 メソッドは消費者先行で
- 実装注意: `TimeWithZone - TimeWithZone` は **Float 秒**。分境界一致時（両端 usec=0 — R2 で保証）は差分が整数で正確なため floor は安全 — この旨をコメントに残す

## §4 Clockings::Recalculate（書き戻し唯一経路・app/services/clockings/recalculate.rb）

```ruby
Clockings::Recalculate.call(record:)  # 戻り値は record。例外は投げ得る（rescue は呼び出し側の責務）
```

1. `record.work_pattern` が nil → **何もせず return**（全列 NULL 維持・brainstorm 決定 3）。計算済みレコードのパターンが後から外れた場合も同様に**残置**（クリアしない — 打刻変更承認 2-2 の再計算設計で再訪。テストで pin）
2. `zone = ActiveSupport::TimeZone[record.organization.time_zone]`、`window = ScheduledWindow.for(pattern:, work_date:, zone:)`
3. clock_in/clock_out を `in_time_zone(zone)` 変換（§5 入力契約）
4. 4 calculator 実行（day_part は v1 全経路 `:full`。DeepNight の `break_minutes:` には `window.break_minutes_for(day_part)` を渡す — 実際に控除した休憩と按分母体を一致させる）→ `MinuteConversion.to_hours` で時間 4 列を最終変換 → `record.update!(8 列)`

**呼び出しと失敗時方針（R4 + R12）:** `ClockOut` の `with_lock` が **commit した後**に呼び（tx 同居は SQL 例外で偽 success + 退勤消失になる — R12）、**begin/rescue で包み、例外は `Rails.error.report`（severity: :error）で報告して握る**（退勤打刻は保全・8 列は NULL のまま）。計算は全域関数ゆえ例外 = 実装バグだが、ロールバックで社員を退勤不能にしない（打刻ブロック禁止の原則）。「計算列 NULL × clocked_out」の検知は暫定 Sentry（error report 経由）・恒久は 4-2 バッチ（§6）。

**将来の合流**（§6）: 2-2/2-3 打刻変更承認・Phase 2 休暇承認の再計算もこの入口を使う（SPEC §4.8「打刻・打刻変更承認・休暇承認時に再計算」）。day_part は Phase 2 で status から導出。

**テナント文脈**: 呼び出し元（ClockOut）が `with_tenant` 内。Recalculate 自身も `ActsAsTenant.with_tenant(record.organization)` で自己完結（1-1 サービス規約踏襲・単体呼び出しに備える）。

## §5 テスト（R11 — 丸めモードを判別できる発火値で構成）

**MinuteConversion spec:**
- `minutes_between` floor ／ `to_hours` は**切り上げ発火値**で: 10 分 = 0.17（truncate なら 0.16）・481 分 = 8.02（truncate なら 8.01）。非発火値（30 = 0.50・50 = 0.83）は算術 sanity として併置
- ※整数分 ÷ 60 は第 3 位がちょうど 5 になる値が存在しないため half up/down の判別は原理的に不能 — 検証対象は「切り上げ発火 vs 切り捨て」であることをコメント明記

**ScheduledWindow spec（DB 不要・Struct duck・述語名対応）:**
- 通常日勤合成（9:00–18:00 JST）／ 夜勤 start > end の end +1.day ／ flextime × night_shift 日跨ぎコアの core_end +1.day ／ 非 flextime で core nil ／ break_minutes_for 3 系（**委譲のみ検証** — effective フォールバック実装は work_pattern_spec で担保済み）／ 不正 day_part で例外

**WorkTimeCalculator spec:**
- 標準 8h（540 分在席 − 60 休憩 = 480）／ 秒切り捨て（9:00:30〜18:00:00 = 539 分在席）／ 在席 < 休憩の clamp 0 ／ 半休休憩適用 ／ 夜勤跨ぎ（22:00〜翌 7:00）／ break 0 素通り ／ clock_in == clock_out → 0

**OvertimeCalculator spec:**
- legal 境界 3 点（479/480/481 分）／ 半休でも閾値 480 不変 ／ scheduled 等値・秒境界 3 点（end ちょうど退勤 = 0・end+1 秒 = 0・end+1 分 = 1）／ 早帰り max(0) ／ 夜勤の end_at +1.day 基準

**DeepNightCalculator spec:**
- 22:00 側境界 3 点（22:00:00 = 0・22:00:01 = 0・22:01:00 = 1 分）／ **5:00 側 3 点**（5:00:00 出勤 = 0・4:59:59 = 0・4:59:00 = 1 分）
- **早朝シフト前日窓**（4:00 出勤 → D 0:00〜5:00 帯捕捉 — §5.3 隣接 2 窓補正の消費）／ 夜勤通し（22:00〜翌 5:00・break 0 = 420 分）
- **2 窓同時寄与 + 按分**: in D 03:00・out D 23:30・break 60（presence 1230）→ overlap 210 分・按分 floor(60×210/1230) = 10 → **200 分**
- **按分 FLOOR 判別値**: break 60・presence 540・overlap 420 → 60×420/540 = 46.67 → floor 46（HALF_UP なら 47）→ **374 分**
- 秒合算→1 回 floor（窓ごと floor との差が出る入力: 各窓に 30 秒ずつ → 合算 60 秒 = 1 分）
- presence 0 ガード ／ 控除後 max(0) ／ **第 3 窓 pin**: in D 04:00・out D+1 23:00 → 480 分（D+1 22:00 以降は数えない — 定義域コメントと対）

**LateEarlyCalculator spec:**
- **等値負例**: start ちょうど出勤 → is_late=false ／ end ちょうど退勤 → is_early_leave=false ／ flex: core_start ちょうど → false
- 秒厳密 + floor 0 分（9:00:30 出勤 → true・0 分）／ 固定制の分数 ／ **遅刻早退同時成立**（in 10:00・out 17:00 → 両 true・各 60 分）
- フレックス二値 + 0 固定 ／ **半休 × フレックス複合**（morning_half × flex → 遅刻 skip + core_end 基準早退のみ）／ 半休片側免除 × 2 ／ 夜勤の日跨ぎ退勤 = 早退でない ／ mode_conflict（flex のコア判定）

**Recalculate spec（DB あり）:**
- 8 列保存の総合 1 本（夜勤含む）／ 未割当 NULL skip ／ **stale 残置 pin**（計算済み record のパターンを外して再実行 → 列不変）／ HALF_UP 最終変換は発火値（469 分 = 7.82）／ **テナント文脈 nil で単体呼び出し成功**（with_tenant 自己完結の検証）

**ClockOut 統合（既存 spec 拡張）:**
- 退勤で計算列が埋まる ／ 未割当でも退勤成功 + NULL 維持 ／ **race 敗者で計算列 NULL のまま**（既存 race テストに assert 追加）／ **夜勤跨ぎで deep_night_hours まで検証**（22:00–7:00 パターン割当・assert は travel_to 内 — GOTCHAS の timeoutable 罠）／ **Recalculate 例外 stub → 退勤成功 + NULL + Rails.error 報告**（R4 の検証）

**モデル spec 拡張:**
- AttendanceRecord: 8 列の numericality（負値 invalid・nil valid）・`calculated` スコープ
- WorkPattern: 夜勤 start == end 拒否（R6）

**法令照合:** `/legal-citation-audit` で労基法 32 条（1 日 8h・週 40h）・37 条 4 項（22–5 時）を jp-labor-evidence 原典照合（設計レビューで照合済み — 実装 PR で記録を残す）

## §6 継ぎ目（このスライスでは作らないもの）

| 継ぎ目 | 消費フェーズ |
|---|---|
| Recalculate の day_part を status から導出 | Phase 2（半休 status 導入時） |
| 半休の所定労働分（standard ÷ 2）の消費先 — 残高 0.5 日・清算 | Phase 2 残高 ／ v2 フレックス清算（R3） |
| 打刻変更承認 → Recalculate 再利用（stale 残置の再訪含む） | 2-2/2-3 |
| is_holiday_work・35% 暦日振り分け（NOTES #14 確認後） | 2-4 |
| 週 40h 週次算出・月次合算 — **§8 コンプラ判定はこの完了が前提**（日次 8h 超のみは法定時間外の部分集合 = 過少評価方向。R10） | Phase 3 |
| 「計算列 NULL × clocked_out」の恒久検知（暫定は Sentry 報告） | 4-2 バッチ |
| 未割当時の管理者通知 | Phase 2（通知基盤） |
| mutant 導入（calculator 配下限定） | 1-2 完了後に検討（ROADMAP 行 84） |

## §7 docs 逆反映（実装 PR に同梱）

- **SPEC §5.2**: 法定残業式を `max(0, 実労働 − 8h)` へ補正（労基法 32 条 2 項・出典 URL・照合日 2026-06-13）
- **SPEC §0.3 用語集・§4.8 列説明**: 「実労働−所定」表記の掃討（`grep '実労働.*所定'` で取り切る — R5）
- **SPEC §5 前文**: 秒→分 floor 統一規則（打刻の秒精度保存・深夜 2 窓は秒合算後 1 回 floor）を入力契約に追記
- **SPEC §5.3**: total_work_minutes = gross 在席分（休憩込み）の明文化
- **SPEC §4.4**: mode_conflict の役割分担（WorkTime/Overtime = night_shift 換算・LateEarly = flex コア判定）を明記
- **SPEC §4.8**: 計算 8 列に「NULL = 未計算（一括 NULL / 一括非 NULL）」注記
- **SPEC §2.3**: ファイル一覧へ scheduled_window.rb・minute_conversion.rb 追加
- **ROADMAP**: 1-2 行チェック + PR 番号 ／ 行 84 のパス表記 `app/services/calculations` → `app/calculators` 修正
- **WorkPattern コメント**: 「優先ルールは Phase 1 計算側」の宿題回収 — 決定内容と参照先（本設計 §0-2）へ更新
- **NOTES #16 新規**: 日次の秒 floor 端数処理（基発 150 号は **MHLW DB で原典取得不能・未照合** — 月単位丸め容認とされる通説の真偽確認含む）
- **RAILS_GOTCHAS**: 実装中に踏んだ罠があれば同 PR 追記
