# ブランチ戦略 設定適用 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 設計仕様（`docs/superpowers/specs/2026-06-10-branch-strategy-design.md`）の GitHub Flow 厳格運用を、GitHub のリポジトリ設定と `main` Ruleset に実際に適用する。

**Architecture:** 全操作は `gh api`（GitHub REST API）で宣言的に適用し、適用前後を `--jq` で検証する。CI が未整備の現状（`rails new` 前）を踏まえ、CI 依存の「必須ステータスチェック」は**適用しない**——今 required にすると全 PR がロックアウトされるため、別段（Deferred）に分離する。

**Tech Stack:** GitHub CLI (`gh`) / GitHub REST API（repos settings・rulesets）/ jq

**前提となる重大な制約（必読）:**
`gh` CLI のアクティブアカウントは `sub-account` だが、当リポジトリ `kei1110/Gatcha_on_RoR` の管理権限を持つのは `kei1110`。管理 API（settings 変更・ruleset 作成）は `kei1110` をアクティブにしないと `must be a collaborator` で失敗する。よって **Task 1 で `kei1110` に切り替え、Task 5 で `sub-account` に戻す**。途中で中断した場合は手動で戻すこと（`gh auth switch --hostname github.com --user sub-account`）。

**コミットについて:** 本計画の実行は GitHub 側の状態変更が主で、**リポジトリへの commit は発生しない**（計画ドキュメント自体のコミットを除く）。各設定タスクに `git commit` ステップは無い。

**リポジトリ識別子:** `kei1110/Gatcha_on_RoR`（以下 `$REPO` と表記。実行時は実値を使う）

---

## File Structure

このプランは GitHub サーバー側の構成のみを変更する。新規・変更するリポジトリ内ファイルは無い。生成する一時ファイル:

- `/tmp/main-ruleset.json` — `main` 用 Ruleset の作成ペイロード（Task 4 で使用、検証後は破棄可）

---

### Task 1: 事前確認と gh アカウント切り替え

**Files:** なし（GitHub アカウント状態の操作）

- [ ] **Step 1: 現在のアクティブアカウントを確認する**

Run:
```bash
gh api user --jq '.login'
```
Expected: `sub-account`（既定状態）

- [ ] **Step 2: kei1110 に切り替える**

Run:
```bash
gh auth switch --hostname github.com --user kei1110
```
Expected: `✓ Switched active account for github.com to kei1110`

- [ ] **Step 3: 切り替えとリポジトリ管理権限を検証する**

Run:
```bash
gh api user --jq '.login' && gh api repos/kei1110/Gatcha_on_RoR --jq '.permissions.admin'
```
Expected: `kei1110` と `true`（admin 権限あり = 以降の管理 API が通る）

---

### Task 2: リポジトリのマージ方式を Squash 限定にする

**Files:** なし（`PATCH /repos/{owner}/{repo}`）

設計 §6: Squash のみ有効、Merge commit / Rebase を無効、Auto-delete head branches を ON、Squash 時は PR タイトルを commit に。

- [ ] **Step 1: 適用前の状態を確認する（まだ既定）**

Run:
```bash
gh api repos/kei1110/Gatcha_on_RoR \
  --jq '{squash: .allow_squash_merge, merge: .allow_merge_commit, rebase: .allow_rebase_merge, delete_branch: .delete_branch_on_merge}'
```
Expected: 既定では `merge: true, rebase: true`（= まだ Squash 限定になっていない）

- [ ] **Step 2: マージ設定を適用する**

Run:
```bash
gh api --method PATCH repos/kei1110/Gatcha_on_RoR \
  -F allow_squash_merge=true \
  -F allow_merge_commit=false \
  -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true \
  -f squash_merge_commit_title=PR_TITLE \
  -f squash_merge_commit_message=PR_BODY \
  --silent
```
Expected: エラー出力なし（HTTP 200）

- [ ] **Step 3: 適用後の状態を検証する**

Run:
```bash
gh api repos/kei1110/Gatcha_on_RoR \
  --jq '{squash: .allow_squash_merge, merge: .allow_merge_commit, rebase: .allow_rebase_merge, delete_branch: .delete_branch_on_merge, squash_title: .squash_merge_commit_title}'
```
Expected:
```json
{"squash": true, "merge": false, "rebase": false, "delete_branch": true, "squash_title": "PR_TITLE"}
```

---

### Task 3: 既存 Ruleset の不在を確認する

**Files:** なし（`GET /repos/{owner}/{repo}/rulesets`）

二重適用を防ぐため、`main` を対象にした Ruleset が未作成であることを確認する。

- [ ] **Step 1: 既存 Ruleset 一覧を確認する**

Run:
```bash
gh api repos/kei1110/Gatcha_on_RoR/rulesets --jq '.[] | {id, name, target}'
```
Expected: 出力なし（空 = Ruleset 未作成）。
もし `name: "main"` 等が既に存在する場合は、本 Task 4 の新規作成は行わず、既存 ruleset の `id` を控えて Step を「更新（PUT）」に読み替えること。

---

### Task 4: main 保護 Ruleset を作成する（ステータスチェックは含めない）

**Files:**
- Create（一時）: `/tmp/main-ruleset.json`

設計 §6 のうち **CI 非依存の項目のみ**を適用する:
PR 必須 / linear history / conversation resolution / 直 push 禁止（deletion・force-push 禁止）/ **承認数 0**（単独ゆえ自己承認不可）。
**required_status_checks は含めない**（CI 不在 → Deferred Task へ）。

- [ ] **Step 1: Ruleset ペイロードを作成する**

Run:
```bash
cat > /tmp/main-ruleset.json <<'JSON'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": {
    "ref_name": {
      "include": ["~DEFAULT_BRANCH"],
      "exclude": []
    }
  },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true
      }
    }
  ]
}
JSON
```
Expected: エラーなし（ファイル生成）

補足: `required_approving_review_count: 0` が単独開発の要点。`pull_request` ルールが「PR 必須＝直 push 禁止」を担い、`non_fast_forward` が force-push を、`deletion` がブランチ削除を防ぐ。`required_linear_history` が merge commit を排除（Task 2 の squash 限定と二重で担保）。

- [ ] **Step 2: Ruleset を作成する**

Run:
```bash
gh api --method POST repos/kei1110/Gatcha_on_RoR/rulesets \
  --input /tmp/main-ruleset.json \
  --jq '{id, name, enforcement}'
```
Expected:
```json
{"id": <数値>, "name": "main", "enforcement": "active"}
```
（`id` は控えておく。Deferred Task の更新で使う）

- [ ] **Step 3: 適用された Ruleset を検証する**

Run:
```bash
gh api repos/kei1110/Gatcha_on_RoR/rulesets --jq '.[] | select(.name=="main") | .id' \
  | xargs -I{} gh api repos/kei1110/Gatcha_on_RoR/rulesets/{} \
  --jq '{name, enforcement, rules: [.rules[].type]}'
```
Expected:
```json
{"name": "main", "enforcement": "active", "rules": ["deletion", "non_fast_forward", "required_linear_history", "pull_request"]}
```
（`required_status_checks` が含まれていないことを確認）

- [ ] **Step 4: 直 push が実際に拒否されることを確認する（任意・破壊なし）**

Run:
```bash
git fetch origin && git push origin origin/main:main --dry-run 2>&1 | head -5
```
Expected: `protected branch` または `Changes must be made through a pull request` 系のエラー（= 直 push がブロックされている）。`--dry-run` ゆえ実際の push は発生しない。

---

### Task 5: gh アカウントを sub-account に戻す

**Files:** なし（GitHub アカウント状態の操作）

- [ ] **Step 1: 既定アカウントへ復元する**

Run:
```bash
gh auth switch --hostname github.com --user sub-account
```
Expected: `✓ Switched active account for github.com to sub-account`

- [ ] **Step 2: 復元を検証する**

Run:
```bash
gh api user --jq '.login'
```
Expected: `sub-account`（既定状態に復帰）

- [ ] **Step 3: 一時ファイルを掃除する**

Run:
```bash
rm -f /tmp/main-ruleset.json
```
Expected: エラーなし

---

## Deferred Task（CI 整備後・現時点では実行しない）: 必須ステータスチェックの登録

> ⛔ **DO NOT RUN YET.** このタスクは `rails new` 後に CI ワークフロー（`.github/workflows/`）を追加し、CI と CodeRabbit のチェックが PR 上で **最低 1 回実行された後**にのみ実行する。今実行すると、存在しないチェックを待ち続けて全 PR がマージ不能になる（設計 §9 の警告）。

実行手順（将来の参照用・context 名は実チェックから取得して埋めること）:

1. **実際のチェック context 名を取得する**（CI を一度走らせた PR の HEAD SHA を使う）:
```bash
gh api repos/kei1110/Gatcha_on_RoR/commits/<sha>/check-runs --jq '.check_runs[].name'
```
これで CI ジョブ名（例: `test` / `rubocop`）と CodeRabbit のチェック名を確認する。

2. **既存 ruleset の id を取得する**:
```bash
RULESET_ID=$(gh api repos/kei1110/Gatcha_on_RoR/rulesets --jq '.[] | select(.name=="main") | .id')
```

3. **`required_status_checks` ルールを加えた更新ペイロードで PUT する**（Task 4 の rules に下記を追加した完全な rules 配列を `--input` で渡す）:
```json
{
  "type": "required_status_checks",
  "parameters": {
    "strict_required_status_checks_policy": true,
    "required_status_checks": [
      { "context": "<CI ジョブ名>" },
      { "context": "<CodeRabbit チェック名>" }
    ]
  }
}
```
```bash
gh auth switch --hostname github.com --user kei1110
gh api --method PUT repos/kei1110/Gatcha_on_RoR/rulesets/$RULESET_ID --input /tmp/main-ruleset-with-checks.json
gh auth switch --hostname github.com --user sub-account
```

4. **検証**: ruleset の rules に `required_status_checks` が含まれ、PR 上で当該チェックが緑にならないとマージできないことを確認する。

---

## Self-Review

- **Spec coverage（設計 §6 の項目対応）:**
  - PR 必須 → Task 4 `pull_request` ルール ✅
  - 直 push 禁止 → Task 4 `pull_request`＋`non_fast_forward`＋`deletion`、Task 4 Step 4 で実証 ✅
  - linear history → Task 4 `required_linear_history` ✅
  - conversation resolution → Task 4 `required_review_thread_resolution: true` ✅
  - 承認数を要求しない → Task 4 `required_approving_review_count: 0` ✅
  - Squash のみ / Merge・Rebase 無効 / Auto-delete head branches → Task 2 ✅
  - 必須ステータスチェック（CI＋CodeRabbit）→ Deferred Task（§9 段階導入に合致）✅
  - gh アカウント食い違いの回避 → Task 1 / Task 5 ✅
- **Placeholder scan:** アクティブな Task 1〜5 にプレースホルダなし。Deferred Task の `<sha>` / context 名は CI 不在ゆえ現時点で確定不能で、これは仕様上の段階分離であり実行可能タスクの穴ではない。
- **Type consistency:** リポジトリ識別子 `kei1110/Gatcha_on_RoR`、ruleset 名 `main`、一時ファイル `/tmp/main-ruleset.json` を全タスクで一貫使用。
