# MCP サーバー設定（Gatcha_on_RoR）

`.mcp.json`（リポジトリ直下）にプロジェクトスコープの MCP サーバーを 3 つ定義している。Claude Code は初回起動時にプロジェクト MCP の信頼確認を求める（承認が必要）。

## 状態サマリ

| サーバー | 役割 | 状態 | 有効化の前提 |
|---------|------|------|------------|
| **sentry** | エラー追跡・原因調査 | ✅ 即利用可（初回 OAuth） | Sentry アカウント / 組織 |
| **rails** | Rails プロジェクト解析（モデル・ルート・スキーマ） | ⏳ 前提待ち | Ruby 3.3+ + `gem install rails-mcp-server` + `projects.yml` |
| **postgres** | スキーマ参照・クエリ・性能解析 | ⏳ 前提待ち | Postgres 本体 + `gatcha_development` DB |

> グリーンフィールド（`rails new` 前）ゆえ ①② は「設定済み・前提待ち」。前提が整うまで Claude Code 上では接続エラー表示になるが、これは想定どおり。

## ① rails — rails-mcp-server（maquina-app）

現在の system Ruby は **2.7.2** で不可。本プロジェクトは仕様上 Ruby 3.3+ を要する（Rails 8 のため）。

```bash
# 1. プロジェクト用 Ruby を導入（rbenv の例。asdf でも可）
rbenv install 3.3.7
rbenv local 3.3.7            # .ruby-version を生成

# 2. gem 導入
gem install rails-mcp-server

# 3. プロジェクト登録（初回起動時に ~/.config/rails-mcp/ が生成される）
#    ~/.config/rails-mcp/projects.yml に追記:
#      gatcha: /Users/Eoh/workspace/Gatcha_on_RoR
```

- 真価を発揮するのは Rails アプリ構造（`config/` `app/` 等）ができてから（`rails new` 後）
- `.mcp.json` の `rails` は `rails-mcp-server`（STDIO）を起動する

## ② postgres — @modelcontextprotocol/server-postgres（公式・読み取り中心）

```bash
# 1. Postgres 導入・起動
brew install postgresql@16
brew services start postgresql@16

# 2. Rails アプリ生成後に DB 作成（gatcha_development が生まれる）
rails new . --database=postgresql   # 既存 docs/ を保持しつつ scaffold する場合は別途調整
bin/rails db:create
```

- `.mcp.json` の接続文字列は `postgresql://localhost/gatcha_development`。認証情報が必要な環境では `postgresql://user:pass@localhost/gatcha_development` に調整
- 本番では**読み取り専用**構成を厳守。性能解析（インデックス提案・クエリプラン）が欲しくなったら、Node を要しない **Postgres MCP Pro**（`crystaldba/postgres-mcp`）への差し替えを検討（Docker or pipx）

## ⑤ sentry — Sentry リモート MCP（公式・OAuth）

- 追加設定不要。Claude Code で初回利用時に `https://mcp.sentry.dev/mcp` への **OAuth 認可**が走る
- 利用には Sentry の org / project が必要
- 労務・給与に隣接する本 SaaS では実行時エラー = 法的 / 給与リスク。**本番運用期（ロードマップ Phase 5〜）**に効く

## 接続確認

```bash
claude mcp list          # 各サーバーの接続状態を確認
```

Claude Code 再起動時にプロジェクト MCP の信頼を承認すること。
