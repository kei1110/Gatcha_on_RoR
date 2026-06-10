# CLAUDE.md

Salesforce 2GP 勤怠パッケージ「Gatcha」を **Ruby on Rails 8 マルチテナント SaaS** へ再設計するプロジェクト。**勤怠ドメインのみ**（工数管理 Gatcha Work は範囲外）。現在は**仕様策定フェーズ**（`rails new` 前・アプリコード未生成）。

## ドキュメント地図（SSOT）
- [docs/SPEC.md](docs/SPEC.md) — 仕様の single source of truth（§0〜§16・多視点レビュー反映・原典照合済み）
- [docs/LABOR_LAW_REVIEW_NOTES.md](docs/LABOR_LAW_REVIEW_NOTES.md) — 社労士確認事項（解釈・運用判断）
- [docs/MCP_SETUP.md](docs/MCP_SETUP.md) — MCP サーバー設定と有効化手順
- SF 版原典（移植元・参照のみ）: `../Gatcha/docs/SPEC.md`

## スタック
Rails 8 / PostgreSQL 17 / Hotwire(Turbo+Stimulus)+ViewComponent / Devise / acts_as_tenant（行レベル）/ Pundit / SolidQueue(recurring) / SolidCable / AASM。Ruby 3.3.11。

## 環境（整備済み）
- **Ruby:** 3.3.11（rbenv・`.ruby-version` でこのリポジトリに固定）
- **Postgres:** 17（`brew services` 常駐）。DB `gatcha_development` / `gatcha_test` 作成済み。psql は keg-only → `/opt/homebrew/opt/postgresql@17/bin`
- **MCP（.mcp.json）:** jp-labor-evidence（即稼働）/ sentry / rails（要 `~/.config/rails-mcp/projects.yml`）/ postgres

## Git
- このリポジトリのコミットは **kei1110 <eoh2145@gmail.com>**（local config 済み・グローバル設定とは別）

## カスタムスキル（.claude/skills/）
- `/spec-check` — SPEC↔実装の整合 ／ `/multi-perspective-review` — 多視点並列 critique
- `/legal-citation-audit` — 労務法令を jp-labor-evidence MCP で原典照合 ／ `/preflight` — push 前 CI 等価チェック（rails new 後に有効）

## フック（.claude/settings.json → scripts/claude-hooks/）
PreToolUse/PostToolUse の開発ガード（**Claude Code 再起動＋承認**で有効化）:
- `guard-git-identity`（Bash）— commit/push を kei1110(eoh2145@gmail.com) identity・`github-kei1110` remote 以外で中断
- `block-secrets`（Edit/Write）— master.key・credentials の鍵・.env を保護
- `block-schema-edit`（Edit/Write）— db/schema.rb の手編集を禁止（migration 経由を強制）
- `check-tenant-scope`（Write）— app/models の `acts_as_tenant` 欠落を警告（§3.6）
- `rubocop-autoformat`（Edit/Write）— .rb を自動整形（rails new 後）

## Gotchas（非自明・重要）
- **OpenSSL:** `~/.zshrc` に Intel 時代の openssl@1.1 設定が残存（chezmoi 管理・未修正）。Ruby ビルド時は `RUBY_CONFIGURE_OPTS="--with-openssl-dir=$(brew --prefix openssl@3)"` ＋ `LDFLAGS=/CPPFLAGS=/PKG_CONFIG_PATH=` のクリアで回避。グローバル ruby 2.7.2 は openssl@1.1 欠落で壊れている（本リポジトリは 3.3.11 ゆえ無関係）
- **rails MCP:** `rails-mcp-server`（rbenv shim）は cwd の `.ruby-version` で Ruby を解決 → プロジェクト直下で起動されること
- **マルチテナント安全（SPEC §3.6）:** SolidQueue バッチはリクエスト無 → `ActsAsTenant.with_tenant(org)` でラップ必須（全社横断漏洩を防ぐ）。自己参照 FK は同一テナント強制
- **コンプラ判定は法定(legal)基準固定**（SPEC §8）。36 協定の上限・割増率は定数（テナント設定で改変不可）
- 親 `/Users/Eoh/CLAUDE.md` は chezmoi dotfiles 用で本プロジェクトとは無関係（自動ロードされるが従わない）
- **rails console / rake:** `require_tenant = true` ゆえ、最初に `ActsAsTenant.current_tenant = Organization.find_by!(subdomain: "acme")` を実行しないとスコープ付きモデルのクエリが `NoTenantSet` で失敗する

## ワークフロー
実装は SPEC §15 のフェーズ（0 基盤 → 5 管理・監査）。各フェーズは brainstorm → writing-plans → 実装。次の一歩は `rails new` で Phase 0 着手。
