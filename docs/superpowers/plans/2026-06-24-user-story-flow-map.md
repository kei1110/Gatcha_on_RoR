# ユーザーストーリー動線マップ（SPEC §1.4）+ 到達性 DoD 昇格 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 3 spec-check の第5観点（動線到達性）を、SPEC §1.4 動線マップ（既存網羅＋状態列）と DoD/spec-check への組み込みとして恒久化する。

**Architecture:** docs + skill のみ（コード変更なし）。SPEC §1.4 に「アクター目的 × 起点(route+nav)」のハイブリッド薄型表を新設し、DEVELOPMENT_WORKFLOW の DoD・`/spec-check` skill・ROADMAP 横断ルールから §1.4 を到達性 SSOT として参照する。

**Tech Stack:** Markdown（docs/SPEC.md・docs/DEVELOPMENT_WORKFLOW.md・docs/ROADMAP.md）+ skill（.claude/skills/spec-check/SKILL.md）。

## Global Constraints

- 設計 SSOT: `docs/superpowers/specs/2026-06-24-user-story-flow-map-design.md`（本計画はその転記）。
- commit identity = kei1110 `<eoh2145@gmail.com>`。commit message 末尾に `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。
- **コード変更ゼロ**（docs + skill md のみ）。`db/schema.rb`/`Gemfile.lock` 不触。docs-only ゆえ `/preflight`・rspec 対象外。
- drift 防止: §1.4 は SPEC 同居の SSOT。別ファイル化・Phase 4-5 スタブ行・独立バックログは作らない（YAGNI）。
- 「テスト」= markdown 構文健全性 + 内容存在 + §1.4 の起点 route が `config/routes.rb` に実在することの grep 照合。

---

### Task 1: SPEC §1.4 ユーザーストーリー動線マップ 新設

**Files:**
- Modify: `docs/SPEC.md`（§1.3 本質的価値の末尾 `---` の直前に §1.4 を挿入・改訂履歴に 1 行追記）

**Interfaces:**
- Produces: SPEC §1.4（後続 Task 2/3 が「到達性 SSOT」として参照する節）。

- [ ] **Step 1: 起点 route が実在することを事前照合（§1.4 の正しさの裏取り）**

Run:
```bash
cd /Users/Eoh/workspace/Gatcha_on_RoR
grep -nE 'leave_requests|clock_change_requests|holiday_work_requests|approval_assignments|monthly_attendance_summaries|proxy_clockings|admin' config/routes.rb | head
```
Expected: 上記 resources が全て定義済み（§1.4 の `起点 route` 列が実在）。`new_clock_change_request`・`admin_user_leave_balance` 系・`summary_csv`/`detail_csv` も routes.rb にあること（PR #20 マージ済 main 前提）。

- [ ] **Step 2: §1.4 を §1.3 の `---` 直前に挿入**

`docs/SPEC.md` の §1.3 末尾、以下の箇所を差し替える（`- **完全な監査証跡:** …5 年保持義務に対応` の後・`---` の前に §1.4 を挿入）:

挿入後の形（`### 1.3 …` 配下の最後の bullet の直後）:

```markdown
- **完全な監査証跡:** 追記専用ログ（`AttendanceHistory`）で任意時点の勤怠状態を再現可能。労基署調査・5 年保持義務に対応

### 1.4 ユーザーストーリー動線マップ

「機能が存在するか」ではなく「**アクターが目的を端から端まで達成できる動線（起点 route + nav 入口）が通っているか**」の SSOT。技術仕様（§4 データモデル／§5 計算）が捉えない「到達性」を一覧で検証する。各機能スライスは本表に自分の行を追加・更新してからマージする（DoD・§15／DEVELOPMENT_WORKFLOW）。

**状態凡例**: ✅ 端から端まで到達可能 ／ ⚠️ 部分（導線はあるが表示等に欠け） ／ — Phase 4+ 予定（行は実装スライスで追加）

| アクター | 目的（〜したい） | 起点 route | nav 入口 | 結果（副作用） | 状態 | §ref |
|---|---|---|---|---|:--:|---|
| 社員 | 出退勤を打刻し当日の状態を見たい | `/`（home） | ナビ「ホーム」/ 打刻ボタン | AR clock_in/out・計算 8 列 | ⚠️ | §6.1/§12.1 |
| 社員 | 休暇を申請し残高を見て反映させたい | `/leave_requests/new` | ナビ「休暇申請」 | 承認後 AR on_leave/半休・残高消費 | ✅ | §6.2 |
| 社員 | 打刻ミスを打刻変更申請で直したい | `/clock_change_requests/new` | ナビ「打刻変更」+ ホーム注記 | 承認後 時刻更新・§5 再計算 | ✅ | §6.3 |
| 社員 | 休日出勤を申請し代休を得たい | `/holiday_work_requests/new` | ナビ「休日出勤」 | 承認後 is_holiday_work・代休 +1 | ✅ | §6.11 |
| 社員 | 承認済み申請を撤回したい | 各 index 行内フォーム | ナビ「休暇申請」「打刻変更」 | 逆操作（残高/記録復元） | ✅ | §7.6 |
| 社員 | 自分の月次サマリを提出したい | `/monthly_attendance_summaries/:id` | ナビ「月次サマリ」→ 詳細 | submit 遷移 | ✅ | §6.6 |
| 管理者 | 申請を承認/却下したい | `/approval_assignments` | ナビ「承認」 | AASM 遷移 + 副作用 | ✅ | §7 |
| 管理者 | 部下の締めを確定/差戻ししたい | `/monthly_attendance_summaries/:id` | ナビ「月次サマリ」→ 詳細 | finalize/defer | ✅ | §6.6 |
| 管理者 | 月次サマリを一括確定したい | `/monthly_attendance_summaries`（bulk_finalize） | ナビ「月次サマリ」→ 一括 | BulkFinalizeJob（冪等） | ✅ | §6.6 |
| 管理者 | 代理打刻したい | `/proxy_clockings` | ナビ「代理打刻」 | 代理 AR・AttendanceHistory | ✅ | §6.1 |
| hr_admin | 各マスタを整備したい | `/admin/*` | ナビ「管理」→ 各タブ | マスタ CRUD | ✅ | §0b/§12.3 |
| hr_admin | パターン割当・残高を付与/編集したい | `/admin/users/:id`（nested） | 管理 → 社員 → 割当/残高 | UserWorkPattern/LeaveBalance CRUD | ✅ | §4.6/§4.10 |
| 給与担当 | 月次/日別 CSV を DL したい | `/monthly_attendance_summaries`（`summary_csv`/`detail_csv`） | ナビ「月次サマリ」→ DL | UTF-8 BOM CSV 出力 | ✅ | §6.4 |

> **アクター注**: 「給与担当」は専用ロールでなく、CSV を扱う hr_admin・manager の通称。
> **既知の部分断絶（⚠️）**: 社員ホームは打刻状態とカレンダー色のみで、§12.1 が想定する「当日の実労働/残業の数値」「申請ステータス・休暇残高サマリ」が未描画（1-1 最小出荷の残り）。Phase 4-1 通知基盤・ホーム拡充で解消予定。
> **不変条件**: `状態` が `✅` の行は「起点 route が実在し、nav 入口（または明示された画面内導線）からクリック到達でき、結果まで一周する」こと。空の `起点 route`／欠落 `nav 入口` は未検出の断絶の疑い＝レビュー指摘対象。

---

## 2. アーキテクチャ
```

> 注意: 挿入は `### 1.3 …` の最後の bullet と、その後の `---`／`## 2. アーキテクチャ` の間。`---` 区切りは §1.4 の後（= §2 の前）に残す。

- [ ] **Step 3: 改訂履歴に 1 行追記**

`docs/SPEC.md` 末尾「## 改訂履歴」テーブルの**最終行の後**に追記（既存最終行を読んでその直後へ）:

```markdown
| 2026-06-24 | §1.4 ユーザーストーリー動線マップ新設（アクター目的 × 起点 route+nav・状態列）。Phase 3 spec-check の動線到達性観点を SSOT 化（PR #19/#20 で是正した動線断絶の再発防止）。設計 `docs/superpowers/specs/2026-06-24-user-story-flow-map-design.md` |
```

- [ ] **Step 4: 構文・内容を検証**

Run:
```bash
cd /Users/Eoh/workspace/Gatcha_on_RoR
grep -n '### 1.4 ユーザーストーリー動線マップ' docs/SPEC.md
grep -c '| 社員 \|| 管理者 \|| hr_admin \|| 給与担当 ' docs/SPEC.md   # §1.4 行数の存在確認
sed -n '/### 1.4/,/^## 2\./p' docs/SPEC.md | head -30                  # §1.4 が §2 の前に収まるか
```
Expected: §1.4 見出しが 1 件・アクター行が複数ヒット・`### 1.4` 〜 `## 2.` の範囲に表が収まる。`---` 区切りが §1.4 の後に残る。

- [ ] **Step 5: Commit**

```bash
git add docs/SPEC.md
git commit -m "docs: SPEC §1.4 ユーザーストーリー動線マップ新設（既存網羅+状態列）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: DoD（DEVELOPMENT_WORKFLOW）+ ROADMAP 横断ルールから §1.4 を参照

**Files:**
- Modify: `docs/DEVELOPMENT_WORKFLOW.md`（基本形テーブルに「マージ前 DoD（動線到達性）」行を追加）
- Modify: `docs/ROADMAP.md`（横断ルールに 1 行追加）

**Interfaces:**
- Consumes: Task 1 の SPEC §1.4。

- [ ] **Step 1: DEVELOPMENT_WORKFLOW 基本形テーブルに DoD 行を追加**

`docs/DEVELOPMENT_WORKFLOW.md` の「マージ前最終」行（`| マージ前最終 | tenant-isolation-reviewer…`）の直後に 1 行追加:

```markdown
| マージ前 DoD（動線到達性） | 主エージェント（SPEC §1.4 ↔ git diff 突合） | Phase 3 spec-check が動線断絶を検出（PR #19/#20）。変更/新規機能は §1.4 に対応行があり起点(route+nav)が実在・状態(✅/⚠️)一致を確認、新機能は §1.4 に行追加してからマージ |
```

- [ ] **Step 2: ROADMAP 横断ルールに 1 行追加**

`docs/ROADMAP.md` の「## 横断ルール（順序の根拠）」末尾（`- 各フェーズ完了時: /spec-check → …` の後）に追加:

```markdown
- 動線到達性の SSOT は **SPEC §1.4**（ユーザーストーリー動線マップ）。各スライスは自分の行を追加・更新し、フェーズ完了時の `/spec-check` が §1.4 を基準に照合する（Phase 3 spec-check で動線断絶を検出した再発防止策）
```

- [ ] **Step 3: 検証**

Run:
```bash
cd /Users/Eoh/workspace/Gatcha_on_RoR
grep -n 'マージ前 DoD（動線到達性）' docs/DEVELOPMENT_WORKFLOW.md
grep -n '動線到達性の SSOT は' docs/ROADMAP.md
```
Expected: 各 1 件ヒット。

- [ ] **Step 4: Commit**

```bash
git add docs/DEVELOPMENT_WORKFLOW.md docs/ROADMAP.md
git commit -m "docs: 動線到達性を DoD/横断ルールに昇格（§1.4 を SSOT 参照）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `/spec-check` skill に Agent 5（ユーザーストーリー網羅性）を常設化

**Files:**
- Modify: `.claude/skills/spec-check/SKILL.md`（観点数 4→5・Agent 5 追加・出力フォーマットに節追加）

**Interfaces:**
- Consumes: Task 1 の SPEC §1.4（Agent 5 の照合基準）。

- [ ] **Step 1: 観点数 4→5 に更新（2 箇所）**

`docs/` ではなく `.claude/skills/spec-check/SKILL.md`。以下 2 箇所を置換:

置換 1（設計原則）:
```markdown
- **並列 subagent** で output token を節約（5 観点を同時起動）
```
（元: `（4 観点を同時起動）`）

置換 2（手順 冒頭）:
```markdown
5 つの subagent（Explore / general）を**並列**起動し、結果をマージする。
```
（元: `4 つの subagent（Explore / general）を…`）

- [ ] **Step 2: Agent 5 を Agent 4 の直後（`## 出力フォーマット` の前）に挿入**

`### Agent 4: 認可・テナント照合` ブロックの最後（`- オーナー（\`user_id\`）と操作者の分離（§3.5）`）の後、`## 出力フォーマット` の前に挿入:

```markdown

### Agent 5: ユーザーストーリー網羅性照合（§1.4）
`docs/SPEC.md` §1.4 動線マップ ↔ `config/routes.rb` + `app/controllers/` + `app/views/` + `app/components/`
- §1.4 各行の `起点 route` が routes.rb に実在し、`nav 入口`（`GlobalNavComponent#links` 等）からクリック到達できるか
- 「機能・policy はあるが画面にリンクが無い」「action はあるが nav/画面から到達不能」な**動線断絶**の検出（§1.4 に無い到達不能画面が無いか）
- §1.4 の `状態`（✅/⚠️）が実態と一致するか・空の `起点 route`／欠落 `nav 入口` が無いか
- ※ 個別機能の有無は Agent 1–4 が担当。本観点は「アクターが端から端まで辿れるか」の到達性のみ見る
```

- [ ] **Step 3: 出力フォーマットに §1.4 節を追加**

出力フォーマットの code block 内、`## 認可・テナント（§3）` の後に追加:

```markdown

## ユーザーストーリー網羅性（§1.4）
| Story（アクター×目的） | 到達可能? (✅/⚠️/❌) | 起点 route 実在 | nav 入口 | 欠落点 |
```

- [ ] **Step 4: 検証**

Run:
```bash
cd /Users/Eoh/workspace/Gatcha_on_RoR
grep -n '5 観点を同時起動\|5 つの subagent' .claude/skills/spec-check/SKILL.md
grep -n '### Agent 5: ユーザーストーリー網羅性照合' .claude/skills/spec-check/SKILL.md
grep -n '## ユーザーストーリー網羅性（§1.4）' .claude/skills/spec-check/SKILL.md
```
Expected: それぞれヒット（観点数 2 箇所・Agent 5 見出し・出力節）。

- [ ] **Step 5: Commit**

```bash
git add .claude/skills/spec-check/SKILL.md
git commit -m "docs: spec-check に Agent 5（ユーザーストーリー網羅性・§1.4 基準）を常設化

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## 完了時（PR 前）

- [ ] 全 commit が docs/skill md のみ（`git diff --name-only main...HEAD | grep -vE '\.md$'` が空）であることを確認
- [ ] ROADMAP 横断バックログに本スライスの完了記録（PR 番号）を残すか判断（横断ルール改訂ゆえ backlog 行は不要・改訂履歴と DoD 行が記録を兼ねる）
- [ ] PR 作成（base main・docs-only ゆえ CI は lint/security/test が通れば良い）

## Self-Review チェック結果

- **設計カバレッジ**: 設計 §3（§1.4 新設＝Task 1）/ §4.1（DoD＝Task 2）/ §4.2（spec-check Agent 5＝Task 3）/ §4.3（ROADMAP＝Task 2）すべてにタスク対応あり。
- **Placeholder**: なし（§1.4 本文・各編集テキストは完成形）。
- **整合**: §1.4 の起点 route は PR #20 マージ後の実ルート前提（`new_clock_change_request`・残高 nested・`summary_csv`/`detail_csv` 実在）。Task 1 Step 1 で grep 裏取り。Agent 5 の照合基準（§1.4）は Task 1 の成果物を指す＝順序整合。
- **既知の注意**: 改訂履歴の追記アンカーは「現在の最終行」（実装時に tail を読んで直後へ）。SPEC §1.4 挿入は `---` 区切りを §1.4 の後に残す点に注意（Task 1 Step 2 注記）。
