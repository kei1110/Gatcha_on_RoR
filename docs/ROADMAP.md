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

### Phase 0b — マスタ CRUD（次はここ）

> 完了条件: hr_admin が画面から全マスタを整備でき、§16.7 のオンボーディング手順が seed + 画面で一周する

- [x] **0b-1 ユーザー管理**（PR #9）: 社員 CRUD（hr_admin 専用）・`role` / `manager_id` / `exempt_from_overtime` の変更 UI（Admin 名前空間限定の明示 permit — 設計 §0 で「専用アクション」方式を supersede）・招待メール（recoverable 転用・§16.7-3）
- [ ] **0b-2 WorkPattern + LeaveType**: CRUD・法定休憩バリデーション（§4.4・労基法 34 条）・night_shift×flextime 警告
- [ ] **0b-3 CompanyCalendar**: CRUD・CSV 一括インポート（RFC 4180）・`CompanyCalendarResolver`（PORO・未登録日フォールバック §4.7）・legal_holiday 運用
- [ ] **0b-4 UserWorkPattern**: 割当 CRUD・期間重複バリデーション（§4.6）
- [ ] **0b-5 OrganizationSetting + ReasonTemplate**: 設定画面（v1 は項目を絞る・§4.15 YAGNI 注記）・テンプレート CRUD

### Phase 1 — 打刻と計算エンジン

> 完了条件: 社員がブラウザから打刻し、退勤時に実労働・残業・深夜・遅刻早退が正しく保存される

- [ ] **1-1 AttendanceRecord + 打刻**: 出退勤ボタン（Turbo）・パターンスナップショット・二重打刻防止（UI + サーバー）・社員ホームのヘッダー/カレンダー（§12.1 最小）
- [ ] **1-2 計算オブジェクト 4 種**: WorkTime / Overtime / DeepNight / LateEarly（§5.1〜5.4・分単位整数 + HALF_UP・TZ 入力契約）。退勤・再計算時にサービスから保存（週 40h 週次算出は Phase 3 の集計で導入）
- [ ] **1-3 AttendanceHistory + 代理打刻**: 追記専用モデル（3 段不変防御・DB トリガー/REVOKE 含む・§4.14）・代理打刻（§6.1。対象者通知は Phase 4 で接続、まず note 追記と履歴記録まで）

### Phase 2 — 申請・承認

> 完了条件: 休暇・打刻変更・休日出勤が申請 → 2 段承認 → 副作用（記録更新・残高・履歴）まで一周し、撤回で復元できる

- [ ] **2-1 承認エンジン core**: ApprovalAssignment・固定 2 段ルート解決（単段縮約）・自己承認防止 4 種（§7.2〜7.3）・AASM 業務ステータス
- [ ] **2-2 LeaveRequest + LeaveBalance**: 申請 UI（LeaveDaysCalculator §5.5・残高 2 段階表示）・承認副作用サービス（`lock!`・AR 更新・履歴）・月跨ぎ/年度跨ぎ（§6.2）
- [ ] **2-3 ClockChangeRequest**: 競合チェック（§7.4）・new_entry・再計算接続
- [ ] **2-4 HolidayWorkRequest**: 4 値ステータス・代休残高 +1・is_holiday_work 連動（§6.11。未打刻検出は Phase 4）
- [ ] **2-5 撤回フロー**: withdrawal_requested（承認イベント未定義）・履歴参照復元・イベント単位副作用（§7.6・§13.6）

### Phase 3 — 月次締め

> 完了条件: 提出 → 確定 → 差戻しが状態機械で回り、給与システムへ渡せる CSV が出る

- [ ] **3-1 MonthlyAttendanceSummary + 集計**: MonthlySummaryService（提出時全件再集計・週 40h 超の法定時間外 §5.2・2 系統集計の保存 §8.2）
- [ ] **3-2 締め状態機械 + 申請制限**: AASM（§13.4）・§6.7 の横断バリデーション・承認時の締め再チェック・一括確定ジョブ（初の SolidQueue 利用 → dev 用 Active Job 設定もここで）
- [ ] **3-3 CSV 2 種**: 月次サマリ・日別明細（UTF-8 BOM・割増区分網羅・§6.4）

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
- [ ] **5-3 運用整備（§16・デプロイ先決定後）**: Sentry 接続・PITR/バックアップ設定・復旧手順書・recurring 死活監視・Kamal/Thruster 再導入判断

## 横断ルール（順序の根拠）

- **AttendanceHistory は §15 では Phase 5 だが、書き込み側は Phase 1 の代理打刻から始まる**ため、モデルと不変防御は 1-3 で前倒しする（Phase 2 の承認副作用が依存）
- 0b-2/0b-3/0b-4 は Phase 1 の前提（打刻はパターンとカレンダーが無いと計算できない）。0b-1 は Phase 2 の前提（承認ルートは `manager_id` 階層）
- 通知に触れる機能（代理打刻・承認・検知）は **Phase 4-1 まで通知送信を持たない**。「通知を送る」コードを書く場所を 1 箇所に集めるための意図的な後送り
- 各フェーズ完了時: `/spec-check` → 乖離があれば SPEC 改訂 or 追補スライスを本書に追加
