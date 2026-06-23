# Phase 3-3 月次サマリ・日別明細 CSV + 休暇集計 — 設計

- 日付: 2026-06-23
- スライス: ROADMAP Phase 3-3。**2 PR に分割**（D1）:
  - **3-3a** 休暇集計の素材整備（`feat/phase3-3a-leave-aggregation`）— migration + 承認 hot path 統合 + 集計エンジン拡張
  - **3-3b** CSV 出力（`feat/phase3-3b-csv-export`）— exporter + controller/routes/policy + 最小 UI
- 典拠: SPEC §6.4（月次勤怠レポート・CSV エクスポート 2 種）・§4.13（`MonthlyAttendanceSummary` 列定義＝`paid_leave_days_used`/`total_leave_hours` の正本）・§5.5/§5.6（休暇日数・割増区分）・§6.2（休暇承認副作用・月跨ぎ per-day 分割計上）・§3.4（自分 + 部下 scope）・§3.6（テナント分離・ジョブの `with_tenant`）・§16.1（CSV はストリーミング応答）・§8.6（有給 5 日義務＝本休暇集計と意味論が**別物**である境界の典拠）
- 前提エンジン: Phase 2-2b（`LeaveRequests::ApplyApproval`）・2-5（`LeaveRequests::Withdraw`・`Withdrawable`）・3-1（`MonthlySummaries::Aggregate`・`AttendancePeriod`・`MonthlyAttendanceSummary`）・3-2（締め状態機械・`MonthlyAttendanceSummariesController` 最小 UI・`MonthlyAttendanceSummaryPolicy`）はすべて据付・merge 済（main = 3-2 完了）
- **本設計のブレスト確定事項（2026-06-23・`superpowers:brainstorming`）**: 休暇集計の源泉＝A 案（D2）／`total_leave_hours` 換算＝所属パターン時間（D3）／CSV 粒度＝サマリ collection・明細 member（D4）／2 PR 分割（D1）をユーザー承認済み。設計全体（§1〜§7）もユーザー承認済み
- **多視点レビュー反映（2026-06-23・`/multi-perspective-review` 6 視点: 原則整合/実用主義/YAGNI/セキュリティ・テナント/承認 hot path/労務）**: 全視点の指摘を前後実コード・SPEC と実ファイル照合。視点横断で一致した重大指摘 5 件（F1 CSV formula injection／F2 サマリ CSV の社員識別子列欠落／F3 `Withdraw` の `leave_type_id` クリア必須＋ラベル過小／F4 backfill のテナント文脈・D2 矛盾／F5 absence_to_paid「自動カバー」時期尚早）と採用指摘を本文へ反映。各反映箇所に「（多視点: <視点>/<重要度>）」で出所明記。**Critical/High 級のクロステナント漏洩は無し**（複合 FK・policy_scope・strong params・hot path は二重 org 束縛で構造的に leak-safe）と全セキュリティ系視点が一致。ユーザー判断: 社員識別子列＝追加（D11）／backfill＝落として再 seed（D2・§1.1c）／CSV＝ストリーミング維持・全行事前確定（D7）

## 0. スコープと前提

Phase 3-1 が `MonthlyAttendanceSummary`（永久保持）へ AR 由来の素材を冪等 upsert する `Aggregate` を、3-2 が締め状態機械を据えた。ただし **3-1 の素材は AttendanceRecord 由来のみ**（`aggregate.rb:11-12` の `WORKED_STATUSES` で `on_leave` を明示除外）で、§4.13 が定義し §6.4 月次サマリ CSV が要求する**休暇側 2 列（`paid_leave_days_used` / `total_leave_hours`）が MAS に存在しない**。3-3 はこの穴を塞ぎ、§6.4 の CSV 2 種を出して Phase 3（月次締め）を完了させる。完了条件:

> hr_admin / manager が「ある年月・scope 内全社員」の**月次サマリ CSV**（給与システム入力用・1 行=1 社員・**社員識別子列で行↔社員を突合**＝D11）を、本人/manager/hr_admin が「個人 1 ヶ月」の**日別明細 CSV**（1 行=1 日）を、UTF-8 BOM + CRLF + RFC 4180（**＋ formula injection サニタイズ**＝F1）でストリーミング DL でき、サマリには有給使用・総休暇時間を含む割増区分が網羅される。

### なぜ休暇集計が「どのスライスにも割り当たっていなかった」か（seam）

3-1 は「素材保存のみ」と銘打って AR 由来集計（労働/残業/深夜/遅刻早退）だけを保存し、3-3 は当初「CSV を描く」だけのスライスだった。だが §6.4 月次サマリ CSV の `有給使用`・`総休暇時間` は **AttendanceRecord に存在しない情報**（AR は `status` で休暇日と分かるが `leave_type`・paid/unpaid を持たない・`ApplyApproval` は `leave_type_id` を AR に焼かない）。ゆえに休暇集計はどちらのスライスにも属さず宙に浮いていた。本スライスがこれを 3-3a として明示的に owner にする。

### 設計判断ログ

| # | 論点 | 決定 | 根拠 |
|---|------|------|------|
| D1 | PR 分割 | **2 PR**＝3-3a（§1–§4: migration + 承認統合 + 集計）/ 3-3b（§5–§6: CSV + controller + UI） | 3-3a は承認 hot path（ApplyApproval/Withdraw）に触れ approval-engine + tenant-isolation レビューが重い。3-3b は読み取り専用の配管。観点が異なるため分割し各 PR をレビュー可能なサイズに保つ（2-2a/2-2b と同型） |
| D2 | 休暇集計の源泉 | **A 案＝AR に `leave_type_id` を持たせる**。`ApplyApproval` が休暇 AR 作成時に set、`Withdraw` が逆操作で整合。`Aggregate` は period 内の**凍結済み休暇 AR を読むだけ** | 単一ソース（AR の凍結日付）＝カレンダー再計算 drift も状態 drift も**構造的にゼロ**。**pre-production ゆえ backfill migration は書かず dev/test 再 seed で対応**（§1.1c・多視点: 実用主義/Med で D2⇄旧§1.1c の矛盾を是正）。**却下**: B 案（LeaveRequest 由来集計＝`counted_dates` 再計算でカレンダー変更 drift の窓・2-5 が潰した drift の再導入）／C 案（ハイブリッド＝日付→請求マップ構築が込み入る） |
| D3 | `total_leave_hours` の日→時間換算 | **所属パターン時間**＝その社員・その日の `WorkPattern.standard_work_hours`（半休は ÷2・`work_pattern.rb:60` の半休所定と一致）。解決順は **§6.1 スナップショット優先**＝`record.work_pattern`（半休+打刻 AR は打刻時に `work_pattern_id` をスナップ済）→ 純休暇日（NULL）のみ effective 割当 lookup。未割当日は **0h**（多視点: 労務/Warning で snapshot 優先化・YAGNI/Med・労務/要確認で 0h × paid>0 の食い違いを §7.1 明記＋データ品質シグナルは Phase 4-2 観測へ） | 給与正確・既存 `standard_work_hours` を使い、worked 集計（`record.work_pattern`）と同日で乖離させない。**却下**: 固定 8h/4h（`standard_work_hours` が 8 でないパターン＝スキーマが明示サポートの組織で給与入力がずれる） |
| D4 | CSV の粒度と出力口 | **サマリ CSV = collection**（`?year_month=YYYY-MM`・`policy_scope` 内全社員を 1 行ずつ）/ **明細 CSV = member**（その社員の 1 ヶ月・1 行=1 日・AR 直） | §6.4/§16.1 の給与連携文脈（全社員分を 1 ファイルで給与へ）に最も沿う。明細は個人の監査導線 |
| D5 | 休暇集計の母数 | **period.range 内の leave-status AR を直接読む**（`status ∈ LEAVE_STATUSES`）。`counted_dates` を再計算しない | AR は in-effect 休暇の materialized truth（`ApplyApproval` が作成・`Withdraw` が逆操作）。直接読めば月跨ぎは period.range で切るだけ＝drift なし（2-5 の「counted_dates 非再計算で drift 解消」と同思想）。`ApplyApproval` が `counted_dates` のみ AR 作成ゆえ母数 = §5.5 計上日 = `days_requested`（労務視点で実装裏取り） |
| D6 | 集計の置き場 | **`MonthlySummaries::LeaveAggregator`（AR を読む集計サービス／query object）を `Aggregate` が合成**。`Aggregate` は MAS の単一 writer のまま | `Aggregate` を肥大させず休暇集計を独立テスト可能に。単一責務。※「PORO」表記は不正確（AR 依存）ゆえ query object と呼ぶ（多視点: 原則整合/Low・実用主義 が分割自体は妥当と確認） |
| D7 | CSV ストリーミング | **Rack の Enumerator-body**（`ActionController::Live` 不使用）+ **行は stream 開始前に全件確定**。Ruby 標準 `CSV` で行生成 | §16.1「ストリーミング応答」を満たしつつ Live のスレッド複雑さを回避。**全行を事前確定**して mid-stream 例外による「200 + 欠損」破損 CSV を排除（多視点: 実用主義/Med・payroll silent corruption 対策＝F10）。body 内は捕捉済 tenant で `with_tenant` ラップ・`without_tenant` 回避を禁止（多視点: セキュリティ/Med・§5.2）。**後置**: ジョブ非同期化 + DL リンク（§16.2・YAGNI） |
| D8 | AR の不変条件 | **CHECK 制約 `leave_type_id IS NULL OR status IN (2,3,4)`**（worked 行に休暇種別が紛れ込むのを DB 最終防衛）+ AR モデルに対称 validation。migration に enum→整数の対応コメント | §3.6 の「DB 最終防衛 idiom」。アプリ層バグ（worked 行へ誤代入）を最終層で弾く。整数ハードコードは §13.1 凍結 enum と一致（leave 系 status 追加時は CHECK も更新する旨を migration コメントに明記・全視点 Low/Info） |
| D9 | §4.13 残列 | **追加しない**（`absent_days` / `interval_violation_count` / `consecutive_work_days_max` / `is_medical_guidance_target` / `medical_guidance_on` / `medical_guidance_note`） | producer が Phase 4（欠勤確定 4-2・インターバル/連続勤務 4-2/4-4・産業医 4-3）かつ §6.4 CSV 列に非掲載。「消費する Phase の PR が列を同梱」原則（ROADMAP backlog #95・YAGNI 視点で正当性確認） |
| D10 | CompanyCalendar destroy 制限 | **後送り**（本スライス対象外） | ROADMAP backlog line 88。CSV は読み取りのみで blocker でない。締め安全の loose end として Phase 4/5 で回収 |
| D11 | サマリ CSV の社員識別子列 | **`employee_code`（安定キー・NOT NULL）+ `name` を先頭に追加**。§6.4 列リスト自体の穴ゆえ **SPEC §6.4 にも同 PR で追記** | 「1 行=1 社員・給与入力用」なのに §6.4/旧§4 マッピングに識別子が無く行を社員へ突合不能（多視点: 実用主義/High・セキュリティ/Med で一致）。`name` はユーザー入力由来ゆえ F1 サニタイズ対象 |
| D12 | CSV formula injection | **exporter で全セルをサニタイズ**（先頭 `=` `+` `-` `@`・TAB・CR は `'` 前置等で無害化） | `RAILS_GOTCHAS.md:154-159` が**本スライスを名指し**で予約済の既知罠。RFC 4180 quoting は別物で防げない（多視点 5 視点で一致＝最優先 F1）。識別子 `name`（D11）等ユーザー入力セルが発火点 |

### 本スライスに含めない（明示的後置）

- **§4.13 の Phase 4 列**（D9）→ 4-2/4-3/4-4
- **CompanyCalendar destroy の締め済み月制限**（D10・backlog line 88）→ Phase 4/5
- **CSV のジョブ非同期化 + DL リンク**（D7）→ §16.2 の本格非同期は YAGNI。v1 は同期ストリーミング
- **月次レポートのリッチ ViewComponent**（§6.4「Hotwire で表示」のサマリ + 日別明細の作り込み）→ 3-3b は既存 index/show に**最小の DL ボタン導線**のみ。表示画面の作り込みは Phase 5 ダッシュボード（§12.2）で再訪
- **通知**（§6.4 と無関係）→ 全 Phase 4-1
- **未割当パターン日 leave の積極的観測**（0h × paid>0 のデータ品質シグナル）→ Phase 4-2 のデータ整合バッチ（v1 は silent・§7.1 で明記のみ）

---

## 1. データモデル（3-3a）

### 1.1 マイグレーション

**(a) `attendance_records` に `leave_type_id` 追加（A 案の核）**

| カラム | 型 | 制約 |
|---|---|---|
| `leave_type_id` | bigint | NULL 可（worked 行は NULL） |

- 複合 FK `[organization_id, leave_type_id] → leave_types[organization_id, id]`（自己テナント強制・既存 `attendance_records → work_patterns` FK と同型＝`schema.rb:336`・被参照 `leave_types` の unique index `schema.rb:198` で裏打ち）。`/create-migration` 規約に沿う。
- **CHECK 制約**（D8）: `leave_type_id IS NULL OR status IN (2,3,4)`。制約名 `attendance_records_leave_type_only_on_leave_status`。**migration に enum→整数の対応コメント**（working=0/clocked_out=1/morning_half=2/afternoon_half=3/on_leave=4・§13.1 凍結 enum・leave 系追加時は CHECK も更新）。
- **参照側 index は入れない**（多視点: YAGNI/Med・セキュリティ/Info で一致）。集計の hot query は `(user_id, work_date, status)` で既存 unique index `[user_id, work_date]` が担当し、子側 index は FK 整合に不要（親 `leave_types` 削除高速化のみ・削除は稀）。将来 `leave_type_id` で AR を絞るレポートが出たら追加する（§16.2「計測→index」）。

**(b) `monthly_attendance_summaries` に休暇 2 列追加（§4.13 の正本に一致）**

| カラム | 型 | 制約 |
|---|---|---|
| `paid_leave_days_used` | decimal(6,2) | NOT NULL, default 0 |
| `total_leave_hours` | decimal(7,2) | NOT NULL, default 0 |

既存テーブルへのカラム追加（複合 FK・unique index は 3-1 設置済）。新 FK なし。

**(c) backfill は行わない＝dev/test 再 seed で対応（多視点: 実用主義/Med・F4）**

pre-production ゆえ本番データは無い（ROADMAP 5-3「デプロイ先決定後」）。既存 dev/test の leave-status AR（`leave_type_id` NULL）は **backfill data-migration を書かず再 seed** で解消する（D2 と整合・`create-migration` skill も data-only を別扱い）。新規に作られる leave AR は §2.1 で `leave_type_id` が必ず set される。再 seed されない長命 dev DB の leave AR は `leave_type_id` NULL のまま残るが CHECK は満たし、集計で paid 0・hours は status から算出（孤児として無害・§7.1）。

> backfill を将来どうしても要する場合（本番投入時等）は、`require_tenant = true` 下の data migration ゆえ **生 SQL `UPDATE...FROM` で `organization_id` を結合キーに含め**（acts_as_tenant バイパス）、重複 in-effect 休暇時の選択規則（最新 approved 等）を決定化すること（多視点: セキュリティ/Med・「1 日 1 in-effect 休暇＝単射」は overlap guard 不在ゆえ未検証前提だった）。本スライスでは不要。

### 1.2 `AttendanceRecord` モデル

- `belongs_to :leave_type, optional: true`。
- validation `validate :leave_type_only_on_leave_status`（CHECK と対称・`leave_type_id` 有り ⟹ `leave_status?`）。
- 既存の 8 計算列契約・`calculated` スコープ・`LEAVE_STATUSES` は不変。

---

## 2. 承認 hot path の統合（3-3a・2 点のみ）

いずれも `Approvals::Approve` の `with_lock` 内・同一 tx で呼ばれる既存サービス（`apply_approval.rb:19`・`withdraw.rb:17` で自己完結 `with_tenant` ラップ・内側 rescue なし・raise 伝播で atomic rollback を承認 hot path 視点が裏取り）。**approval-engine-reviewer + tenant-isolation-reviewer 対象**。grep 確認: leave-status を AR に書く経路は `apply_approval.rb:54` の 1 点、leave→worked へ戻す経路は `withdraw.rb` の else の 1 点のみ（網羅済）。

### 2.1 `LeaveRequests::ApplyApproval#upsert_attendance_records`

per-day AR の `find_or_initialize_by(user_id, work_date)` 後、`record.status = leave_status` と並べて **`record.leave_type_id = @leave_request.leave_type_id`** を代入。

> **absence_to_paid（§6.2・absent→on_leave 上書き）は本スライスでは休眠**（多視点: 承認 hot path/Warning・実用主義・労務で一致）。`absent`(5) は AR enum 未追加（`attendance_record.rb:13`「4-2 で追加」）で経路が存在しない。「同経路ゆえ自動カバー」に依存せず、**Phase 4-2 の absence_to_paid 実装 PR が `leave_type_id` set を所有する** handoff とする（absent→on_leave 上書き経路に leave_type_id set + guard spec を必須化）。

### 2.2 `LeaveRequests::Withdraw#restore_attendance_records`

範囲内 leave-status AR の戻し 2 分岐のうち:
- `clock_in.blank?`（純休暇日）→ `record.destroy!`（**`leave_type_id` も行ごと自動消滅・追加コードなし**）。
- `else`（**`clock_in.present?` の全 leave AR** ＝半休+打刻 / **clocked 済日への全休 stale**〔ROADMAP line-104〕の双方）→ `record.update!(status: ..., leave_type_id: nil)` と **`leave_type_id` のクリアを同一 `update!` 内で併記**（多視点: 承認 hot path/**Critical**）。

> **これは省略不可**。クリアを忘れると worked へ戻る行（status 0/1）が `leave_type_id` を残し **CHECK 違反 → `with_lock` ごと rollback → 撤回承認が永久にリトライ失敗**（DoS 面）。ラベルは「半休+打刻」だけでなく `clock_in.present?` 全般を指す（line-104 stale 全休も同分岐）。テストは両ケースをハードゲート化（§7.2）。`reject_withdrawal`（副作用なし・§13.6）は AR 非接触ゆえ対象外。`ClockChangeRequests::ApplyApproval/Withdraw` は status 不変（clock_in/out のみ）で leave↔worked 境界を跨がず CHECK-safe（承認 hot path 視点が cross-path 検証済・実装時に `record.save!` が走る点のみ確認）。

---

## 3. 集計エンジン拡張（3-3a）

### 3.1 `MonthlySummaries::LeaveAggregator`（AR を読む集計サービス／query object・D6）

```
LeaveAggregator.call(user:, period:) → { paid_leave_days_used:, total_leave_hours: }
```

- 母数（D5）: `AttendanceRecord.where(user:, work_date: period.range, status: AttendanceRecord::LEAVE_STATUSES).includes(:leave_type)`。**`.calculated` を課さない**（理由は「leave 集計は 8 計算列を読まない＝status / leave_type / standard_work_hours のみで算出する」ゆえ。純休暇日が 8 列 NULL である点に依存しない＝#104-stale な on_leave〔打刻済日への全休で計算列が非 NULL 残置〕でも stale な actual を読まず正しく leave 計上・多視点: 原則整合/Med で根拠を一本化）。
- 日重み: `on_leave → 1.0` / `morning_half`・`afternoon_half → 0.5`。
- `paid_leave_days_used = Σ (record.leave_type&.paid_leave? ? weight : 0)`（BigDecimal）。
- `total_leave_hours = Σ hours(record)`、`hours = standard_work_hours`（半休は ÷2・未割当日は 0h）。**全種別**（paid 不問）。
- **パターン解決（§6.1 スナップショット優先・D3）**: `record.work_pattern`（半休+打刻 AR は `work_pattern_id` をスナップ済）を優先し `standard_work_hours` を読む → 純休暇日（`work_pattern_id` NULL）のみ `user.user_work_patterns.includes(:work_pattern).to_a` を 1 回ロードして effective（`active && start_date ≤ date && (end_date.nil? || end_date ≥ date)`）な assignment を in-memory 解決（N+1 回避）。これで遡及割当変更時も worked 集計と同日で乖離しない。
- **テナント防御ラップ**: `Aggregate` 同型に `ActsAsTenant.with_tenant(user.organization)`（将来バッチ化に fail-closed・§3.6）。

> **`paid_leave_days_used` の意味論境界（多視点: 労務/Warning・原典照合済）**: 本列は `leave_type.paid_leave?`（**全種別**・annual 非限定）の給与表示用素材であり、**§8.6（労基法 39 条・有給 5 日義務）の充足日数（`satisfied_days`＝annual 限定・新規付与 10 労働日以上・39 条 8 項の参入規則）とは別物**。admin が代休/振替種別に `paid_leave=true` を立てると本列に混入し得る（`leave_type.rb:19-20`）。**§8.6 判定は本列でなく `LeaveBalance`(annual=`paid_annual?`) + annual フィルタ済取得を独自 source とすること**を §8.6 実装（4-3）への handoff とし、`LABOR_LAW_REVIEW_NOTES.md` にも追記（付録）。

### 3.2 `MonthlySummaries::Aggregate` の合成

`attributes` に `LeaveAggregator.call(user: @user, period: @period)` の 2 値をマージ。既存の AR 由来集計（労働/残業/深夜/遅刻早退）は不変＝§8.1/§8.2 の 35% 法定休日母数・60h 分離・割増 2 系統に**非混入**（CHECK 制約が worked 行への種別混入を DB 最終防衛・労務視点が `holiday_work_hours`/`overtime_hours_over_60`/`total_overtime_hours` 不変を確認）。月跨ぎは AR 日付を period.range で切るだけ＝**counted_dates 再計算なし＝drift なし**。

---

## 4. §6.4 列マッピング（参照表）

| 月次サマリ CSV 列 | 源泉 |
|---|---|
| **社員コード**（D11 新規） | `summary.user.employee_code`（安定キー・NOT NULL） |
| **氏名**（D11 新規・F1 サニタイズ対象） | `summary.user.name` |
| 所定/実出勤日数 | `summary.scheduled_work_days` / `work_days` |
| 総労働 / 総残業 | `summary.total_work_hours` / `total_overtime_hours` |
| 60h 超 | `summary.overtime_hours_over_60` |
| 法定休日 | `summary.holiday_work_hours` |
| 深夜 | `summary.total_deep_night_hours` |
| 管理監督者フラグ | `summary.user.exempt_from_overtime`（join・preload） |
| 有給使用 | `summary.paid_leave_days_used`（**3-3a 新規**） |
| 遅刻 / 早退 | `summary.late_days` / `early_leave_days` |
| 総休暇時間 | `summary.total_leave_hours`（**3-3a 新規**） |

> 社員コード/氏名は §6.4 列リスト自体に欠落していた（D11）。**SPEC §6.4 を同 PR（3-3b）で「社員コード・氏名」を含むよう追記**する。

| 日別明細 CSV 列（§6.4・1 行=1 実在 AR） | 源泉 |
|---|---|
| 日付 | `record.work_date`（`YYYY-MM-DD`） |
| 出勤 / 退勤 | `record.clock_in` / `clock_out`（組織 TZ・`HH:MM`・**NULL → 空セル**） |
| 実労働 / 残業 / 深夜 / 遅刻早退 | `record.actual_work_hours` / `legal_overtime_hours` / `deep_night_hours` / `late_minutes`・`early_leave_minutes`（**NULL → 空セル**・休暇日は計算 8 列 NULL） |
| status | `record.status`（i18n ラベル） |

---

## 5. CSV 出力層（3-3b）

### 5.1 exporter（行生成サービス）

- `MonthlySummaries::Csv::SummaryExporter`（summary 群 → 行）/ `MonthlySummaries::Csv::DailyDetailExporter`（AR 群 → 行）。行生成を controller から分離し独立テスト可能に。
- 形式（§6.4・§16.1）: **UTF-8 BOM（先頭に `﻿`〔U+FEFF〕を 1 度だけ出力）+ CRLF（`CSV.new(row_sep: "\r\n")`）+ RFC 4180**（quoting は Ruby 標準 `CSV` に委譲）。日付 `YYYY-MM-DD`・時刻 `HH:MM`・小数ドット。**NULL は空セル**（"0" 誤出力を避ける・多視点: セキュリティ/Info）。
- **formula injection サニタイズ（D12・最優先 F1）**: 全セル文字列で、先頭が `=` `+` `-` `@`・TAB(`\t`)・CR(`\r`) の場合は `'` 前置（or 同等の無害化）。特に `name`（ユーザー入力由来）が発火点。共通ヘルパ化し両 exporter で適用。`RAILS_GOTCHAS.md:154-159` の本スライス名指し罠への対処を本実装と同 PR で台帳へ verified 追記。
- ヘッダは i18n（`ja.yml` の専用キー群）。
- 時刻の TZ: 保存済タイムスタンプを組織 TZ で整形（`time&.in_time_zone(org.time_zone)&.strftime("%H:%M")`・既存 `clock_change_request_row_component.rb:19` / `application_helper#t_time` 同型。`Clockings.proxy_note_fragment` は `Time.current` 整形ゆえ参照先として不適切・多視点: 実用主義）。

### 5.2 ストリーミング（D7・全行事前確定）

- **行は body 生成前に全件確定**（DB クエリ・サニタイズを stream 開始前に完了）。mid-stream 例外で「200 + 欠損」破損 CSV になる payroll silent corruption を排除（F10）。例外は clean に 5xx へ。
- controller で `response.headers["Content-Type"] = "text/csv; charset=utf-8"`・`Content-Disposition: attachment`、body に Enumerator を割り当て（BOM → ヘッダ → 確定済データ行を yield）。`ActionController::Live` 不使用。
- **テナント文脈**: body 生成前に `t = ActsAsTenant.current_tenant` を捕捉し、行確定〜yield を `ActsAsTenant.with_tenant(t) { ... }` で包む（`Aggregate`/`ApplyApproval` 同型の fail-closed）。**`ActsAsTenant.without_tenant` での握り潰しは禁止**（多視点: セキュリティ/Med・relation の lazy load も同ラップ内）。

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

- **`before_action :set_summary` の `only:` に `:detail_csv` を追加**（現状 `%i[show submit finalize defer]`・多視点: 実用主義/セキュリティ）。`summary_csv` は collection（`:id` 無し）ゆえ加えない。
- `summary_csv`（collection）: `authorize MonthlyAttendanceSummary, :summary_csv?` → **`policy_scope` 起点**（manager=自分+部下／hr_admin=全社・§3.4・生 where 禁止 §16）→ `where(year_month: params[:year_month])`・`includes(:user)` で N+1 回避 → `SummaryExporter` をストリーミング。`year_month` は `AttendancePeriod.new(organization: current_tenant, year_month:)` の `YEAR_MONTH_FORMAT` 検証を流用（**`organization:` 必須**・多視点: 実用主義）し、不正/欠落は `rescue ArgumentError → 400`（空 CSV を返さず明示エラー）。
- `detail_csv`（member）: `set_summary`（`policy_scope.find` ＝ scope 外は 404・IDOR 対策）→ `authorize @summary, :detail_csv?` → `AttendancePeriod.new(organization: current_tenant, year_month: @summary.year_month)` の `range` で `AttendanceRecord.where(user: @summary.user, work_date: period.range).order(:work_date)` → `DailyDetailExporter`。**記録の無い日は行を作らない**（1 行 = 1 実在 AR・休暇 status 行も含む）。

> 明細の `AttendanceRecord.where(user:)` は §16「CSV は生 where 禁止・policy_scope 起点」の文言に形式上触れるが、**認可境界は `@summary`（`policy_scope.find` 済）であり AR はその user への射影**。tenant 喪失時の安全は複合 FK `(org, user_id)` 束縛に依存（多視点: セキュリティ/Low で leak-safe 確認・本注記で意図を明示）。

### 6.3 policy（`MonthlyAttendanceSummaryPolicy` 追加）

- `summary_csv? = index?`（= `user.present?`。実ゲートは `Scope` の交差・一般社員は自分 1 行のみ出る＝意図どおり）。
- `detail_csv? = show?`（= `own? || manages? || hr_admin?`・既存述語を再利用）。

### 6.4 UI（最小導線）

- `index.html.erb`: 年月セレクタ + 「月次サマリ CSV」DL ボタン（`summary_csv` へ）。
- `show.html.erb`: 「日別明細 CSV」DL ボタン（`detail_csv` へ）。

---

## 7. エッジケース / テスト

### 7.1 エッジケース

- **半休 + 打刻**: `morning_half`/`afternoon_half` は `WORKED_STATUSES`（worked 集計）と `LEAVE_STATUSES`（leave 集計）の両方に属す。worked 側 `work_days`（`in_period.size`）では半休も **1.0 出勤日**、leave 側 `paid_leave_days_used` では **0.5** で計上＝**二重計上ではなく別メトリクス**（多視点: 原則整合/Med で「0.5 出勤日」誤記を是正）。給与側は work_days と paid_leave_days_used を素朴合算しない前提。
- **#104-stale な on_leave**: 打刻済日への全休承認で計算 8 列が stale 非 NULL 残置でも、LeaveAggregator は計算列を読まず status/leave_type/standard_work_hours のみで算出ゆえ **leave 日として正しく計上**（stale な actual は不参照）。
- **未割当パターン日の leave**: `total_leave_hours` 寄与 0h・`paid_leave_days_used` は leave_type で計上（日数は乗る）。同日で **paid>0 かつ hours=0 の食い違い**が出る（給与レビュアーが気付くシグナル）。v1 は silent・データ品質バッチは Phase 4-2（多視点: YAGNI/Med・労務/要確認）。
- **撤回済 leave**: `withdrawn` は AR が destroy or status 復元 + `leave_type_id` クリア → 集計から自動的に非計上（D2 の drift ゼロ）。`withdrawal_requested` は AR が残るため**計上される**（撤回承認前は効力継続・§7.6 と整合・承認 hot path 視点が裏取り）。
- **孤児 leave AR**（再 seed されない長命 dev・§1.1c）: `leave_type_id` NULL → paid 0・hours は status から算出。
- **60h 超・法定休日**: 不変（worked 集計のまま・§3.2）。
- **空の年月**（該当 summary/AR ゼロ）: ヘッダのみの CSV（BOM + ヘッダ行）。

### 7.2 テスト（`/gen-spec` 雛形・テナント文脈規約）

**3-3a**:
- migration（FK 複合・CHECK・index を増やさない確認）/ AR model validation（leave_type 整合）。CHECK 違反 example は `transaction(requires_new: true)` で DB RAISE 隔離（RAILS_GOTCHAS）。
- `ApplyApproval`（leave_type_id set）/ **`Withdraw`（destroy 分岐・`clock_in.present?` 戻し分岐で leave_type_id クリア＝半休打刻**と**clocked 済日への全休 stale** の両ケースをハードゲート・F3 Critical）。
- **mass-assignment guard**: `attendance_record[:leave_type_id]` を permit する controller が存在しないことの回帰 spec（多視点: セキュリティ/Low）。
- `LeaveAggregator`（paid vs unpaid・full/half・`standard_work_hours` 変動・snapshot 優先 vs effective fallback・未割当 0h・#104-stale on_leave 計上・撤回非計上）/ `Aggregate` 統合（既存 worked 集計の不変回帰）。

**3-3b**:
- `SummaryExporter`/`DailyDetailExporter`（BOM・CRLF・RFC 4180 quoting・**formula injection サニタイズ＝`=@+-`/TAB/CR 前置**・**NULL→空セル**・列順〔社員コード/氏名先頭〕・format・i18n ヘッダ）。
- request（`summary_csv` の scope 絞り＝manager は部下+自分のみ・hr_admin 全社・一般社員は自分 1 行・`year_month` 不正→400・`detail_csv` の 404 IDOR・**ストリーミング body 内のテナント文脈保持**）/ policy。

**完了条件**: 各 PR で `bundle exec rspec`・`bundle exec rubocop --force-exclusion`、app/ 変更ゆえ `bin/brakeman --no-pager`。3-3a は `tenant-isolation-reviewer` + `approval-engine-reviewer`、3-3b は `tenant-isolation-reviewer`（CSV・scope）、`/preflight` 後 PR。

---

## 付録: ROADMAP / SPEC / NOTES 反映

- 3-3a / 3-3b 各 PR で ROADMAP の Phase 3-3 行を更新（チェック + PR 番号）。両 PR マージで Phase 3 完了 → `/spec-check` で §6.4 含む乖離確認。
- **SPEC §6.4 追記（3-3b 同 PR・D11）**: 月次サマリ CSV 列に「社員コード・氏名」を明記（§6.4 列リストの穴を埋める）。
- **`LABOR_LAW_REVIEW_NOTES.md` 追記（3-3a・労務視点 Warning）**: 「月次サマリ CSV の休暇集計の給与連携前提」＝(1) `total_leave_hours` は全種別の時間合算・半休 `standard/2` 近似・未割当日 0h、(2) 有給は `paid_leave_days_used`（日・半 0.5）で別提供・時間内訳なし、(3) **`paid_leave_days_used` を §8.6（労基法 39 条 7 項）の 5 日取得義務充足判定に流用しない**（§8.6 は annual 限定・§8 充足は `LeaveBalance`(annual) source）。給与システムが日数ベース算定で時間内訳・近似・0h を許容するか社労士/PdM 確認。
- backlog の「Phase 3-1 の 35% 母数」「代休 LeaveBalance の繰越除外」等は本スライス範囲外（Phase 4）。CompanyCalendar destroy 制限（line 88）は D10 で後送り明記。
