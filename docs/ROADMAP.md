# 実装ロードマップ & タスク管理

> 進行管理の SSOT。仕様の正本は [SPEC.md](SPEC.md)（特に §15）であり、本書は「§15 を PR 単位のスライスに分解し、現在地を記録する」役割。仕様と齟齬があれば SPEC が優先。

## タスク管理の方法

- **管理単位 = スライス（1 スライス = 1 ブランチ = 1 PR）。** 縦に切る（モデル＋サービス＋UI＋spec が揃って初めて「動く」単位）。下表のチェックボックスと PR 番号が進捗記録のすべて
- **更新タイミング:** スライスの PR に本書の該当行更新（チェック + PR 番号）を含めてからマージする。別途の進捗管理ツール（Issues / Projects）は使わない（割り込み課題・バグのみ Issue 化してよい）
- **スライスの進め方（1 サイクル）:**
  1. brainstorm（`superpowers:brainstorming`）→ 設計判断が多いものは設計仕様を `docs/superpowers/specs/` に残す（Phase 0a と同形式・多視点レビュー `/multi-perspective-review` を通す）
  2. `superpowers:writing-plans` → `docs/superpowers/plans/` に実装計画
  3. 実装（TDD・spec 雛形は `/gen-spec`）→ `/preflight` → PR（squash マージ・CI 必須）
  4. 小さなスライス（CRUD 1 画面程度）は 1 を省略し plan から始めてよい
- **レビューの掛け方:** models / jobs / migration に触れたら `tenant-isolation-reviewer`、§8 関連（calculator・compliance・OrganizationSetting）に触れたら `labor-law-compliance-reviewer` + `/legal-citation-audit`。フェーズ完了時に `/spec-check` で SPEC との乖離を確認
- **凡例:** `[x]` マージ済み / `[ ]` 未着手。着手中はブランチが存在することで表現（中間状態を本書に書かない）

## フェーズとスライス

### Phase 0a — 基盤 ✅（PR: aff09bb 直 push 時代）

- [x] rails new・テナント解決（fail-closed）・Devise テナントスコープ・Pundit 強制・CI + required checks・seed 組織・最小ホーム

### Phase 0b — マスタ CRUD ✅

> 完了条件: hr_admin が画面から全マスタを整備でき、§16.7 のオンボーディング手順が seed + 画面で一周する

- [x] **0b-1 ユーザー管理**（PR #9）: 社員 CRUD（hr_admin 専用）・`role` / `manager_id` / `exempt_from_overtime` の変更 UI（Admin 名前空間限定の明示 permit — 設計 §0 で「専用アクション」方式を supersede）・招待メール（recoverable 転用・§16.7-3）
- [x] **0b-2 WorkPattern + LeaveType**（PR #12）: CRUD・法定休憩バリデーション（§4.4・労基法 34 条）・night_shift×flextime 警告 + i18n 日本語化・タブ active 修正・dev seed
- [x] **0b-3 CompanyCalendar**（PR #15）: CRUD・CSV 一括インポート（RFC 4180）・`CompanyCalendarResolver`（PORO・未登録日フォールバック §4.7）・legal_holiday 運用（一括生成 + 35% 保護 — 降格チェックボックス・0 件バナー・曜日必須選択）
- [x] **0b-4 UserWorkPattern**（PR #16）: 割当 CRUD（社員詳細ネスト）・期間重複バリデーション（§4.6・モデル検証 + exclusion constraint の二重防衛）・割当済み WorkPattern の無効化ガード（**ガード②同型の拒否で確定** — 0b-2 設計 §0 の宿題回収）・`Organization#today` TZ 契約・未割当バナー（E 原則準拠）
- [x] **0b-5 OrganizationSetting + ReasonTemplate**（PR #17）: 設定画面（v1 は closing_day / submit_deadline_days / fiscal_year_end_month の 3 項目・残カラムは消費 Phase 後送り）・テンプレート CRUD・**fiscal_year_end_month 変更は同一 tx で CompanyCalendar.fiscal_year 自動再計算に確定**（0b-3 設計 §0 の宿題回収・`Organization#setting` アクセサ規約）

### Phase 1 — 打刻と計算エンジン ✅

> 完了条件: 社員がブラウザから打刻し、退勤時に実労働・残業・深夜・遅刻早退が正しく保存される

- [x] **1-1 AttendanceRecord + 打刻**: 出退勤ボタン（Turbo）・パターンスナップショット・二重打刻防止（UI + サーバー）・社員ホームのヘッダー/カレンダー（§12.1 最小）（PR [#19](https://github.com/kei1110/Gatcha_on_RoR/pull/19)）
- [x] **1-2 計算オブジェクト 4 種**: WorkTime / Overtime / DeepNight / LateEarly（§5.1〜5.4・分単位整数 + HALF_UP・TZ 入力契約）。退勤・再計算時にサービスから保存（週 40h 週次算出は Phase 3 の集計で導入）（PR #23）
- [x] **1-3 AttendanceHistory + 代理打刻**: 追記専用モデル（3 段不変防御・fx トリガー/TRUNCATE 拒否・§4.14）・代理打刻（§6.1・本人バナー前倒し・通知本体は Phase 4）（PR #26）

### Phase 2 — 申請・承認（次はここ）

> 完了条件: 休暇・打刻変更・休日出勤が申請 → 2 段承認 → 副作用（記録更新・残高・履歴）まで一周し、撤回で復元できる

- [x] **2-1 承認エンジン core**: ApprovalAssignment・固定 2 段ルート解決（単段縮約）・自己承認防止 #1/#2/#3（§7.2〜7.3）・AASM 業務ステータス（#1）。対象非依存エンジンをテスト専用 approvable で検証。**後置**: 撤回（#4・2-5）／副作用・LeaveRequest（2-2）／delegate 基盤（§7.5）／Cancel サービス・Scope・承認 UI（2-2）。サービス/Approve/Reject はリクエスト文脈前提（ジョブ化時は `ActsAsTenant.with_tenant` ラップ必須・§8）
- [x] **2-2a LeaveRequest + LeaveBalance（申請側）**: 申請 UI（LeaveDaysCalculator §5.5・Estimate 単一ソース・残高 2 段階表示・サーバ往復 preview）・hr_admin 残高 CRUD・取消（`Approvals::Cancel`）・決算月ガード格上げ（残高ありで `fiscal_year_end_month` 変更禁止・社労士確認 #13）（PR [#6](https://github.com/kei1110/Gatcha_on_RoR/pull/6)）
- [x] **2-2b 承認 + 副作用**: 承認インボックス UI・`ApprovalAssignmentPolicy::Scope`・`approve` 副作用サービス（`LeaveRequests::ApplyApproval`＝残高 `lock!`加算/over-balance ハード拒否・AR upsert on_leave/半休・`LateEarly` 再計算・`AttendanceHistory(leave_approved)`）・月跨ぎ per-day 計上・年度跨ぎ start_date 統一・`AttendanceRecord.status` enum 拡張（PR [#7](https://github.com/kei1110/Gatcha_on_RoR/pull/7)）
- [x] **2-3 ClockChangeRequest**: 打刻変更申請（clock_in/clock_out/both）・`ClockChangeRequests::Create`（original_* snapshot）・`ApplyApproval`（§7.4 競合チェック→時刻更新→§5 再計算→前後値 `AttendanceHistory(clock_change_approved)`）・インボックス CCR 行（型別描画）・組織 TZ 入力 parse。**new_entry は absent 依存ゆえ 4-2 へ後置**（PR [#8](https://github.com/kei1110/Gatcha_on_RoR/pull/8)）
- [x] **2-4 HolidayWorkRequest**: 4 値ステータス・代休残高 +1（`LeaveType#balance_tracked?` で付与=消費を対称化）・is_holiday_work 双方向連動（承認=予約＋既存AR付与 / ClockIn・ProxyClockIn=事前付与）・承認時 work_date 平日性再検証（`ConflictError`）・代休限定（振替後置）（§6.11。35% は Phase 3 / 未打刻検出は Phase 4-2）（PR [#9](https://github.com/kei1110/Gatcha_on_RoR/pull/9)）
- [x] **2-5 撤回フロー**: `Withdrawable` concern 分離で撤回 state/event を LR/CCR 限定（HWR は `respond_to?(:request_withdrawal)` false の構造隔離・§4.12/§13.3）・`ApprovalAssignment.purpose` で承認/撤回世代分離（固定 2 段エンジン全面再利用）・`approve_withdrawal` で逆操作（残高 `balance_tracked?` 減算・leave-status AR 由来復元〔counted_dates 非再計算で drift 解消〕・CCR `original_*` 復元・`clock_change_withdrawn` 前後値履歴）・`reject_withdrawal` は副作用なし（§13.6 イベント束縛）・再撤回 v1 不可・締め月制限は前方フックのみ（MonthlyAttendanceSummary 不在ゆえ Phase 3-2）（§7.6・§13.6・多視点レビュー R1–R9 反映）（PR [#11](https://github.com/kei1110/Gatcha_on_RoR/pull/11)）

### Phase 3 — 月次締め

> 完了条件: 提出 → 確定 → 差戻しが状態機械で回り、給与システムへ渡せる CSV が出る

- [x] **3-1 MonthlyAttendanceSummary + 集計**: 締め期間（`closing_day` 基準）単位の集計エンジン — `AttendancePeriod` 値オブジェクト（D9・暦月ハードコード排・厳格 YYYY-MM 検証）＋ `WeeklyOvertimeCalculator`（週 40h 超を法定時間外へ §5.2・重複控除/法定休日/flextime 除外・per-week 丸め排で累積誤差回避）＋ `MonthlySummaries::Aggregate`（日次 legal OT ＋週次 extra の 2 系統集計の保存 §8.2・60h 超分離・出勤系 status ゲートで #104 stale 除外・`.calculated` で未計算行除外・冪等 upsert・防御テナントラップ・`day_types` 注入）。素材保存のみで判定はしない（コンプラは 4-x）。**提出時全件再集計のトリガ（状態機械・提出 UI）は 3-2 へ後置**（PR [#12](https://github.com/kei1110/Gatcha_on_RoR/pull/12)）
- [x] **3-2 締め状態機械 + 申請制限**: `MonthlyAttendanceSummary` AASM（§13.4・submit/finalize/defer の 3 event で 5 遷移・whiny_persistence・deferral_reason 必須）＋ 横断制限（`AttendancePeriod.containing` 逆写像 ＋ `MonthlySummaries::ClosingLock` 述語 ＋ `ClosingRestricted` concern で LR/CCR/HWR の新規作成を締め月で fail-closed・`Withdrawable` guard で LR/CCR 撤回を締め月で制限・§6.7）＋ 承認時の締め再チェック（`Approve#guard!` へ `ClosingLockedError < ConflictError` を単一チョークポイント注入＝全 3 型 fail-closed by construction・ガード spec で silent-gap 動的検出・§6.6）＋ 提出フロー（`Submit`＝提出前チェック`PendingRequests`→全件再集計→submit! の 1 tx・`Finalize`/`Defer`・D7 で確定後の再集計を構造排除）＋ Policy（本人/hr_admin=提出・直属 manager/hr_admin=確定/差戻し・Scope）＋ 最小 UI ＋ 一括確定（**初の SolidQueue**＝`BulkFinalizeJob`・dev 専用 queue DB / test=:test 配線・with_tenant ラップ・冪等・per-record `finalize?` 交差で IDOR/self-finalize 防御）。**mass-assignment 締め出し・同一 org 内 IDOR は多視点レビュー(5視点)で検出し是正**（PR [#13](https://github.com/kei1110/Gatcha_on_RoR/pull/13)）
- [x] **3-3 CSV 2 種**: 月次サマリ・日別明細（UTF-8 BOM・割増区分網羅・§6.4）。**3-3a 休暇集計の素材整備** done（AR `leave_type_id`＝複合 FK+CHECK・`ApplyApproval` set/`Withdraw` clear〔F3 撤回永久失敗を構造封鎖〕・`MonthlySummaries::LeaveAggregator`〔snapshot 優先・全種別 hours・paid 日数・period.range 直読で drift ゼロ〕・MAS 2 列。多視点 6 視点＋tenant-isolation/approval-engine レビュー clean）（PR [#16](https://github.com/kei1110/Gatcha_on_RoR/pull/16)）／**3-3b CSV 出力** done（`Csv::Row`〔BOM/CRLF/RFC4180＋型駆動整形＋formula-injection 無害化〕・`SummaryExporter`/`DailyDetailExporter`・社員識別子列・NULL 未引用空セル・AR status i18n・`policy_scope` 起点 streaming〔`.to_a` 事前確定でテナント安全・Turbo `data:turbo:false`〕・SPEC §6.4 穴埋め。whole-branch＋tenant-isolation レビュー clean）（PR [#18](https://github.com/kei1110/Gatcha_on_RoR/pull/18)）。**Phase 3（月次締め）完了**

### Phase 4 — コンプライアンス・通知

> 完了条件: バッチが毎日回り、§8 の全監視が legal 基準・テナント別子ジョブで動く。`labor-law-compliance-reviewer` の重点フェーズ

- [ ] **4-1 通知基盤**: Notification / NotificationDelivery・抑制（quiet hours / 休日）・二重 opt-in（`User.email_enabled` migration はここで追加 — 0a からの明示的後送り）・ディスパッチャ→子ジョブのテナント反復パターン確立（§3.6・§10）
- [ ] **4-2 日次バッチ**: 打刻漏れ検知（§6.8）・欠勤候補 → 欠勤確定フロー（§6.10）・勤務間インターバル（出勤打刻時判定 + 記録 §6.9）・Phase 1〜2 の保留通知（代理打刻・承認/却下）接続
- [ ] **4-3 36 協定 + 60h + 産業医 + 有給 5 日**: ComplianceService 群（法定値は定数・2 系統集計・管理監督者分岐 §8.1〜8.3, 8.6〜8.7）・退勤時即時アラート・週次/月次バッチ・段階通知
- [ ] **4-4 連続勤務 + HWR 未打刻 + 繰越**: §8.5・§6.11 後段・年度更新（繰越上限）・滞留アラート（§7.5）

### Phase 5 — 管理・監査

> 完了条件: 管理者が日次/週次/月次の運用をダッシュボードで完結でき、監査証跡が労基署対応水準

- [ ] **5-1 管理ダッシュボード**: 3 セクション統合（緊急/重要/管理・§12.2）・36 協定管理タブ・是正チェックリスト（§8.2）
- [ ] **5-2 監査・保持の仕上げ**: AttendanceHistory の保持方針確認（アーカイブ実装は v1 不要 §11.4）・§14 after_commit 継ぎ目の文書化・`/spec-check` 全域
- [ ] **5-3 運用整備（§16・デプロイ先決定後）**: Sentry 接続・PITR/バックアップ設定・復旧手順書・**テナント開設手順書（§16.7 の console 実行例の成文化 — 0b 完了時 spec-check の推奨）**・recurring 死活監視・Kamal/Thruster 再導入判断

### 横断バックログ（スライス外の小タスク・発見時にここへ追記）

- [x] **エラーメッセージの i18n**: default locale が `:en` のため `:manager_id` 系の full_messages が「Manager は循環しています」と英日混在（0b-1 レビューで検出）。ja.yml + `default_locale` の方針判断が要る — 0b の早期に（0b-2・PR #12 で回収）
- [x] **Admin タブの active 表示**: `current_page?` は完全一致のため show/edit ページでタブのハイライトが外れる。0b-2 でタブが増えると顕在化 — `request.path.start_with?` 等へ（app/components/admin/nav_component.html.erb）（0b-2・PR #12 で回収）
- [ ] **マスタのインライン編集（SPEC §12.3）**: 0b-2 はページ遷移型 edit で機能要件を充足。Turbo 化は UX 改善として後送り
- [ ] **デザインシステム整備**: 現状 UI は各スライスに「最小」で同梱（機能優先・意匠は未スコープ）。Tailwind v4 + ViewComponent を土台に、(a) デザイントークン（配色・タイポ・余白スケール）の規約化、(b) 共通 ViewComponent（ボタン・フォーム・テーブル・バッジ・カード・ナビ）の抽出・統一、(c) アクセシビリティ（コントラスト・フォーカス・ARIA）、(d) レスポンシブ/モバイル（§12.4）の基線。どの Phase でも引ける横断土台。**着手は Phase 2（申請 UI）前を推奨**（画面数が増える前に土台を整えると後戻りが少ない・ただし強制ではなく必要時に引く）。`frontend-design` スキルで試作 → 規約を docs 化。社員向け（§12.1）と管理（§12.3）でトーンを分けるか要判断
- [ ] **実労働ベースの法定休憩再判定**: マスタ検証は必要条件のみ（所定 8h・休憩 45 分は残業 1 分で 60 分不足）。Phase 1/4 の事後アラートとして検討（打刻ブロック不可・社労士確認 #8）
- [ ] **LeaveType の annual×paid_leave 整合警告**: §8.6 の有給 5 日義務判定への影響。Phase 4 着手時に再検討
- [ ] **production のエラーページ**: RecordNotFound 等が plain text 応答（0b-1 で controller 層 404 化した際の暫定）。Phase 5 の管理 UI 仕上げで専用ページへ
- [ ] **Mutant のスコープ限定導入**: 計算オブジェクト（§5）・ComplianceService（§8）は「テストが緑でも法定値とズレたら重大事故」の純粋ロジックで、ミューテーションテストの費用対効果が最大。Phase 1-2 完了後に `app/calculators` 配下のみで導入を検討し、Phase 4-3 で対象を拡大（全体適用はしない）。mbj/mutant はライセンス形態が変遷した歴史があるため導入時点で商用利用条件を要確認（出典: [TechRacho 2026-06-10](https://techracho.bpsinc.jp/hachi8833/2026_06_10/158257)）
- [ ] **legal_holiday カバレッジ失効の事前アラート**: 一括生成（上限 2 年）の期間満了後、未登録日曜が Resolver フォールバックで sunday に降格し 35% 側が静かに失われる。index の 0 件バナー（0b-3）が第一歩 — 残り N 日での管理者通知は Phase 4-1 の通知基盤接続後（労務レビュー高・社労士確認 #11）。**失効時フォールバックは曜日（sunday）降格でなく「要確認」状態へ**（原典再照合 2026-06-13・平成 6.1.4 基発 1 号＝暦週内の「最後の休日」を法定休日と推認・SPEC §4.7 反映済）
- [ ] **締め済み月の CompanyCalendar destroy 制限**: 過去日の削除は Phase 1 再集計時の day_type 根拠（legal_holiday の 35%・60h 除外）を遡及的に書き換える。締め状態機械の導入（Phase 3-2）に合わせて制限を課す
- [ ] **夜勤継続中のカレンダー前日セル表示**: classify の `stale_working` は window 内の現役夜勤行（勤務継続中）も退勤済と同色に巻き込む（1-1 品質レビュー観察・実害なし）。Phase 2-3 で打刻変更申請の導線をセルに付ける際、「勤務中の前日セル」を独立分類に分けるか再訪
- [ ] **代理退勤バナーの夜勤エッジ**: `ProxyClockOut` は `working_within((today-1)..today)` で対象を取るため夜勤は `work_date = today-1` 行が対象になり得るが、ホームのバナー解決は `@state.today_record`（= `find_by(work_date: today)` 厳密一致・`app/controllers/home_controller.rb:19`）ゆえ前日 work_date 行への代理**退勤**がバナーに出ない（Phase 1 spec-check 検出・実コード裏取り済）。代理退勤そのもの（record 更新・AttendanceHistory 監査証跡）は正常で、欠けるのは表示のみ。バナーは Phase 1 前倒しの暫定 → **Phase 4-1 通知基盤で恒久解決（暫定バナーを置換）**。早期に直すなら home_controller のバナー解決を working/window ベースへ
- [ ] **社員一覧の未割当バッジ + 期限切れ先読み**: 0b-4 は社員詳細バナーのみ（述語 = `effective_on`）。一覧バッジは Phase 1 の打刻導線で実害が出てから、「N 日以内に割当終了 + 後継なし」の先読み通知は Phase 4-1 の通知基盤接続後（0b-4 労務レビュー）
- [ ] **割当隙間日の遡及補正**: 無割当期間に打たれた打刻は `work_pattern_id` NULL で計算スキップ（§5.4）になるが、§4.8 の不遡及原則により後追い割当でも補正されない。Phase 1 の打刻設計で「NULL レコード限定の遡及スナップショット + 再計算」の例外を判断（労務レビュー High・社労士確認 #12-(a)）
- [ ] **割当変更履歴**: 過去に食い込む日付編集が監査証跡ゼロで可能（労基法 109 条の趣旨・社労士確認 #12-(b)）。Phase 1-3 AttendanceHistory 設計時に同棲で判断 — 履歴機構を二系統作らない（0b-4 設計 §0）
- [ ] **fiscal_year_end_month の変更禁止への格上げ**: 0b-5 は CompanyCalendar の自動再計算で出荷。**Phase 2-2（LeaveBalance）着手時に「残高が存在したら変更禁止」へ格上げを再判断**（0b-5 設計 §0・社労士確認 #13）
- [ ] **organization_settings 残カラムの追加様式**: 消費する Phase の PR が検証・既定値・意味論ごと同梱（4-1 email_enabled 方式）。36 協定系 4 カラムは Phase 4-3 で法定定数モジュールと同一 PR — 参考閾値 ≤ 法定の検証 + DB CHECK + `alert_` リネーム + 「ComplianceService が本テーブルを読まない」ガード spec の重装備セット（0b-5 労務レビュー High）
- [x] **社労士チェックリストの原典再照合 + SPEC 反映**（PR #24）: ChatGPT deep-research 報告を `jp-labor-evidence` MCP で原典再照合し、確定分を SPEC §8 前文 / §8.2 / §8.6 / §8.7 / §4.7 / §4.4 / §6.11 へ反映（罰則 119/120 分離・年休 5 日の二層管理＝新規付与基準・法定休日「要確認」化・産業医面談「疲労蓄積」要件・振替休日の事前特定必須）。報告書を `docs/LABOR_LAW_REVIEW_REPORT.md` へ取り込み・台帳に再照合結果表(#1〜12)追加。本バックログ #81(実労働休憩・#8)/ 上記 legal_holiday(#11)/ #89・#90(#12) の判定根拠を更新。残・別途確認（政令 35% 本文数値・判例・古い通達原文）は台帳に列挙（原典再照合 2026-06-13）
- [ ] **本番 attendance_histories の owner 分離**: 不変トリガー（`_v01`）は table owner / superuser をバイパスできる。本番でマイグレーション実行ロールと app 接続ロールを分離し、**app ロール ≠ owner** にして初めて層③が攻撃者からも守られる。Phase 5-3（運用ハードニング）で接続ロール分離を入れる（1-3 で脅威モデルとして記録・§4.14）
- [ ] **§11.2 匿名化 vs 不変トリガー**: 5 年経過後の匿名化／削除（§11.2）は、追記専用トリガーが UPDATE/DELETE を拒否するため通常経路では実行不能。トリガーを **`_v01` 版差し替え方式**（バージョン付き SQL ファイル・現行は `attendance_histories_no_mutate_v01.sql` 等）で「制御付きバイパス（保持期間管理ジョブのみ許可）」へ更新する設計を、アーカイブ実装（§11.1・v1 は YAGNI）と同時に判断する
- [x] **Ruby 4.0.2 アップグレード**（PR #27）: 3.3.11 → 4.0.2 直行（Rails 8.1.3 据え置き＝既に 8.1 native）。実機検証で全 CI ゲート green を確認（rspec 523/0・rubocop・brakeman・C 拡張 4.0 ABI ロード可）後にスライス化。bundler 4.0.14・`gem "cgi"` 予防追加・frozen_string_literal 一括付与（計 181 ファイル）を同梱。YJIT 有効化・4.0.5 追従は別 PR。設計 `docs/superpowers/specs/2026-06-14-ruby-4-0-2-upgrade-design.md`
- [x] **YJIT 有効化（調査の結果 Rails 8.1 既定で production 有効・実装不要）**（PR #28）: `config.load_defaults 8.1` が `config.yjit` を production のみ true に設定し boot で `RubyVM::YJIT.enable`。Ruby 4.0.2 も `+YJIT` 同梱。dev/test は OFF（正）。明示 `config.yjit = true` は omakase に反し drift 源ゆえ追加せず。別 PR の実装対象なし（docs のみ・GOTCHAS「Ruby / ツールチェーン」に記録）
- [x] **PostgreSQL 17→18 アップグレード**（PR #3）: ローカル開発機を 17.10→18.4。dev/test はクリーン再生成（data dir 非移行）・17 は完全退場。pg gem は libpq 自前同梱で再ビルド不要（`otool` 実測）・exclusion-constraint 罠 152 は PG18.4 でも不変。新発見の fx トリガー dump 順非決定性を `config/initializers/fx_trigger_dump_order_fix.rb` で決定化。rspec 589/0 緑（退場後も）。CI image を `postgres:18` へ。設計 `docs/superpowers/specs/2026-06-16-postgres-18-upgrade-design.md`
- [ ] **汎用インボックスの polymorphic preload を型非依存化**: `ApprovalAssignmentsController#index` は表示 N+1 回避のための nested preload を入れられない（approvable 型混在で `leave_type` 等を CCR に探し `AssociationNotFoundError`）。現状 `includes(:approvable)` で N+1 は §16.1 許容。2-3 で ClockChangeRequest が approvable に加わる前に型別 conditional preload を導入（2-2b 最終レビュー I-1）
- [ ] **半休日への後続打刻連携（§13.1 `morning_half → morning_half`）**: 先に半休休暇が承認され半休 status の AR が存在する日に、本人が残り半日を打刻する経路が未対応（`Clockings::ClockIn` は `(user, work_date)` unique index に衝突し得る）。2-2b は leave 承認が AR を作る側に集中し本連携を退避（2-2b 設計 D5）。`ClockIn` を「既存 AR があれば status を壊さず clock_in を埋める upsert」へ改修する Phase 1 clocking PR で回収
- [ ] **clocked 済 AR への全休承認で計算列が stale**: 既に出退勤打刻済（clocked_out・計算 8 列 non-NULL）の日に全休が承認されると、status は on_leave に上書きされるが `on_leave?` 早期 return で再計算されず clock_in/clock_out・計算 8 列が stale のまま残り、下流集計を誤らせ得る（§13.1 非掲載の運用上想定外ケース）。2-2b 設計 §1.5 / §8 handoff #2 で既知。打刻済日への全休は競合検出（却下推奨）or 計算列クリアの要否を後続スライスで判断
- [ ] **振替休日（substitute_holiday）の実装**: 振替元休日・振替先労働日の事前特定モデリング（HWR にカラム追加 or 別テーブル）＋ 35% 抑制根拠完備＋ `balance_tracked?` への substitute_holiday 追加可否（振替は日付 swap で割増免除＝残高に乗らない可能性）を再判断。2-4 は代休限定で出荷（D3・§6.11 事前特定ノート）。`LeaveType` の `system_type=substitute_holiday && paid_leave=true` 禁止検証も同スライスで（Codex C3）
- [ ] **HWR 承認↔打刻 write-skew の整合バッチ**: 承認 tx（未コミット）と ClockIn tx の競合で `is_holiday_work` が false 確定し得る（balance ロックは承認同士のみ直列化・ClockIn は balance を lock しない）。Phase 4-2 で「approved HWR × 当日 AR あり × is_holiday_work=false」を未打刻検出と同じ走査で補正（2-4 設計 §2.2③・Codex C1）。**finalize 前ゲート**
- [ ] **代休の事前消費ハザード**: HWR 承認で代休 +1 → 実勤務前/未打刻で LeaveRequest 消費 → 未打刻なら Phase 4-2 取消（granted −1）で remaining 負になり得る。over-balance は付与超は防ぐが勤務前消費は防がない。Phase 4-2 の取消フローで「消費済代休の負残高/差戻し」を扱う＋**社労士確認**（実労働なき代償休暇付与・先取り消費の可否）。**finalize 前ゲート**（2-4 Codex C4・§6.11 L851）
- [ ] **Phase 3-1 の 35% 母数**: `holiday_work_hours`（35%）の母数は `is_holiday_work` 単独でなく **`is_holiday_work AND day_type==legal_holiday`** で確定（所定休日労働は対象外・§8.1）。legal_holiday 登録漏れの未登録日曜が resolver フォールバックで `:sunday` 降格し漏れる点は §4.7「要確認」と整合（2-4 R4/Codex C5・既存「legal_holiday カバレッジ失効」と同根）
- [ ] **代休 LeaveBalance の繰越除外**: `balance_tracked?` 拡張で代休も used_days/over-balance 対象になるが、年度繰越ジョブ（Phase 4-4・§4.10）のフィルタを `paid_annual?` に限定し代休を含めない（代休に carry_over は不適切・2-4 R8）
- [ ] **holiday-work の AttendanceHistory イベント / 遡及付与の証跡**: 事後申請で打刻済 AR に遡及で is_holiday_work=true を立てる経路は AttendanceHistory に残らず、証跡は HWR.approval_status + ApprovalAssignment に依存。労基法 109 条の証跡要件を満たすか社労士確認・§4.14 taxonomy 末尾に `holiday_work_approved` 追加を Phase 3/4 で再判断（2-4 D5・LABOR_LAW_REVIEW_NOTES #17 追記案）
- [ ] **承認インボックスの ConflictError flash を型別に**: `ApprovalAssignmentsController` の `rescue Approvals::ConflictError` は CCR 由来の「変更前時刻が現在の記録と一致しません」固定文言。HWR の D4 平日化 ConflictError でこの打刻時刻向け文言が出て意味がずれる（rollback は正・fail-closed・cosmetic）。汎用文言化（「申請の前提条件が変わりました」）or approvable_type 別分岐へ。2-4 設計が flash 流用を明示受容ゆえ後送り（2-4 最終レビュー M1・未テスト path ゆえ request spec も同時に）。**3-2 で締め由来 `ClosingLockedError < ConflictError` の専用文言分岐は追加済**（残るは CCR↔HWR の文言区別）
- [ ] **締め提出（Submit）の TOCTOU 窓**: `MonthlySummaries::Submit` は `PendingRequests` チェックと `submit!` の間を `ActiveRecord::Base.transaction`（行ロックなし・READ COMMITTED）で囲むため、チェック後・コミット前に新規 LR/CCR/HWR が `aggregating` 状態の MAS を見て `on:create` 制限を通過し残留し得る。残留申請は承認時 `Approve#guard!`（`closing_locked?`）で fail-closed にブロックされる＝**「締め済み AR が裏で書き換わる」安全不変条件は保持**。実害は申請者/承認者が stuck（管理者の `defer` で解消）に留まる。完全封鎖は summary 行の `with_lock`（`find_or_create` で先作り）化＝設計変更ゆえ後続で判断（単一ユーザ操作の同時性ゆえ実害リスク低・3-2 approval-engine レビュー W1）
- [ ] **LeaveRequest.last_stale_notified_on の未実装（CCR との非対称）**: SPEC §4.9 は LeaveRequest に `last_stale_notified_on`（滞留アラート重複防止）を記載するが、schema には ClockChangeRequest 側（§4.11）にしか無い。消費（滞留アラート §7.5・§9）は Phase 4-1 通知基盤ゆえ現時点で実害なしだが、**Phase 4-1 で LeaveRequest 側に migration 追加**して非対称を解消する（Phase 3 spec-check 検出・データモデル観点）
- [x] **Phase 2〜3 機能の動線整備（最小グローバルナビ）**: Phase 0a〜3 で実装した機能画面（休暇申請・打刻変更・休日出勤・承認インボックス・月次サマリ/CSV・管理マスタ）が、唯一のランディング（root=home）から**クリック到達不能**（layout にナビ無し・各 path は自ディレクトリ外から参照ゼロ＝URL 直打ち専用）だった。`Admin::NavComponent` 同型の `GlobalNavComponent`（role 出し分け＝申請系は全員/承認・代理打刻は manager\|hr_admin/管理は hr_admin）を layout に常設し home の重複ヘッダを解消（A1）・**CCR index に「新規申請」リンク**追加（A2・LR/HWR と対称）・**残高 CRUD を `users/show` にネスト表示**（A3・`_work_pattern_assignments` 同型・policy_scope 由来 @user 経由でテナント安全）・`home/_clocking.html.erb` の陳腐化文言を実リンク化（A4）。ナビ全画面常設で誤発火した既存 2 spec をナビ非依存へ調整。tenant-isolation レビュー clean（Phase 3 spec-check ユーザーストーリー観点・PR [#20](https://github.com/kei1110/Gatcha_on_RoR/pull/20)）

## 横断ルール（順序の根拠）

- **AttendanceHistory は §15 では Phase 5 だが、書き込み側は Phase 1 の代理打刻から始まる**ため、モデルと不変防御は 1-3 で前倒しする（Phase 2 の承認副作用が依存）
- 0b-2/0b-3/0b-4 は Phase 1 の前提（打刻はパターンとカレンダーが無いと計算できない）。0b-1 は Phase 2 の前提（承認ルートは `manager_id` 階層）
- 通知に触れる機能（代理打刻・承認・検知）は **Phase 4-1 まで通知送信を持たない**。「通知を送る」コードを書く場所を 1 箇所に集めるための意図的な後送り
- 各フェーズ完了時: `/spec-check` → 乖離があれば SPEC 改訂 or 追補スライスを本書に追加
- 動線到達性の SSOT は **SPEC §1.4**（ユーザーストーリー動線マップ）。各スライスは自分の行を追加・更新し、フェーズ完了時の `/spec-check` が §1.4 を基準に照合する（Phase 3 spec-check で動線断絶を検出した再発防止策）
