# Ruby 4.0.2 アップグレード設計 — 直行・1 PR

> 対象: docs/ROADMAP.md 横断バックログ（新規）／ CLAUDE.md スタック（Ruby 3.3.11 → 4.0.2）。勤怠ドメインのロジックには非該当（言語/ツールチェーンのみ）
> 体制: 軽量スライス。models/jobs/migration を新設せず、labor-law / tenant-isolation レビューは不要（コンプラ・テナント分離に触れない）
> 前提: 本設計に先立ち **2026-06-14 に 4.0.2 を実機検証済み**（rspec 523/0・rubocop 181/0・brakeman 0・C 拡張ロード可）。詳細は本書 §4。memory: `ruby-4-0-2-verified.md`
> ユーザー決定（2026-06-14）: **直行**（3.3.11 → 4.0.2・段階 3.4 を経由しない）／ スコープに **bundler 4.x bump・`gem "cgi"`・frozen_string_literal 一括付与**を含む／ **YJIT 有効化と 4.0.5 追従は非スコープ**（別 PR）

## §0 方針・前提

- **「アップグレード」の実体は Ruby のみ。** 本リポジトリは初手から Rails 8.1.3 native（`config.load_defaults 8.1`）で、Rails 側に移行作業は無い。残る唯一の前進が Ruby 3.3.11 → 4.0.2。
- **Ruby 4.0 は記念リリースで破壊的変更は最小限**（Matz 方針）。コードベースの露出を全方位 grep した結果、hard error 化する該当は皆無（§3）。frozen string も 4.0 では chilled = 警告のみで raise しない（一次情報 3 系統で確認・実測でも 0 警告）。
- **検証済みの版（4.0.2）にピンする。** 最新は 4.0.5 だが、実機 green を確認したのは 4.0.2。安全側に倒し、4.0.5 追従は別途バックログへ。
- **本番/Docker は影響を受けない論点が一つある（libvips）。** ローカル開発機のみ libvips 未導入で `require "vips"` が失敗するが、これは 3.3.11 でも同一に失敗する**環境要因**であり Ruby 4.0 の回帰ではない。Dockerfile は base/build 両ステージで `libvips` を導入済み、かつ Gemfile は `ruby-vips: require: false`（variant 使用時のみ遅延ロード）ゆえ boot・suite に無影響。

## §1 スコープ

**含む:**
1. **コア version bump** — `.ruby-version`（3.3.11 → 4.0.2）+ `Dockerfile` の `ARG RUBY_VERSION`（3.3.11 → 4.0.2）。CI の `ruby/setup-ruby@v1` は `ruby-version` 無指定ゆえ `.ruby-version` を自動追従（3 ジョブとも）。
2. **bundler 4.x bump** — `.ruby-version` を 4.0.2 にした上で `bundle install` を回すと、同梱 bundler 4.0.6 が `Gemfile.lock` の `BUNDLED WITH` を 2.5.22 → 4.0.6 へ更新（独立作業ではなく version bump に内包）。Ruby 4.0 の rubygems と 2.5.22 が起こす `Gem::Platform::* already initialized` 警告を解消。
3. **`gem "cgi"` 予防追加** — Ruby 4.0 で `cgi` は default gem から削除（`cgi/escape` のみ残存）。本 app は CGI 直接利用ゼロだが、将来の依存追加に対する安価な保険（rails/rails#56457 の定番落とし穴）。`csv` に倣い悲観ピン。
4. **frozen_string_literal 一括付与** — `.rubocop.yml` で `Style/FrozenStringLiteralComment: Enabled: true` にし、`rubocop -a` で対象 `.rb`（約 80 ファイル）へ磁気コメント付与。**§2 の mutation 監査を伴う**。
5. **docs** — ROADMAP 横断バックログ追記（✓ + PR#）／ RAILS_GOTCHAS に「Ruby 4.0 移行の罠」verified 追記／ 本設計書。

**含まない（非スコープ）:**
- YJIT 有効化（`RUBY_YJIT_ENABLE` 等）— ベンチ検証が別関心。別 PR。
- Ruby 4.0.5 への追従 — 検証済み 4.0.2 を採る。バックログへ。
- libvips のローカル導入 — 環境作業であってコード変更ではない（手順は GOTCHAS に記録）。

## §2 frozen_string_literal の技術的含意（最重要の注意点）

磁気コメント付与は「無害な装飾」ではない。Ruby 4.0 の chilled string は mutation 時に**警告のみ**だが、`# frozen_string_literal: true` を付けた瞬間その文字列は**真に freeze** され、mutation は**即 FrozenError（hard error）**になる。したがって 80 ファイル付与は実質「全ファイルの文字列リテラル mutation 監査」である。

**安全手順:**
1. `rubocop -a` で磁気コメントを一括付与。
2. **付与後の状態で全 suite を再実行**（523 examples）。FrozenError が出た行は、文字列リテラルを mutate している箇所。
3. 該当を `str = +""`（mutable 化）・`dup`・非破壊メソッドへの置換等で修正。再実行。green まで反復。
4. 安全網は既存の green suite。検証は 4.0.2 上で行う（freeze 挙動は Ruby 版に依らず同一だが、移行先＝ 4.0.2 で確認するのが筋）。

> 補足: 0b 以降のコードは Rails omakase（`FrozenStringLiteralComment: false`）方針で磁気コメント無しできたため、文字列 mutation が紛れている可能性は低くないが量は限定的と見込む。FrozenError は実行時に確実に検出されるため、suite green が受け入れの十分条件。

## §3 Ruby 4.0 破壊的変更 × 本コードベースの該当（調査済み）

| 4.0 の変更 | 該当 | 対応 |
|---|---|---|
| `cgi` を default gem から削除 | app 直接利用 0・lock 不在 | §1-3 で `gem "cgi"` 予防追加 |
| stdlib bundled gem 化（ostruct/fiddle/benchmark/pstore 等） | 直接 require 0・logger/irb/reline/rdoc は lock 済 | 対応不要 |
| Set を C 再実装（`@hash` ivar・inspect 形式） | `user.rb:170 visited = Set[id]` のみ（標準用法・ivar/inspect 非依存） | 対応不要 |
| frozen string（chilled） | 80/81 ファイル磁気コメント無し | §1-4・§2 で一括付与（将来投資） |
| Ractor API 刷新／leading-pipe プロセス生成削除／`ObjectSpace._id2ref`／Net::HTTP Content-Type | いずれも該当 0 | 対応不要 |

C 拡張 gem（pg 1.6.3・nokogiri 1.19.3・ffi 1.17.4）は 4.0 ABI のネイティブ gem を持ち、`bundle install` で source-compile 不要に解決（§4 で実証）。

## §4 検証（受け入れ条件）= CI 等価

移行後、Ruby 4.0.2 上で以下が全て green であること（2026-06-14 に**現行コードを Ruby 4.0.2 上で実測し green を確認済み**。lock 再生成・`gem "cgi"`・frozen 付与は実装時に適用するため、各コミットで再検証する）:

- `bundle exec rspec` — **523 examples, 0 failures**（実測済）
- `bundle exec rubocop --force-exclusion` — **no offenses**（frozen string cop 有効化後も green であること）
- `bin/brakeman --no-pager` — **0 security warnings / 0 errors**（実測済）
- `bin/bundler-audit check --update` ／ `bin/importmap audit`（CI security ジョブ等価）
- `db:test:prepare` — fx トリガー・排他制約込みの schema.rb がロード可（実測済）
- 仕上げに `/preflight`

## §5 コミット分割（1 PR・各完了で即コミット）

| # | 内容 | 検証ゲート |
|---|---|---|
| C1 | `.ruby-version` + `Dockerfile ARG` を 4.0.2 → `bundle install`（lock 再生成: BUNDLED WITH 4.0.6・platform） | rspec/rubocop/brakeman green |
| C2 | `Gemfile` に `gem "cgi"`（悲観ピン）→ `bundle install` | suite green |
| C3 | `.rubocop.yml` で frozen string cop 有効化 → `rubocop -a` 付与 → §2 mutation 監査 | suite green（hard-freeze 下） |
| C4 | docs: ROADMAP（✓ + PR#）・RAILS_GOTCHAS（verified 追記）・本設計書 | — |

## §6 変更ファイル

`.ruby-version` / `Dockerfile` / `Gemfile` / `Gemfile.lock` / `.rubocop.yml` / 約 80 個の `app・lib・config/**/*.rb`（磁気コメント + 監査由来の mutation 修正） / `docs/ROADMAP.md` / `docs/RAILS_GOTCHAS.md` / `docs/superpowers/specs/2026-06-14-ruby-4-0-2-upgrade-design.md`

## §7 リスク・前提

- **frozen string FrozenError**（§2）— 最大の作業リスク。green suite が安全網。
- **CI ランナーの 4.0.2 取得** — `ruby/setup-ruby` は prebuilt ruby を取得。4.0.2 は ruby-build 定義あり・公開済み。bundler 4.x は同梱。万一 setup-ruby が 4.0.2 を解決できなければ 4.0.x の解決可能な最近接版へ（要 CI 実走確認）。
- **bundler 4.x の lock 互換** — `bundle install` を 4.0.2 上で回し lock を 4.0.6 で再生成する。ローカル検証時は `.ruby-version` 切替で rbenv が 4.0.2 を選択（導入済み）。
- **rbenv ビルド前提** — 4.0.2 は導入済みだが、他環境で入れ直す場合は CLAUDE.md の OpenSSL 回避策（`RUBY_CONFIGURE_OPTS=--with-openssl-dir=$(brew --prefix openssl@3)` + LDFLAGS/CPPFLAGS/PKG_CONFIG_PATH クリア）必須。
- **無関係 untracked `home-admin.png`** — 本スライス対象外。触れない。
- **`.rubocop.yml` の TargetRubyVersion** — 現状未指定で `.ruby-version` から推論。bump 後は 4.0 を推論。明示固定は任意（C3 で判断）。
