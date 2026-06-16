# MCP サーバー設定（Gatcha_on_RoR）

`.mcp.json`（リポジトリ直下）にプロジェクトスコープの MCP サーバーを 4 つ定義している。Claude Code は初回起動時にプロジェクト MCP の信頼確認を求める（承認が必要）。

## 状態サマリ（2026-06-13 時点・全サーバー接続済み）

| サーバー | 役割 | 状態 |
|---------|------|------|
| **jp-labor-evidence** | 日本の労基法・労安法・行政通達の原文エビデンス取得 | ✅ 接続済み（npx・前提なし） |
| **rails** | Rails プロジェクト解析（モデル・ルート・スキーマ） | ✅ 接続済み（gem 1.5.1 + projects.yml 登録済み） |
| **postgres** | スキーマ参照・クエリ・性能解析 | ✅ 接続済み（Postgres 18 常駐・`gatcha_development`） |
| **sentry** | エラー追跡・原因調査 | ✅ 接続済み（OAuth 認可済み・2026-06-13） |

## ① jp-labor-evidence — 日本労務法令エビデンス MCP（sub-account）

- リポジトリ: <https://github.com/sub-account/jp-labor-evidence-mcp>（Node.js / TypeScript）
- **追加設定不要・前提なし**。`.mcp.json` の `npx -y jp-labor-evidence-mcp` が初回にパッケージを取得して起動する（API キー不要。任意で `LABOR_LAW_INDEX_DIR` でインデックス保存先を変更可）
- 提供ツール:
  - 法令原文: `resolve_law` / `get_article` / `search_law` / `get_evidence_bundle` / `diff_revision`（改正差分）
  - 行政通達: `search_mhlw_tsutatsu`・`get_mhlw_tsutatsu`（厚労省）/ `search_jaish_tsutatsu`・`get_jaish_tsutatsu`
  - 観測: `get_observability_snapshot`
- 用途: SPEC §5・§8 の労務ロジック（労基法 34/37/39/41 条・36 協定・労安法 66 条の 8 等）の**典拠を原文・ソース URL・監査メタデータ付きで取得**。`/legal-citation-audit` skill と `labor-law-compliance-reviewer` agent の基盤

## ② rails — rails-mcp-server（maquina-app）

整備済みの構成（再現手順を兼ねた記録）:

```bash
# Ruby（rbenv・.ruby-version でリポジトリに固定済み）
gem install rails-mcp-server        # 1.5.1 導入済み

# ~/.config/rails-mcp/projects.yml（登録済み）:
#   gatcha: /Users/Eoh/workspace/Gatcha_on_RoR
```

- `.mcp.json` の `rails` は `rails-mcp-server`（STDIO）を起動する
- **Gotcha:** `rails-mcp-server` は rbenv shim ゆえ **cwd の `.ruby-version` で Ruby を解決**する → Claude Code をプロジェクト直下で起動すること（他所から起動すると ruby 2.7.2 に落ちて失敗）
- 複数プロジェクト登録時は `switch_project` ツールで切替

## ③ postgres — @modelcontextprotocol/server-postgres（公式・読み取り中心）

- Postgres 18 が `brew services` で常駐済み。DB `gatcha_development` / `gatcha_test` 作成済み
- `.mcp.json` の接続文字列は `postgresql://localhost/gatcha_development`（local trust 認証・調整不要）
- psql が必要なら keg-only パス `/opt/homebrew/opt/postgresql@18/bin` を使う
- 本番では**読み取り専用**構成を厳守。性能解析（インデックス提案・クエリプラン）が欲しくなったら、Node を要しない **Postgres MCP Pro**（`crystaldba/postgres-mcp`）への差し替えを検討（Docker or pipx）

## ④ sentry — Sentry リモート MCP（公式・HTTP + OAuth）

- `.mcp.json` で `https://mcp.sentry.dev/mcp` への HTTP 接続。**OAuth 認可済み**（2026-06-13・再認可が必要になったら `/mcp` から）
- 労務・給与に隣接する本 SaaS では実行時エラー = 法的 / 給与リスク。真価を発揮するのは**本番運用期（ロードマップ Phase 5〜）** — エラー追跡対象のデプロイ環境ができてから

## 接続確認

```bash
claude mcp list          # 各サーバーの接続状態を確認（2026-06-13: 4/4 Connected）
```

- Claude Code 再起動時にプロジェクト MCP の信頼を承認すること
- sentry の OAuth が切れた場合は Claude Code 内の `/mcp` から再認可
