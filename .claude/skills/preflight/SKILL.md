---
name: preflight
description: push / PR 作成前に local で CI 等価の静的検証をまとめて回し、CI 往復を減らしたいときに使う。TRIGGER - push / gh pr create 直前 / ユーザーが「preflight」「push 前」「CI 前検証」「coverage 確認」「lint まとめて」に言及。DO NOT TRIGGER - docs only commit（*.md のみ） / WIP commit を細かく重ねている最中 / rails new 前（ツール不在）。
---

# preflight — push / PR 作成前の local CI 等価チェック（Rails）

CI で実行する静的検証群を push 前に local 並列実行し、CI 往復（数分）を削減する。SF 版 `preflight` の Rails 移植（prettier/eslint/jest/pmd → **rubocop/rspec/brakeman/simplecov**）。

## 設計原則（SF 版から不変の資産）

- **判定せず材料提供**（Mechanism over Judgment）— PASS/FAIL を出すだけ。auto-fix はしない
- **既存 gem / コマンドを orchestration するのみ**（新規 logic を書かない）
- **diff scope で自動 skip**（`app/` 無変更 → brakeman skip 等）
- **fail-fast せず全件実行**（1 つの fail で他を止めると往復が増える）
- **escape hatch**: `GATCHA_PREFLIGHT_SKIP=rubocop,rspec,brakeman,coverage,audit,erblint`
- **Self-exclusion**: Phase 0 で本 skill の Last verified 鮮度と、cite 先（`Gemfile` / `bin/rubocop` 等）の実在を確認

## 入力

- 引数なし: `git diff`（`HEAD~..HEAD` + staged + unstaged）から scope 自動判定
- `--all`: 全件 / `--staged`: staged のみ

## Phase 0: Self-exclusion + scope 判定

```bash
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

# rails new 前ガード（Gemfile 不在なら全 SKIP して終了）
[[ -f Gemfile ]] || { echo "⏭️  rails new 前: Gemfile 不在のため preflight skip"; exit 0; }

# scope 判定
case "${1:-}" in
  --all)    DIFF_FILES=$(git ls-files) ;;
  --staged) DIFF_FILES=$(git diff --cached --name-only) ;;
  *)        DIFF_FILES=$( { git diff --name-only HEAD~..HEAD 2>/dev/null; git diff --name-only; git diff --cached --name-only; } | sort -u ) ;;
esac

HAS_RB=$(echo "$DIFF_FILES"   | grep -cE '\.rb$' || true)
HAS_APP=$(echo "$DIFF_FILES"  | grep -cE '^app/' || true)
HAS_VIEW=$(echo "$DIFF_FILES" | grep -cE '^app/views/.*\.erb$' || true)
HAS_LOCK=$(echo "$DIFF_FILES" | grep -cE '^Gemfile\.lock$' || true)

SKIP_CSV="${GATCHA_PREFLIGHT_SKIP:-}"
should_run() { [[ ",$SKIP_CSV," == *",$1,"* ]] && return 1 || return 0; }
```

## Phase 1: 並列検証（background 起動 → wait）

各検証は log file に書き出し、最後に summary だけ stdout に出す。

```bash
LOG_DIR="/tmp/preflight-$(date +%s)"; mkdir -p "$LOG_DIR"

# 1. RuboCop（変更 .rb / rubocop-rails-omakase）
if should_run rubocop && [[ "$HAS_RB" -gt 0 ]]; then
  { echo "$DIFF_FILES" | grep -E '\.rb$' | xargs bundle exec rubocop > "$LOG_DIR/rubocop.log" 2>&1; echo $? > "$LOG_DIR/rubocop.exit"; } &
fi

# 2. RSpec（関連 spec。安全側は全実行）+ 3. SimpleCov coverage（rspec が出力）
if should_run rspec; then
  { COVERAGE=true bundle exec rspec > "$LOG_DIR/rspec.log" 2>&1; echo $? > "$LOG_DIR/rspec.exit"; } &
fi

# 4. Brakeman（app/ 変更時・セキュリティ）
if should_run brakeman && [[ "$HAS_APP" -gt 0 ]]; then
  { bundle exec brakeman -q -w2 > "$LOG_DIR/brakeman.log" 2>&1; echo $? > "$LOG_DIR/brakeman.exit"; } &
fi

# 5. bundle-audit（Gemfile.lock 変更時・脆弱 gem）
if should_run audit && [[ "$HAS_LOCK" -gt 0 ]]; then
  { bundle exec bundle-audit check --update > "$LOG_DIR/audit.log" 2>&1; echo $? > "$LOG_DIR/audit.exit"; } &
fi

# 6. erb_lint（views 変更時）
if should_run erblint && [[ "$HAS_VIEW" -gt 0 ]]; then
  { bundle exec erb_lint --lint-all > "$LOG_DIR/erblint.log" 2>&1; echo $? > "$LOG_DIR/erblint.exit"; } &
fi

wait
```

## Phase 2: Summary 集約

`$LOG_DIR/*.exit` を走査し PASS(0) / FAIL(≠0) / SKIP(file 不在) のマトリクスを出力。FAIL があれば各 log の先頭 30 行を添えて非ゼロ終了。

```
=== /preflight summary ===
✅ rubocop          (12 files, 0 offenses)
❌ rspec/coverage   (coverage 82.3% < 85%)
✅ brakeman         (0 warnings)
⏭️  bundle-audit    (Gemfile.lock 無変更)
⏭️  erb_lint        (views 無変更)
```

## グリーンフィールド時

`rails new` 前は Gemfile / bin が無いため Phase 0 ガードで即 skip。`rails new` 後に有効化する。CI（`.github/workflows`）を整備したら、本 skill の検証群が CI と**等価**になるよう同期すること（本 skill PASS = CI PASS を保証はしない）。

## 関連

- `docs/SPEC.md` §2.1（スタック）/ §15（フェーズ）
- `/spec-check`（SPEC ↔ 実装）/ `/legal-citation-audit`（SPEC ↔ 法令）と直交

<!-- Last verified: 2026-06-09 -->
