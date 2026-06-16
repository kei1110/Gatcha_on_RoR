# PostgreSQL 17 → 18 アップグレード設計 — クリーン再生成・17 退場・1 PR

> 対象: ローカル開発環境（Homebrew postgresql@17 → @18）／ CLAUDE.md・README・MCP_SETUP・CI の環境記述（17 → 18）。勤怠ドメインのロジックには非該当（ツールチェーン/環境のみ）
> 体制: 軽量 chore スライス。models/jobs/migration を新設せず、labor-law / tenant-isolation レビューは不要（コンプラ・テナント分離に触れない）。Ruby 4.0.2 アップグレード（PR #27/#28・[[ruby-4-0-2-verified]]）と同型
> ユーザー決定（2026-06-16）: **クリーン再生成**（17 の data dir を移行せず・dev/test を migrate + seed で作り直す）／ 検証後に **postgresql@17 を完全退場**（uninstall + data dir 削除）
> 補正（2026-06-16・実測）: 当初「17 を消すと pg gem が dyld 死／再ビルド必須」と想定したが、`otool -L` で **precompiled pg gem は libpq を自前同梱・Homebrew libpq 非依存**と判明。再ビルド不要（§0・§2）。

## §0 方針・前提

- **「アップグレード」の実体はローカル開発機の PostgreSQL のみ。** 本番 `database.yml` は接続情報だけでサーバ版に非依存ゆえ変更不要。残る前進はローカルの 17.10 → 18.4。
- **データは dev/test の 75M のみ・本番不在。** Phase 0b の段階で、`gatcha_development` / `gatcha_test` は migration + seed から再生成できる。ゆえに pg_upgrade（in-place）や dump & restore のデータ温存は不要 → **クリーン再生成**が最小リスク。
- **17 と 18 は同一ポート 5432 を奪い合う。** 17 を `brew services stop` してから 18 を start する順序が前提（§2）。
- **`pg` gem は libpq を自前同梱しており再ビルド不要（実測）。** 本機が使う precompiled `pg-1.6.3-arm64-darwin` を `otool -L` で検査した結果、外部リンクは gem 同梱の `@loader_path/../../ports/arm64-darwin/lib/libpq-ruby-pg.1.dylib`（current version **5.18.0 = PG18 世代**）と `/usr/lib/libSystem` のみ。**Homebrew の libpq を一切参照しない**。ゆえに postgresql@17 を uninstall しても `require "pg"` は dyld 死せず、gem 再ビルドは不要。サーバ版差はワイヤプロトコル互換で吸収される。※ `bundle config force_ruby_platform true` で source 版へ切替えた場合のみ Homebrew libpq 依存に戻るが、本機は precompiled を使用ゆえ非該当。この「自前同梱」事実自体を RAILS_GOTCHAS に記録する。
- **既知の罠 `RAILS_GOTCHAS.md:149-154` は「PG 17.10 で直接プローブして確認」した代物。** 18 で `pg_get_constraintdef` の括弧挙動が変われば回避策が崩れ得るため、18 上での再プローブを受け入れ条件に含める（§4）。

## §1 スコープ

**含む:**
1. **postgresql@18 導入・起動** — `brew install postgresql@18`（keg-only・18.4）→ `brew services stop postgresql@17` → `brew services start postgresql@18`（新クラスタ初期化・5432）。
2. **`pg` gem の 18 接続確認**（再ビルド不要） — 自前 libpq 同梱を実測済（§0）。`require "pg"` ロードと 18 への接続を rails コマンド／rspec 経由で確認するのみ。
3. **DB 再生成** — `bin/rails db:create db:migrate db:seed`（dev）＋ `RAILS_ENV=test bin/rails db:create db:schema:load`（test）。seed は §3 の通り自前で tenant 文脈を張るため追加対応不要。
4. **postgresql@17 完全退場** — §4 の検証が緑になった後に `brew services stop` → `brew uninstall postgresql@17` → data dir（`/opt/homebrew/var/postgresql@17`・75M）削除 → **退場後に再度 rspec 緑**で pg gem 生存を実証。
5. **生きた参照の 18 化** — `CLAUDE.md:20` / `README.md:36-37`（PostgreSQL 行）/ `docs/MCP_SETUP.md:11,42,44`（psql PATH も `/opt/homebrew/opt/postgresql@18/bin` へ）／ `.github/workflows/ci.yml:34` の `postgres:17→18` ／ `docs/RAILS_GOTCHAS.md` に「18 再検証」と「pg gem 自前同梱」を verified 日付付きで追記。
6. **docs** — ROADMAP 横断バックログ追記（✓ + PR#・Ruby #27/#28 の隣）／ 本設計書。

**含まない（非スコープ）:**
- `docs/superpowers/plans/2026-06-10-phase0a-foundation.md:216` の `image: postgres:17` — **完了済み履歴の記録**。当時の事実ゆえ改変せず保存（生きた CI だけ 18 へ）。
- 本番 `database.yml` の変更 — サーバ版非依存・不要。
- `README.md:35` / `docs/MCP_SETUP.md:29` の "Ruby 3.3.11" 表記 — Ruby アップグレード（#27）由来の別件 staleness。PG とは独立ゆえ本 PR では原則触れない（実装時に同一ブロック内なら付随修正可否をユーザー確認）。
- PG 18 新機能（並列 GIN・skip scan・OAuth 等）の活用 — 別関心。本スライスは「版を上げ、緑を保つ」のみ。

## §2 実行順序の技術的含意

順序の核は **(a) ポート 5432 衝突の回避** と **(b) 不可逆点（17 退場）を緑確認の後ろに置くこと**。当初想定した「pg gem 再ビルドを 17 退場前に」という制約は、§0 の実測（自前 libpq 同梱）により**解消**した。

```
0. bundle exec rspec                     # 17 上でベースライン緑と example 数を記録（後の同値判定の基準）
A. brew install postgresql@18            # 18 を入れる（17 はまだ生きている）
B. brew services stop postgresql@17      # 5432 を解放（衝突回避）
C. brew services start postgresql@18     # 新クラスタ初期化・5432 を奪取
   → /opt/homebrew/opt/postgresql@18/bin/psql -d postgres -tAc "show server_version;" == 18.x
D. DB 再生成（§1-3）
E. bundle exec rspec 緑（step 0 と同値）＋ §4 の罠再プローブ
F. ここで初めて brew uninstall postgresql@17 ＋ data dir 削除   ← 唯一の不可逆点
G. bundle exec rspec 緑（17 退場後）      # pg gem が Homebrew libpq 非依存で生存することを実証
```

**なぜ F が E の後か:** F（17 uninstall + data dir 削除）が唯一の不可逆点。E までは 17 が健在なので、何かあれば `brew services start postgresql@17` で原状復帰できる。pg gem は自前 libpq 同梱ゆえ F の前後どちらでも動くが、退場という不可逆操作は緑を確認してからのみ行う。G は「17 非依存」の実証を兼ねた最終ゲート。

## §3 seed と tenant 文脈

- `db:migrate` は tenant-scoped モデルを query しないため `ActsAsTenant` 不要。
- `db:seed` は **seeds.rb 自身が `ActsAsTenant.with_tenant(org)` でラップ済み**（`db/seeds.rb:20`・SPEC §3.6 準拠）。ゆえに `bin/rails db:seed` 単体で tenant 文脈が成立し、手動の `ActsAsTenant.current_tenant` 設定は不要。seed は `SEED_PASSWORD` 未指定時に自動生成パスワードを stdout に出す（dev/test 専用・本番は abort）。

## §4 検証（受け入れ条件）

18 上で以下が全て緑であること:

- `show server_version;` が 18.x（18.4）を返す。
- `bundle exec rspec` — step 0 で記録したベースラインと**同数の examples が 0 failures**（17→18 で増減なし）。
- **`RAILS_GOTCHAS.md:149-154` の罠を 18 で再プローブ** — psql で一時表に exclusion constraint を 2 種張り、`pg_get_constraintdef` の括弧数を直接観察する:
  ```sql
  CREATE TEMP TABLE _probe (a boolean, b int);
  ALTER TABLE _probe ADD CONSTRAINT _p_bare EXCLUDE (b WITH =) WHERE (a);
  ALTER TABLE _probe ADD CONSTRAINT _p_expr EXCLUDE (b WITH =) WHERE (b > 1);
  SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conname LIKE '_p_%';
  ```
  期待（17 と同じなら回避策据え置き）: 裸カラム `WHERE (a)` は単一括弧、演算子式 `WHERE ((b > 1))` は二重括弧。**加えて** `RAILS_ENV=test bin/rails db:schema:load` が UserWorkPattern の exclusion constraint をラウンドトリップできること（壊れれば schema:load が `PG::UndefinedColumn` 等で確実に落ちる）。挙動が変われば `config/initializers/rails_exclusion_constraint_where_fix.rb` と GOTCHAS を同 PR で更新。変わらなければ「PG 18.4 でも同挙動」を verified 追記。
- `bundle exec rspec`（17 退場後・§2-G）も緑 — pg gem の Homebrew libpq 非依存を実証。
- docs/CI 変更が app に波及した場合の保険として `bundle exec rubocop --force-exclusion`／`bin/brakeman --no-pager`（今回は docs/CI 中心ゆえ通常 no-op）。
- 仕上げに `/preflight`。

## §5 コミット分割（1 PR・環境作業は緑確認を完了条件に）

| # | 内容 | 検証ゲート |
|---|---|---|
| C1 | 設計書（本書） | — |
| C2 | （環境のみ・差分なし）18 導入・17 stop・18 start・DB 再生成 → rspec 緑（§2 step 0〜E） | `show server_version`==18・rspec 緑（ベースライン同値） |
| C3 | `docs/RAILS_GOTCHAS.md` に「PG18 罠 152 再検証結果」＋「pg gem 自前 libpq 同梱」を verified 追記 | §4 プローブ結果が確定 |
| C4 | （環境のみ・差分なし）17 退場（uninstall + data dir 削除）→ rspec 緑（§2-G） | 退場後 rspec 緑（pg 生存実証） |
| C5 | docs/CI: `CLAUDE.md`・`README.md`・`MCP_SETUP.md`（PATH 含む）・`ci.yml`（postgres:18）・`ROADMAP`（✓ + PR#） | CI YAML 構文確認・grep で 17 残存ゼロ |

> 環境作業（C2/C4）はリポジトリ差分を生まないため、コミットされるのは C1/C3/C5 の 3 系統。各環境ステップは緑確認を完了条件とする。

## §6 変更ファイル

`docs/superpowers/specs/2026-06-16-postgres-18-upgrade-design.md`（本書）/ `docs/RAILS_GOTCHAS.md`（罠 152 の 18 再検証 + pg gem 同梱の記録）/ `CLAUDE.md` / `README.md` / `docs/MCP_SETUP.md` / `.github/workflows/ci.yml` / `docs/ROADMAP.md`

> 環境側（brew・data dir・DB）はリポジトリ外。pg gem は再ビルド不要ゆえ `Gemfile.lock` も不変。コミットされるのは上記 docs/CI のみ。

## §7 リスク・前提・ロールバック

- **ポート 5432 衝突**（§2-B/C）— stop 17 → start 18 の順序で回避。
- **`pg_get_constraintdef` 括弧挙動の 18 変化**（§4）— 既存の schema dump round-trip が壊れると `db:schema:load` や test が落ちる形で**確実に検出**される。緑 suite が安全網。
- **pg gem は再ビルド不要**（§0 実測）— 自前 libpq 同梱ゆえ 17 退場後も生存（§2-G で実証。`force_ruby_platform` 時の例外は §0）。
- **postgres MCP の再接続** — DB 名・ポート不変ゆえ恐らく自動復帰。要すれば `/mcp` 再接続。**rails MCP は Ruby 依存ゆえ無関係**。
- **psql keg-only PATH の取り違え** — 退場前は 17/18 が併存し PATH 衝突の温床。`/opt/homebrew/opt/postgresql@18/bin` をフルパス指定で扱い、退場（F）後に docs の PATH 記述を 18 一本化（C5）。
- **ロールバック方針** — F（17 uninstall + data dir 削除）が唯一の不可逆点。それ以前は 17 が健在なので、17 を再 start すれば原状復帰できる。F は §4 緑を確認してからのみ実行。
