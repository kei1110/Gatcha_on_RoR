# PostgreSQL 17 → 18 アップグレード Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ローカル開発機の PostgreSQL を 17.10 → 18.4 へ、dev/test DB をクリーン再生成して移行し、17 を完全退場させ、リポジトリの生きた版記述を 18 へ揃える。

**Architecture:** データ温存せず（dev/test 75M は migrate+seed で再生成）。順序の核は (a) ポート 5432 衝突回避（stop 17 → start 18）、(b) 不可逆点（17 退場）を全検証緑の後ろに固定。pg gem は libpq 自前同梱で再ビルド不要（`otool -L` 実測済・設計 §0）。

**Tech Stack:** Homebrew postgresql@18 (keg-only) / Rails 8.1.3 / pg gem 1.6.3 (precompiled arm64-darwin) / fx + 自前 exclusion-constraint patch。

**設計参照:** `docs/superpowers/specs/2026-06-16-postgres-18-upgrade-design.md`（§0 pg gem 同梱の実測・§2 実行順序・§4 受け入れ条件）

**前提:** 作業ブランチ `chore/postgres-18` 上（作成済・identity kei1110）。設計書は commit 済（C1）。

---

## Task 1: PG17 ベースライン記録

**Files:** なし（記録のみ）

- [ ] **Step 1: 現行 17 で suite 緑と example 数を記録**

Run:
```bash
cd /Users/Eoh/workspace/Gatcha_on_RoR && bundle exec rspec 2>&1 | tail -3
```
Expected: `NNN examples, 0 failures`（NNN を控える＝ Task 3/5 の同値判定の基準）。0 failures でなければ**ここで中断**し原因を調査（17→18 と無関係の既存破損を持ち込まない）。

- [ ] **Step 2: 現行版を確認**

Run:
```bash
/opt/homebrew/opt/postgresql@17/bin/psql -d postgres -tAc "show server_version;"
```
Expected: `17.10 (Homebrew)`

> このタスクはコミット無し（記録のみ）。控えた example 数を以降のゲートで使う。

---

## Task 2: PG18 導入・起動・版確認

**Files:** なし（環境作業・リポジトリ差分なし）

- [ ] **Step 1: postgresql@18 を導入**

Run:
```bash
brew install postgresql@18
```
Expected: `18.4` が keg-only で導入される。post_install で `/opt/homebrew/var/postgresql@18` に initdb 済みになる想定。

- [ ] **Step 2: 17 を停止して 5432 を解放**

Run:
```bash
brew services stop postgresql@17
```
Expected: `Stopping postgresql@17... (successful)`

- [ ] **Step 3: 18 を起動**

Run:
```bash
brew services start postgresql@18
```
Expected: `Successfully started postgresql@18`。
失敗（data dir 未初期化）時のみ: `/opt/homebrew/opt/postgresql@18/bin/initdb --locale=C -E UTF-8 /opt/homebrew/var/postgresql@18` を実行してから再 start。

- [ ] **Step 4: サーバ版が 18 であることを確認**

Run:
```bash
/opt/homebrew/opt/postgresql@18/bin/psql -d postgres -tAc "show server_version;"
```
Expected: `18.4 (Homebrew)`（18.x であること）

> 環境作業ゆえコミット無し。

---

## Task 3: dev/test DB をクリーン再生成

**Files:** なし（DB 再生成・`db/schema.rb` は不変であるべき）

- [ ] **Step 1: dev/test データベースを作成**

Run:
```bash
cd /Users/Eoh/workspace/Gatcha_on_RoR && bin/rails db:create
```
Expected: `Created database 'gatcha_development'` と `Created database 'gatcha_test'`（既存なら "already exists" にならず新規作成）。

- [ ] **Step 2: dev を migrate**

Run:
```bash
bin/rails db:migrate
```
Expected: 全 migration が `migrated` で通る。exclusion constraint・fx トリガーの migration も成功。

- [ ] **Step 3: schema.rb が PG18 で変化しないことを確認（罠 152 の一次検出）**

Run:
```bash
git diff --stat db/schema.rb
```
Expected: **差分なし**（出力空）。もし差分が出たら PG18 で `pg_get_constraintdef` の出力が変わった疑い＝罠 152 が再発。Task 4 のプローブで確定し、`config/initializers/rails_exclusion_constraint_where_fix.rb` を修正してから先へ進む（差分は revert せず原因を潰す）。

- [ ] **Step 4: dev に seed 投入**

Run:
```bash
bin/rails db:seed
```
Expected: `==> Acme: 3 users ...` / `==> Globex: 3 users ...`（seeds.rb が自前で `ActsAsTenant.with_tenant` を張るため tenant 文脈エラーは出ない）。自動生成パスワードが stdout に出るのは正常。

- [ ] **Step 5: test DB に schema をロード**

Run:
```bash
bin/rails db:test:prepare
```
Expected: エラーなく完了（schema.rb のラウンドトリップ成功＝ exclusion constraint + create_trigger が PG18 で load 可能）。

> 環境作業ゆえコミット無し。

---

## Task 4: PG18 検証（受け入れ条件）＋ GOTCHAS 追記

**Files:**
- Modify: `docs/RAILS_GOTCHAS.md`（罠 152 の 18 再検証 + pg gem 自前同梱の記録）
- 条件付き Modify: `config/initializers/rails_exclusion_constraint_where_fix.rb`（プローブで挙動変化が判明した場合のみ）

- [ ] **Step 1: suite を 18 上で実行（ベースライン同値）**

Run:
```bash
cd /Users/Eoh/workspace/Gatcha_on_RoR && bundle exec rspec 2>&1 | tail -3
```
Expected: `NNN examples, 0 failures`（Task 1 Step 1 で控えた NNN と**同数**・0 failures）。pg gem が 18 サーバへ問題なく接続できている証左でもある。

- [ ] **Step 2: 罠 152 を PG18 で直接プローブ**

Run:
```bash
/opt/homebrew/opt/postgresql@18/bin/psql -d gatcha_development <<'SQL'
CREATE TEMP TABLE _probe (a boolean, b int);
ALTER TABLE _probe ADD CONSTRAINT _p_bare EXCLUDE (b WITH =) WHERE (a);
ALTER TABLE _probe ADD CONSTRAINT _p_expr EXCLUDE (b WITH =) WHERE (b > 1);
SELECT conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conname LIKE '_p_%' ORDER BY conname;
SQL
```
Expected（17 と同一なら回避策据え置き）:
- `_p_bare` → `... WHERE (a)`（**単一**括弧）
- `_p_expr` → `... WHERE ((b > 1))`（**二重**括弧）

判定:
- **17 と同じ** → 回避策（`from(1).to(-2)`）は有効。initializer 変更なし。GOTCHAS に「PG 18.4 でも同挙動・回避策据え置き」を verified 追記。
- **挙動が変化**（括弧数が違う）→ `config/initializers/rails_exclusion_constraint_where_fix.rb` の剥がし幅を新挙動に合わせて修正し、Task 3 Step 3 の `git diff db/schema.rb` が空に戻ること・`bin/rails db:test:prepare` が通ることを再確認。GOTCHAS に新挙動と修正を記録。

- [ ] **Step 3: GOTCHAS に PG18 再検証と pg gem 同梱を追記**

`docs/RAILS_GOTCHAS.md` の罠 152 ブロック（`### Rails 8 の exclusion constraint ...`）の `verified:` 行を更新し、PG18 結果を併記する。例（Step 2 が「同挙動」の場合）:
```
- verified: Rails 8.1.3 / PostgreSQL 17.10 / 2026-06-12（0b-4 Task 2 で発覚・レビューで診断訂正）。**PG 18.4 でも同挙動を直接プローブで再確認（2026-06-16・裸カラム単一括弧／演算子式二重括弧）— 回避策据え置き。**
```
さらに「DB / マイグレーション」節へ新規エントリを追加（pg gem 自前 libpq 同梱の事実）:
```
### precompiled な pg gem は libpq を自前同梱し Homebrew libpq に非依存（メジャー版アップで再ビルド不要）

- **WHAT**: Homebrew PostgreSQL をメジャーアップ（17→18）しても、`pg` gem の再ビルドは不要。
- **WHY**: 本機が使う precompiled `pg-1.6.3-arm64-darwin` を `otool -L` で検査すると、外部リンクは gem 同梱の `@loader_path/../../ports/arm64-darwin/lib/libpq-ruby-pg.1.dylib`（5.18.0 = PG18 世代）と `/usr/lib/libSystem` のみで、`/opt/homebrew/.../postgresql@NN/lib/libpq.dylib` を一切参照しない。サーバ版差はワイヤプロトコル互換で吸収される。
- **HOW**: メジャーアップ時は server を入れ替えるだけでよい。`bundle config force_ruby_platform true` で source 版へ切替えた場合のみ Homebrew libpq 依存に戻るため、その時だけ `@NN/bin/pg_config` で再ビルドが要る。確認は `otool -L "$(find "$(bundle show pg)" -name '*.bundle' | head -1)"`。
- verified: pg 1.6.3 (arm64-darwin) / PostgreSQL 18.4 / 2026-06-16（PG17→18 アップグレードで実測）
```

- [ ] **Step 4: GOTCHAS をコミット（C3）**

Run:
```bash
git add docs/RAILS_GOTCHAS.md config/initializers/rails_exclusion_constraint_where_fix.rb 2>/dev/null; git add docs/RAILS_GOTCHAS.md
git commit -m "docs: PG18 で exclusion-constraint 罠を再検証＋pg gem 自前 libpq 同梱を台帳化

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
Expected: コミット成功。initializer を変更していなければ GOTCHAS のみがステージされる。

---

## Task 5: PG17 完全退場＋退場後の生存実証

**Files:** なし（環境作業・不可逆点）

- [ ] **Step 1: 退場の前提を確認（ここが唯一の不可逆点）**

Task 4 Step 1 の rspec が緑であることを再確認してから進む。緑でなければ退場しない（`brew services start postgresql@17` で原状復帰できる猶予を残す）。

- [ ] **Step 2: 17 を停止・アンインストール**

Run:
```bash
brew services stop postgresql@17 2>/dev/null; brew uninstall postgresql@17
```
Expected: `Uninstalling postgresql@17 ...`（成功）。

- [ ] **Step 3: 17 の data dir を削除**

Run:
```bash
rm -rf /opt/homebrew/var/postgresql@17
```
Expected: 無出力（75M 解放）。

- [ ] **Step 4: 17 退場後も pg gem が生存することを実証**

Run:
```bash
cd /Users/Eoh/workspace/Gatcha_on_RoR && bundle exec rspec 2>&1 | tail -3
```
Expected: `NNN examples, 0 failures`（Task 1 と同数）。**Homebrew libpq 非依存（自前同梱）の実証**＝設計 §2-G。失敗（dyld error 等）なら設計の前提が崩れているので即調査。

- [ ] **Step 5: 残存確認**

Run:
```bash
brew list --versions | grep -i postgres; ls /opt/homebrew/var/ | grep -i postgres
```
Expected: `postgresql@18 18.4` のみ。`postgresql@17` も `var/postgresql@17` も無い。

> 環境作業ゆえコミット無し。

---

## Task 6: 生きた参照を 18 へ書き換え（docs/CI）

**Files:**
- Modify: `CLAUDE.md:20`
- Modify: `README.md:36-37`
- Modify: `docs/MCP_SETUP.md:11,42,44`
- Modify: `.github/workflows/ci.yml:34`
- Modify: `docs/ROADMAP.md`（横断バックログに完了行追記）

- [ ] **Step 1: CLAUDE.md の Postgres 行**

`CLAUDE.md:20` を置換:
- 旧: `- **Postgres:** 17（`brew services` 常駐）。DB `gatcha_development` / `gatcha_test` 作成済み。psql は keg-only → `/opt/homebrew/opt/postgresql@17/bin``
- 新: `- **Postgres:** 18（`brew services` 常駐）。DB `gatcha_development` / `gatcha_test` 作成済み。psql は keg-only → `/opt/homebrew/opt/postgresql@18/bin``

- [ ] **Step 2: README.md のセットアップ前提**

`README.md:36-37` を置換:
- 旧: `#       PostgreSQL 17（brew services start postgresql@17）` / `#       psql は keg-only → PATH に /opt/homebrew/opt/postgresql@17/bin`
- 新: `#       PostgreSQL 18（brew services start postgresql@18）` / `#       psql は keg-only → PATH に /opt/homebrew/opt/postgresql@18/bin`

> 注: `README.md:35` の "Ruby 3.3.11" は Ruby #27 由来の別件 staleness（設計 非スコープ）。ユーザー判断が無ければ本 PR では触れない。

- [ ] **Step 3: docs/MCP_SETUP.md の 3 箇所**

置換:
- L11: `✅ 接続済み（Postgres 17 常駐・`gatcha_development`）` → `✅ 接続済み（Postgres 18 常駐・`gatcha_development`）`
- L42: `- Postgres 17 が `brew services` で常駐済み。` → `- Postgres 18 が `brew services` で常駐済み。`
- L44: `keg-only パス `/opt/homebrew/opt/postgresql@17/bin`` → `keg-only パス `/opt/homebrew/opt/postgresql@18/bin``

> 注: `docs/MCP_SETUP.md:29` の "Ruby 3.3.11" も別件 staleness（非スコープ）。

- [ ] **Step 4: CI の postgres service image**

`.github/workflows/ci.yml:34` を置換:
- 旧: `        image: postgres:17`
- 新: `        image: postgres:18`

- [ ] **Step 5: ROADMAP 横断バックログに完了行を追記**

`docs/ROADMAP.md` の YJIT 行（`- [x] **YJIT 有効化 ...**（PR #28）...`）の直後に追加:
```
- [x] **PostgreSQL 17→18 アップグレード**（PR #XX）: ローカル開発機を 17.10→18.4。dev/test はクリーン再生成（data dir 非移行）、17 は完全退場。pg gem は libpq 自前同梱で再ビルド不要（otool 実測）。exclusion-constraint 罠を PG18 で再プローブ。設計 `docs/superpowers/specs/2026-06-16-postgres-18-upgrade-design.md`
```
（`#XX` は PR 採番後に更新）

- [ ] **Step 6: 17 残存がリポジトリから消えたことを確認**

Run:
```bash
cd /Users/Eoh/workspace/Gatcha_on_RoR && grep -rn "postgresql@17\|postgres:17\|Postgres 17\|PostgreSQL 17" --include="*.md" --include="*.yml" . | grep -v "docs/superpowers/specs/2026-06-16\|docs/superpowers/plans/2026-06-16\|docs/superpowers/plans/2026-06-10\|RAILS_GOTCHAS"
```
Expected: **出力空**（生きた doc/CI から 17 が消えた。設計書/本計画書の "17→18" 記述・履歴 plan・GOTCHAS の歴史 verified 行は対象外ゆえ除外済）。

- [ ] **Step 7: CI YAML 構文確認**

Run:
```bash
ruby -ryaml -e "YAML.load_file('.github/workflows/ci.yml'); puts 'ci.yml OK'"
```
Expected: `ci.yml OK`

- [ ] **Step 8: docs/CI をコミット（C5）**

Run:
```bash
git add CLAUDE.md README.md docs/MCP_SETUP.md .github/workflows/ci.yml docs/ROADMAP.md
git commit -m "docs: 環境記述・CI の PostgreSQL を 18 へ更新（17 退場後）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
Expected: コミット成功。

---

## Task 7: preflight ＋ PR

**Files:** なし（最終検証＋PR 作成）

- [ ] **Step 1: preflight（CI 等価の静的検証）**

`/preflight` を実行。Expected: 全ゲート緑（今回は docs/CI 中心ゆえ rubocop/brakeman は no-op に近い。rspec は PG18 上で緑）。

- [ ] **Step 2: PR 作成**

Run（必要なら先に `gh auth switch -u kei1110`）:
```bash
git push -u origin chore/postgres-18
gh pr create --base main --title "chore: PostgreSQL 17 → 18 アップグレード（クリーン再生成・17 退場）" --body "$(cat <<'EOF'
## 概要
ローカル開発機の PostgreSQL を 17.10 → 18.4 へ。dev/test はクリーン再生成（data dir 非移行）、17 は完全退場。設計 `docs/superpowers/specs/2026-06-16-postgres-18-upgrade-design.md`。

## 実測の要点
- **pg gem は再ビルド不要**: precompiled `pg-1.6.3-arm64-darwin` は libpq を自前同梱（`otool -L` で Homebrew libpq 非依存を確認）。17 退場後も rspec 緑で実証。
- **exclusion-constraint 罠（GOTCHAS 152）を PG18 で再プローブ**: 結果を台帳に追記。
- リポジトリ差分は docs/CI のみ（`Gemfile.lock` 不変）。

## 検証
- `bundle exec rspec` 緑（17→18 で example 数同値・17 退場後も緑）
- `git diff db/schema.rb` 空（PG18 で schema dump 不変）
- `bin/rails db:test:prepare` ラウンドトリップ成功
- `/preflight` 緑

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```
Expected: PR 作成成功。PR 採番後、`docs/ROADMAP.md` の `#XX` を実番号へ更新して追コミット（Task 6 Step 5）。

- [ ] **Step 3: ROADMAP の PR 番号確定**

PR 番号が判明したら `docs/ROADMAP.md` の `（PR #XX）` を実番号に置換しコミット・push。

---

## Self-Review 結果

- **Spec coverage:** 設計 §1（スコープ 1-6）→ Task 2-3（導入/再生成）・Task 4（pg 接続確認 §1-2・検証 §4）・Task 5（17 退場 §1-4）・Task 6（参照 18 化 §1-5・ROADMAP §1-6）・Task 1（§2 step 0 ベースライン）で網羅。§3 seed tenant 文脈 → Task 3 Step 4。§7 ロールバック → Task 5 Step 1 の不可逆点ガード。
- **Placeholder scan:** `#XX`（PR 番号）は採番後確定する正当な未定値（Task 7 Step 3 で解消）。他に TBD/TODO なし。
- **Type/コマンド consistency:** psql は一貫して `/opt/homebrew/opt/postgresql@18/bin/psql` フルパス。example 数 NNN は Task 1 で確定し Task 4/5 で同値判定。罠プローブの SQL は設計 §4 と一致。
