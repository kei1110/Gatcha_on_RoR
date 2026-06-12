# CLAUDE.md

Salesforce 2GP 勤怠パッケージ「Gatcha」を **Ruby on Rails 8 マルチテナント SaaS** へ再設計するプロジェクト。**勤怠ドメインのみ**（工数管理 Gatcha Work は範囲外）。現在は **Phase 0b（マスタ CRUD）進行中**。現在地・次の一歩は docs/ROADMAP.md が正。

## ドキュメント地図（SSOT）
- [docs/SPEC.md](docs/SPEC.md) — 仕様の single source of truth（§0〜§16・多視点レビュー反映・原典照合済み・SF 知識なしで自立）
- [docs/ROADMAP.md](docs/ROADMAP.md) — 進行管理の SSOT（フェーズ→スライス分解・現在地・1 スライス = 1 PR）
- [docs/RAILS_GOTCHAS.md](docs/RAILS_GOTCHAS.md) — 実際に踏んだ/仕留めた罠台帳（WHAT/WHY/HOW・verified 日付き）。**計画とレビューのプロンプトに注入し、新しい罠は修正と同じ PR で追記**
- [docs/DEVELOPMENT_WORKFLOW.md](docs/DEVELOPMENT_WORKFLOW.md) — スライス実行体制の規約（役割分担・haiku 転写・レビュー実挙動検証義務など。0b-5/1-1 で実測検証済み）
- [docs/LABOR_LAW_REVIEW_NOTES.md](docs/LABOR_LAW_REVIEW_NOTES.md) — 社労士確認事項（解釈・運用判断）
- [docs/MCP_SETUP.md](docs/MCP_SETUP.md) — MCP サーバー設定と有効化手順
- [docs/MIGRATION_FROM_SF.md](docs/MIGRATION_FROM_SF.md) — SF 版からの移植対応表（歴史的経緯・参照任意。SF 版原典 `../Gatcha/docs/SPEC.md` が手元に無くても支障なし）

## スタック
Rails 8 / PostgreSQL 17 / Hotwire(Turbo+Stimulus)+ViewComponent / Devise / acts_as_tenant（行レベル）/ Pundit / SolidQueue(recurring) / SolidCable / AASM。Ruby 3.3.11。

## 環境（整備済み）
- **Ruby:** 3.3.11（rbenv・`.ruby-version` でこのリポジトリに固定）
- **Postgres:** 17（`brew services` 常駐）。DB `gatcha_development` / `gatcha_test` 作成済み。psql は keg-only → `/opt/homebrew/opt/postgresql@17/bin`
- **MCP（.mcp.json）:** jp-labor-evidence / sentry（OAuth 済み）/ rails / postgres — **全 4 サーバー接続済み**（詳細・再現手順は docs/MCP_SETUP.md）

## Git
- このリポジトリのコミットは **kei1110 <eoh2145@gmail.com>**（local config 済み・グローバル設定とは別）
- gh CLI はアカウント 2 つ登録（kei1110 / sub-account）。PR 操作が collaborator エラーになったら `gh auth switch -u kei1110`

## カスタムスキル（.claude/skills/）
- `/spec-check` — SPEC↔実装の整合 ／ `/multi-perspective-review` — 多視点並列 critique ／ `/gen-spec` — spec 雛形生成
- `/legal-citation-audit` — 労務法令を jp-labor-evidence MCP で原典照合 ／ `/preflight` — push 前 CI 等価チェック

## フック（.claude/settings.json → scripts/claude-hooks/）
PreToolUse/PostToolUse の開発ガード（**Claude Code 再起動＋承認**で有効化）:
- `guard-git-identity`（Bash）— commit/push を kei1110(eoh2145@gmail.com) identity・`github-kei1110` remote 以外で中断
- `block-secrets`（Edit/Write）— master.key・credentials の鍵・.env を保護
- `block-schema-edit`（Edit/Write）— db/schema.rb の手編集を禁止（migration 経由を強制）
- `check-tenant-scope`（Write）— app/models の `acts_as_tenant` 欠落を警告（§3.6）
- `rubocop-autoformat`（Edit/Write）— .rb を自動整形
- `block-gemfile-lock-edit`（Edit/Write）— Gemfile.lock の手編集を禁止（bundle 経由を強制）

## Gotchas（非自明・重要）
- **OpenSSL:** `~/.zshrc` に Intel 時代の openssl@1.1 設定が残存（chezmoi 管理・未修正）。Ruby ビルド時は `RUBY_CONFIGURE_OPTS="--with-openssl-dir=$(brew --prefix openssl@3)"` ＋ `LDFLAGS=/CPPFLAGS=/PKG_CONFIG_PATH=` のクリアで回避。グローバル ruby 2.7.2 は openssl@1.1 欠落で壊れている（本リポジトリは 3.3.11 ゆえ無関係）
- **rails MCP:** `rails-mcp-server`（rbenv shim）は cwd の `.ruby-version` で Ruby を解決 → プロジェクト直下で起動されること
- **マルチテナント安全（SPEC §3.6）:** SolidQueue バッチはリクエスト無 → `ActsAsTenant.with_tenant(org)` でラップ必須（全社横断漏洩を防ぐ）。自己参照 FK は同一テナント強制
- **コンプラ判定は法定(legal)基準固定**（SPEC §8）。36 協定の上限・割増率は定数（テナント設定で改変不可）
- 親 `/Users/Eoh/CLAUDE.md` は chezmoi dotfiles 用で本プロジェクトとは無関係（自動ロードされるが従わない）
- **rails console / rake:** `require_tenant = true` ゆえ、最初に `ActsAsTenant.current_tenant = Organization.find_by!(subdomain: "acme")` を実行しないとスコープ付きモデルのクエリが `NoTenantSet` で失敗する
- **rubocop にファイルを明示渡しすると .rubocop.yml の Exclude（db/schema.rb 等）が無視され偽 FAIL** — 必ず `bundle exec rubocop --force-exclusion <files>` で実行（0b-3 preflight で実踏）

## ワークフロー
実装は SPEC §15 のフェーズを docs/ROADMAP.md のスライス（1 スライス = 1 ブランチ = 1 PR・squash マージ）で進める。各スライスは brainstorm →（大物は specs/ に設計 + 多視点レビュー）→ writing-plans → 実装 → `/preflight` → PR。**PR に ROADMAP の該当行更新（チェック + PR 番号）を含めてからマージ**。設計・計画は docs/superpowers/{specs,plans}/ に日付付きで蓄積。現在地と次の一歩は ROADMAP が正。

**サブエージェント運用の 3 か条**（フックはサブエージェントをすり抜けるため指示で補う）:
1. ステップ完了ごとに**即コミット**（セッション上限による中断でもステージ未満の状態を残さない）
2. 探索で触ったが不要だった編集は **revert してから報告**（デバッグ痕を成果に混ぜない）
3. 完了条件に検証コマンドを明記 — `bundle exec rspec`・`bundle exec rubocop`、app/ に触れたら `bin/brakeman --no-pager` も
- 計画・レビューのプロンプトには docs/RAILS_GOTCHAS.md を注入する（罠の再購入防止）
