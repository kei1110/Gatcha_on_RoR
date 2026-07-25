# CLAUDE.md

Salesforce 2GP 勤怠パッケージ「Gatcha」を **Ruby on Rails 8 マルチテナント SaaS** へ再設計するプロジェクト。**勤怠ドメインのみ**（工数管理 Gatcha Work は範囲外）。**現在地・進行中フェーズ・次の一歩は docs/ROADMAP.md が唯一の正**（フェーズ番号を本ファイルにベタ書きしない＝ drift 防止・後述「バージョン記法」と同方針）。

## 鉄則（どのモデル・どのセッションでも遵守）

1. **db/schema.rb と Gemfile.lock を手で編集しない** — 必ず migration / bundle 経由（フックが止めるが、サブエージェントはフックをすり抜けるため指示でも守る）
2. **rubocop へのファイル渡しは `--force-exclusion` ＋ xargs 経由** — `--force-exclusion` を省くと .rubocop.yml の Exclude が無視され db/schema.rb 等で偽 FAIL（0b-3）。**zsh は `cmd $FILES` を単語分割しない**ため変数展開で渡すと「0 files inspected, no offenses」と偽の緑を返す（4-2c-2 で実踏）。`git diff --name-only main...HEAD | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion` とし、`Inspecting N files` の N を必ず確認する
3. **スコープ付きモデルに触れる前にテナント文脈を確立する** — console/rake は `ActsAsTenant.current_tenant = Organization.find_by!(subdomain: "acme")`、ジョブ・service・seed は `ActsAsTenant.with_tenant(org) { ... }`（`require_tenant = true`。`NoTenantSet` は正しい挙動 — ガードを緩めず利用側を直す）
4. **ユーザー参照・マスタ参照の FK は複合 FK `[organization_id, xxx_id] → table(organization_id, id)`** — 単純 FK（`→ users(id)`）はテナント越境を DB が素通しする（§3.6・型は `/create-migration`）。ただし **`with_tenant(信頼できない record.organization)` で自己ラップする書き込み service では複合 FK も model 検証も無力**（昇格プリミティブであって境界ではない）。昇格前に actor↔target の `organization_id` 一致を独立に検証すること（4-2c-2 で実踏・docs/RAILS_GOTCHAS.md）
5. **法定値（SPEC §8）はコード内の定数** — 36 協定上限・割増率・月 80h・有給 5 日等を OrganizationSetting から読む実装にしない（テナント設定はアラート参考値まで）
6. **いかなる違反検知でも打刻をブロックしない**（SPEC §8 — 実労働時間の記録義務。対応は事後通知・エスカレーションのみ）
7. **enum 整数・event_type taxonomy は append-only** — リオーダ・再利用禁止（§13・§4.14。partial index の `where` 生整数が enum マッピングに依存）
8. **マージ前レビュアーは下記「レビュアー起動トリガー表」×実際の git diff から都度導出する** — 設計書のレビュアー表を転記しない（4-2a で転記に従い approval-engine 未起動 → dormant バグが merge 通過・PR #29）

## ドキュメント地図（SSOT）
- [docs/SPEC.md](docs/SPEC.md) — 仕様の single source of truth（§0〜§16・多視点レビュー反映・原典照合済み・SF 知識なしで自立）
- [docs/ROADMAP.md](docs/ROADMAP.md) — 進行管理の SSOT（フェーズ→スライス分解・現在地・1 スライス = 1 PR）
- [docs/RAILS_GOTCHAS.md](docs/RAILS_GOTCHAS.md) — 実際に踏んだ/仕留めた罠台帳（WHAT/WHY/HOW・verified 日付き）。**計画とレビューのプロンプトに注入し、新しい罠は修正と同じ PR で追記**
- [docs/DEVELOPMENT_WORKFLOW.md](docs/DEVELOPMENT_WORKFLOW.md) — スライス実行体制の規約（役割分担・haiku 転写・レビュー実挙動検証義務など。0b-5/1-1 で実測検証済み）
- [docs/LABOR_LAW_REVIEW_NOTES.md](docs/LABOR_LAW_REVIEW_NOTES.md) — 社労士確認事項（解釈・運用判断）。**追記前に `grep -n "^### #"` と冒頭テーブルの両方で最大番号を確認**（番号は二段構えで衝突しやすい）。条文を根拠に引くときは「その条文が実際に命じている内容」を原典で確認する（4-2c-2 で労基法 24 条を適正手続きの根拠として誤引用）
- [docs/LABOR_LAW_REVIEW_REPORT.md](docs/LABOR_LAW_REVIEW_REPORT.md) — ChatGPT deep-research による社労士チェックリスト検証報告（2026-06-13・原典再照合の入力資料。確定結論は LABOR_LAW_REVIEW_NOTES.md が正）
- [docs/MCP_SETUP.md](docs/MCP_SETUP.md) — MCP サーバー設定と有効化手順
- [docs/MIGRATION_FROM_SF.md](docs/MIGRATION_FROM_SF.md) — SF 版からの移植対応表（歴史的経緯・参照任意。SF 版原典 `../Gatcha/docs/SPEC.md` が手元に無くても支障なし）

## スタック
Rails 8 / PostgreSQL 18 / Hotwire(Turbo+Stimulus)+ViewComponent / Devise / acts_as_tenant（行レベル）/ Pundit / SolidQueue(recurring) / SolidCable / AASM。Ruby は `.ruby-version` にピン。

## 環境（整備済み）
- **Ruby:** `.ruby-version` にピン（rbenv。PR #27/#28 で 3.3.11 → 4.0.2 に直行アップグレード済み）
- **Postgres:** 18（`brew services` 常駐）。DB `gatcha_development` / `gatcha_test` 作成済み。psql は keg-only → `/opt/homebrew/opt/postgresql@18/bin`
- **MCP:** 構成は `.mcp.json`、設定・有効化手順は docs/MCP_SETUP.md

> **バージョン記法（drift 防止）:** 現行 Ruby 版は `.ruby-version` が SSOT。prose/docs に数字をベタ書きせずファイルを指す（CI の `setup-ruby` も無記述で追従・Dockerfile ARG だけは build 用 literal で同期コメント付き）。過去の移行記録（PR #27 の 3.3.11 → 4.0.2 等・凍結事実）は数字可。

## よく使うコマンド

```bash
bundle exec rspec [path]                            # テスト（引数なし = 全件）
bundle exec rubocop --force-exclusion <files>       # lint（鉄則 2。全体走査は引数なしで可）
bin/brakeman --no-pager                             # セキュリティ静的解析（app/ に触れたら必須）
bin/rails generate migration XxxYyy                 # migration は生成 → body 差し替え（/create-migration の idiom で）
bin/rails db:migrate && bin/rails db:test:prepare   # db:test:prepare を忘れると test DB 不整合で spec が落ちる
bin/rails console                                   # 起動後まず鉄則 3 のテナント設定を実行
```

## Git
- このリポジトリのコミットは **kei1110 <eoh2145@gmail.com>**（local config 済み・グローバル設定とは別）
- gh CLI はアカウント 2 つ登録（kei1110 / sub-account）。**PR・API 操作の前に `gh api user --jq .login` で active を確認**し、違えば `gh auth switch -u kei1110`（エラーを待たない — 別 identity で PR を作ると 2 つの identity が公開物で結びつく）

## レビュアー起動トリガー表（.claude/agents/・読み取り専用・DEVELOPMENT_WORKFLOW「マージ前最終」の正本・各 agent frontmatter が参照するトリガー SSOT）

スライスが**実際に触れた面**（`git diff main...HEAD --name-only`）から導出する。複数行に該当したら**該当レビュアーをすべて**起動:

| 触れた面（diff で判定） | 必須アクション（merge 前） |
|---|---|
| app/models / app/jobs / db/migrate / Devise・テナント解決まわりの config | `tenant-isolation-reviewer`（§3.6） |
| app/calculators / compliance / OrganizationSetting / 残業・割増・36 協定・有給・産業医面談 | `labor-law-compliance-reviewer`（§8）+ `/legal-citation-audit` |
| 状態 enum の追加・変更 / Approvable / ApprovalAssignment / ApplyApproval / AASM / 撤回・締め | `approval-engine-reviewer`（§7・§13・副作用 atomicity） |
| フェーズ完了時・リリース候補 merge 前 | `/spec-check`（SPEC ↔ 実装の乖離） |

## フック（.claude/settings.json → scripts/claude-hooks/・有効）

挙動の正は各スクリプト冒頭コメント。BLOCKED / TENANT-SAFETY メッセージが出たら**メッセージの指示に従う**（回避策を探さない）:
- **block 系（PreToolUse・中断）**: `guard-git-identity`（kei1110/`github-kei1110` remote 以外の commit/push）・`block-secrets`（master.key/credentials 鍵/.env）・`block-schema-edit`（db/schema.rb）・`block-gemfile-lock-edit`（Gemfile.lock）
- **警告系（PostToolUse・フィードバック）**: `check-tenant-scope`（models の `acts_as_tenant` 欠落）・`check-job-tenant-wrap`（jobs の `with_tenant` 未ラップ・非ディスパッチャのみ）— いずれも §3.6
- **整形系（PostToolUse・常に exit 0）**: `rubocop-autoformat`（.rb 自動整形）・`regen-spec-index`（SPEC.md 冒頭索引の行番号補正）

## Gotchas（環境固有・非自明）

> 挙動上の禁止則は冒頭「鉄則」に集約済み。ここは環境まわりの罠のみ。実装・テストの罠台帳は docs/RAILS_GOTCHAS.md。

- **OpenSSL:** 旧記述「`~/.zshrc` に Intel 時代の openssl@1.1 残存」は**解消済み**（2026-07-13 実測: ログインシェル環境に OPENSSL/LDFLAGS 等の汚染なし・brew は openssl@3 のみ）。Ruby ビルドは素の `rbenv install` で可。万一他環境で openssl エラーが出たら `docs/superpowers/plans/2026-06-14-ruby-4-0-2-upgrade.md` の回避策を参照
- **rails MCP:** `rails-mcp-server`（rbenv shim）は cwd の `.ruby-version` で Ruby を解決 → プロジェクト直下で起動されること。**Ruby アップグレード時は新 Ruby へ `gem install rails-mcp-server` で入れ直す**（Bundler 管理外の実行系ツールゆえ bundle では追従しない。怠ると `/mcp` が `Failed to reconnect: -32000` で死ぬ。詳細は docs/RAILS_GOTCHAS.md「Ruby / ツールチェーン」）
- 親 `/Users/Eoh/CLAUDE.md` は chezmoi dotfiles 用で本プロジェクトとは無関係（自動ロードされるが従わない）

## ワークフロー
実装は SPEC §15 のフェーズを docs/ROADMAP.md のスライス（1 スライス = 1 ブランチ = 1 PR・squash マージ）で進める。各スライスは brainstorm →（大物は specs/ に設計 + 多視点レビュー）→ writing-plans → 実装 → `/preflight` → PR。**PR に ROADMAP の該当行更新（チェック + PR 番号）を含めてからマージ**。設計・計画は docs/superpowers/{specs,plans}/ に日付付きで蓄積。現在地と次の一歩は ROADMAP が正。

**サブエージェント運用の 4 か条**（フックはサブエージェントをすり抜けるため指示で補う）:
1. ステップ完了ごとに**即コミット**（セッション上限による中断でもステージ未満の状態を残さない）
2. 探索で触ったが不要だった編集は **revert してから報告**（デバッグ痕を成果に混ぜない）
3. 完了条件に検証コマンドを明記 — `bundle exec rspec`・`bundle exec rubocop`、app/ に触れたら `bin/brakeman --no-pager` も
4. **レビュアーは読み取り専用に固定**（implementer とワークツリーを共有するため）— 「編集も rspec 実行も禁止・判別性は静的読解で論証せよ」と明示する。実証が要るなら `isolation: "worktree"` で隔離。implementer には「衝突を検出したら上書きせず即報告」を指示（4-2c-2 でレビュアーが共有ツリーを mutation・implementer の報告で実害ゼロ）
- 計画・レビューのプロンプトには docs/RAILS_GOTCHAS.md を注入する（罠の再購入防止）
