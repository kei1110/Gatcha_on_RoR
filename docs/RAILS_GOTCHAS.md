# Rails 環境 Gotchas

Rails / Devise / Turbo / テスト基盤の落とし穴台帳。**実装・レビューで実際に踏んだ（または仕留めた）ものだけ**を WHAT / WHY / HOW で記録する（一般論は書かない）。マルチテナント設計の原則は docs/SPEC.md §3.6、spec の書き方は `.claude/skills/gen-spec/`、開発体制の教訓は CLAUDE.md を参照。

運用: 計画（writing-plans）のセルフレビューとレビュアー subagent のプロンプトに本書を注入し、同じ虫を二度と買わないこと。各項目に **verified（検証日と版）** を付け、gem メジャーアップ時に再検証する。

> 形式の出自: SF 版 `../Gatcha/docs/SF_GOTCHAS.md` の移植。

---

## Devise / Warden

### devise の `require_no_authentication` はテナント解決より先に走る（最重要）

- **WHAT**: ログイン済みユーザーが devise 公開画面（sessions#new・passwords#new/edit 等）を踏むと `ActsAsTenant::Errors::NoTenantSet` で 500
- **WHY**: `prepend_before_action :require_no_authentication` は継承チェーンの先頭に入り、`ApplicationController` のテナント解決 before_action より先に `warden.authenticated?` → `serialize_from_session`（テナントスコープ付きクエリ）を実行する。remember cookie 経由の `serialize_from_cookie`（no-input 戦略）も同経路
- **HOW**: `User.serialize_from_session` / `serialize_from_cookie` を `ActsAsTenant.without_tenant` で包み、クロステナント突合は `warden_tenant_guard`（`after_set_user`・fail-closed）の単一点に集約する。フックに `event:` フィルタを付けたり `run_callbacks: false` を使うとこの前提が壊れる（相互参照コメント済み）
- verified: devise 5.0.4 / warden 1.2.9 / 2026-06-11（0b-1 最終レビューで発見・`8710371` 等で修正）

### `set_reset_password_token` は protected かつ `save(validate: false)` を伴う

- **WHAT**: 招待などで reset token を転用するときの内部 API 依存
- **WHY**: 公開 API 契約外（メジャーアップで黙って壊れ得る）。さらに dirty なレコードに呼ぶと未検証の変更ごと永続化される
- **HOW**: モデルに公開ラッパー（`User#send_invitation_instructions`）を 1 つ定義して依存を 1 箇所に閉じ込める。保存済み・クリーンなレコードに対してのみ呼ぶ。戻り値の raw token を flash・ログ・レスポンスへ出さない。Gemfile は `"~> 5.0"` に悲観固定
- verified: devise 5.0.4 / 2026-06-11

### devise FailureApp の未認証 redirect は常に 302（`redirect_status = :see_other` が効かない）

- **WHAT**: `config.responder.redirect_status = :see_other` を設定していても、未認証アクセスのサインインへの redirect は 302 のまま
- **WHY**: FailureApp の `redirect` は素の `redirect_to`（lib/devise/failure_app.rb）で responder 設定を参照しない（recall 経路のみ参照）。POST 起点なら fetch 仕様で GET に変わるため実害なし — 危険なのは **PATCH/PUT/DELETE の認証切れ経路**（302 でメソッド保持再発行）
- **HOW**: 認証必須の PATCH/DELETE 画面を作るスライスでは、認証切れからの導線を request spec で踏んで挙動確認する（必要なら custom FailureApp で 303 化）
- verified: devise 5.0.4 / 2026-06-12（1-1 Task 5 品質レビューで実測）

### `flash[:timedout] = true` が flash ループに紛れ込む

- **WHAT**: timeoutable 有効時、セッションタイムアウトで flash に boolean が入り、素朴な `flash.each` レイアウトが緑枠の「true」を描画する
- **HOW**: レイアウトの flash ループは `next unless %w[notice alert].include?(type)` で絞る
- verified: devise 5.0.4 / 2026-06-11

### `sign_in_count == 0`＝未受諾、の判定は `sign_in_after_reset_password` 既定 true に依存

- **WHAT**: 招待未受諾の判定に trackable の `sign_in_count` を使う設計
- **WHY**: 受諾（パスワード設定）直後の自動サインインが初回カウントを刻むことが前提。設定を false に変えると「設定済みだが未ログイン」に再送ボタンが出続ける
- **HOW**: 依存をコードコメントで明示（`Admin::UserPolicy#resend_invitation?`）。設定変更時はここを見直す
- verified: devise 5.0.4 / 2026-06-11

## Rails / Turbo

### Turbo は 302 で PATCH/PUT/DELETE メソッドを保持して redirect 先を再リクエストする

- **WHAT**: `button_to method: :patch` の成功後 redirect が 302 だと、redirect 先へ PATCH が再発行され ParameterMissing 400 や RoutingError になる（request spec では検出不能 — fetch 追従をしないため）
- **WHY**: fetch 仕様で GET に変わるのは 303（または 301/302+POST）のみ
- **HOW**: 書き込み系アクションの redirect は一律 `status: :see_other`。devise 側は `config.responder.redirect_status = :see_other` で設定済み
- verified: turbo-rails / Rails 8.1.3 / 2026-06-11

### enum は不正値の代入で `ArgumentError` → 500

- **WHAT**: `User.new(role: "superadmin")` のような毒入力が、バリデーションでなく代入時例外になる
- **HOW**: `enum :role, {...}, validate: true`（Rails 7.1+）で通常のバリデーションエラー（422）に変える。permit している enum カラムには必須
- verified: Rails 8.1.3 / 2026-06-11

### enum 値名が AR/モデルのメソッドと衝突するとクラスロード時 `ArgumentError`（`none` 等）

- **WHAT**: `enum :half_day_type, { none: 0, ... }` は値ごとのスコープ/述語生成時に `none` を作ろうとし、`ActiveRecord::Base.none`（空リレーション）と衝突してクラスロード時に `ArgumentError`（"this will generate a class method 'none', which is already defined by Active Record"）で落ちる
- **WHY**: Rails enum は値名でスコープ・述語メソッドを生成する。値名が既存メソッド（`none` / `new` / `valid` 等）と被ると衝突する
- **HOW**: `prefix: <名前>`（例 `prefix: :half_day`）で生成メソッドを `half_day_none?` 等へ逃がす。**enum の値シンボル（`:none` 等）は不変**ゆえ DB 値・factory・代入は変わらず、述語/スコープ名だけ変わる（モデル内の `none?` 参照は `half_day_none?` へ）。`validate: true` と併用可
- verified: Rails 8.1.3 / 2026-06-16（Phase 2-2a `LeaveRequest.half_day_type` で実踏）

### ShowExceptions ミドルウェア経由の例外応答は session が commit されない

- **WHAT**: 例外を middleware の 404/500 描画に任せると、そのリクエストでの `reset_session` や Warden ログインが**クライアントに届かない**（連続リクエストのテストで 2 回目が 302 になる等）
- **WHY**: rack-session は `app.call` の正常復帰後にのみ `commit_session` する。ShowExceptions は session ミドルウェアの外側
- **HOW**: アプリが意味を持たせたい例外（`RecordNotFound` → 404 等）は `rescue_from` で controller 層で描画する。テナント解決 404 の `reset_session` が実際に効いているのはこの構造のおかげ
- verified: rack-session 2.1.2 / Rails 8.1.3 / 2026-06-11

## acts_as_tenant

### バリデーション内のスコープ依存クエリは `without_tenant` 文脈で fail-open し得る

- **WHAT**: 「自分以外のアクティブ hr_admin がいるか」のような**救済要員カウント**を default scope 任せで書くと、console/seed（`without_tenant`）で全テナント横断 COUNT になり、他社の hr_admin を救済要員と誤認して保護が外れる
- **HOW**: fail-open する判定クエリは `where(organization_id: organization_id, ...)` を明示（0a の「default scope に加えた明示防衛」規約）。一方、`manager` / `subordinates` のような自己参照 association の遡上は複合 FK `(organization_id, manager_id)` が DB レベルで越境を排除するため明示不要（この書き分けは user.rb のコメント参照）
- verified: acts_as_tenant / 2026-06-11（0b-1 セキュリティレビュー W-1）

### テナント未設定文脈の `NoTenantSet` は「正しい挙動」— 直すのは利用側

- **WHAT**: request spec の setup で `user.update!(...)` と裸で書くと、バリデーションがスコープ付きクエリを持った瞬間に `NoTenantSet` で落ち始める
- **WHY**: request/system spec は意図的にテナント未設定（解決フィルタ自体を検証するため）。fail-closed は設計どおりで、ガード側を `without_tenant` で緩めるのは誤り
- **HOW**: setup のモデル操作を `ActsAsTenant.with_tenant(org) { ... }` で包む（本番のコントローラ文脈の写像）
- verified: 2026-06-11（0b-1 G2 で顕在化）

## Pundit / 認可

### `policy_scope(Model)` の Scope 解決規則（top-level Policy 不在で `NotDefinedError`）

- **WHAT**: 代理打刻のロスターを `policy_scope(User)` で引こうとすると `Pundit::NotDefinedError`（"unable to find policy scope `UserPolicy::Scope`"）で 500。`User` モデルには top-level `UserPolicy` が無く（認可は `Admin::UserPolicy` 名前空間と headless な `ProxyClockingPolicy` に分かれている）、`policy_scope` は既定で `"#{Model}Policy::Scope"` を引くため
- **WHY**: `policy_scope(record)` のスコープ解決は record のクラス名から `XxxPolicy::Scope` を機械的に導出する。別 Policy 配下の Scope（`ProxyClockingPolicy::Scope`）を使いたい場合や、そもそも top-level Policy を置かない設計では、導出名が存在せず fail-closed（例外）になる。これは「誤って素の `policy_scope` を呼んだら通ってしまう」より安全だが、意図した Scope を明示しないと動かない
- **HOW**: 別 Scope を使うときは `policy_scope(User, policy_scope_class: ProxyClockingPolicy::Scope)` と明示する（`app/controllers/proxy_clockings_controller.rb#roster`）。`after_action :verify_policy_scoped`（index 強制）も `policy_scope` 呼び出しで満たされる。top-level Policy を置かない設計は「`policy_scope` の誤用＝即例外」という補償統制として意図的に維持する（`Admin::OrganizationSettingPolicy` が Scope を定義しない理由と同型）
- verified: pundit / Rails 8.1.3 / 2026-06-13（1-3 Task 5 で実装・§3.4 / §5 設計）

## テスト基盤

### `sign_in` / `login_as` は本物のセッション復元経路を踏まない

- **WHAT**: Devise/Warden のテストヘルパは user を直接 set するため、`serialize_from_session`（cookie からの復元）のバグはヘルパ経由 1 リクエスト目では**絶対に再現しない**
- **HOW**: セッション復元まわりを検証するときは「1 リクエスト目で cookie を確立 → 2 リクエスト目で実 deserialize を踏む」構成にする（spec/requests/authentication_spec.rb の回帰 spec が見本）
- verified: warden 1.2.9 / 2026-06-11（本番 500 が 0a のテストをすり抜けた原因）

### `travel_to` ブロック外の `follow_redirect!` は Devise timeoutable でセッション切れになる

- **WHAT**: request spec で `travel_to(過去/未来時刻) { post ... }` の後、ブロックの**外**で `follow_redirect!` すると、認証済みのはずが 302 でサインインへ飛ばされ flash 検証が偽 FAIL する
- **WHY**: ブロック内の POST が Warden セッションの `last_request_at` を travel 先時刻で記録し、ブロック外の後続リクエストは実時刻で評価される。差分が `config.timeout_in`（30 分）を超えると timeoutable がセッションを破棄する
- **HOW**: `follow_redirect!` とボディ検証まで `travel_to` ブロック内に収める（1-1 Task 5 で実踏・計画コードの配置ミスを実装者が検出）
- verified: devise 5.0.4 / 2026-06-12

### メール本文は `body.decoded` で読む

- **WHAT**: `body.encoded` + quoted-printable のソフト改行除去（`gsub("=\r\n", "")`）はエンコーディング依存の dead code になりがち（実際の CTE が base64 だと一切発火しない）
- **HOW**: `ActionMailer::Base.deliveries.last.body.decoded` 一本。エンコーディング非依存
- verified: mail gem / 2026-06-11

### `ActionMailer::Base.deliveries` は example 間で自動クリアされない

- **WHAT**: `deliveries.last` 直読みは、並列実行や同ファイルへの example 追加で他のメールを掴む
- **HOW**: spec/support で `before(:each, type: :system) { ActionMailer::Base.deliveries.clear }` + 件数は change matcher で assert（gen-spec 規約）
- verified: 2026-06-11

### DB トリガーの `RAISE EXCEPTION` を踏む example は `transaction(requires_new: true)` で隔離する

- **WHAT**: 追記専用テーブル（`AttendanceHistory`・§4.14）の「UPDATE/DELETE/TRUNCATE を拒否」拒否 spec で、`expect { update_all }.to raise_error(StatementInvalid)` は通るのに**後続の example が偽 FAIL**する
- **WHY**: transactional fixtures 下では各 example が 1 つの tx で包まれる。DB トリガーの `RAISE EXCEPTION` は PG の tx 全体を aborted 状態にするため、rescue（`expect ... raise_error`）で例外を捕まえても example の親 tx は壊れたまま。以降のクエリが `PG::InFailedSqlTransaction` 系で落ちる（Ruby 例外と違い SQL エラーは tx を道連れにする — DB セクションの with_lock 罠と同根）
- **HOW**: 拒否を起こす 1 文だけを `ActiveRecord::Base.transaction(requires_new: true) { ... }`（savepoint）で包む。savepoint だけが rollback され親 tx は生存する。`spec/models/attendance_history_spec.rb` の `in_savepoint` ヘルパが見本（層③の `update_all` / `delete_all` / raw DELETE / TRUNCATE 全例で使用）。層①②（`readonly?` / `before_destroy` の Ruby 例外）は SQL 未発行ゆえ隔離不要
- verified: Rails 8.1.3 / PG 17 / 2026-06-13（1-3 Task 2 で実装・追記専用 4 経路の拒否 spec）

---

## 生成物・設定

### 生成された initializer の placeholder はレビュー網をすり抜ける

- **WHAT**: devise の `config.mailer_sender` が `please-change-me-at-...` のまま、丁寧に作り込んだ招待メールを送っていた
- **WHY**: 設計・計画・多段レビューはすべて「変更 diff」を見る。生成済み設定の既定値は diff に現れず、誰の視界にも入らない
- **HOW**: ENV 化（`ENV.fetch("MAILER_SENDER", ...)`）+ mailer spec で placeholder 不在を assert。新 gem 導入 PR では `grep -rn "change-me\|TODO\|example\.com" config/initializers/` を儀式に含める
- verified: devise 5.0.4 / 2026-06-11（0b-1 マージ後のレトロスペクティブで発見）

## CSV / エクスポート

### CSV エクスポート時のスプレッドシートインジェクション（formula injection）

- **WHAT**: ユーザー入力由来の文字列（CompanyCalendar.name 等）が `=` `@` `+` `-` またはタブ文字で始まると、Excel 等で開いた際に数式として実行され得る
- **WHY**: 0b-3 の CSV インポートで name にユーザー任意文字列が入る。Phase 3-3 の CSV エクスポート 2 種が実装されるとき、この値がそのまま出力されると発火する（インポート側は無害 — 出力側の罠）
- **HOW**: エクスポート実装時にユーザー入力由来のセルは先頭が `=` `@` `+` `-` またはタブの場合に `'` 前置等でエスケープする
- verified: 2026-06-12（0b-3 Task 6 品質レビューで予防的に記録・エクスポート未実装のため発火例なし）

## DB / マイグレーション

### Rails 8 の exclusion constraint WHERE 句 schema dump バグ（裸カラム述語のみ発火）

- **WHAT**: `add_exclusion_constraint` で `where: "active"` 等の**裸のカラム参照**を使うと、`db:schema:dump` が `where: "ctiv"` という壊れた値を出力する。`db:schema:load` で `PG::UndefinedColumn: column "ctiv" does not exist` エラーになりラウンドトリップが失敗する。
- **WHY**: `schema_statements.rb` の `predicate.from(2).to(-3)` が WHERE 節を常に二重括弧 `((expr))` と仮定して 2 文字ずつ剥がしている。だが pg_get_constraintdef の括弧数は PG バージョンではなく**述語の形状**に依存する（PG 17.10 で直接プローブして確認）: 裸カラム `active` → `WHERE (active)`（単一括弧・壊れる）／演算子式 `b > 1` → `WHERE ((b > 1))`（二重括弧・既存コードでも動く）。正しくは `from(1).to(-2)` で外側 1 対だけ剥がす — 演算子式は `(b > 1)` になるが Rails が再度 `(...)` で包むため両形状でラウンドトリップ安定。
- **HOW**: `config/initializers/rails_exclusion_constraint_where_fix.rb` で `ExclusionConstraintWhereFix` モジュールを `prepend` して修正済み。upstream Rails main は 2026-06-12 時点でも未修正のため、ガードは `ActiveRecord::VERSION::MAJOR == 8`（8 系なら適用）。upstream 修正後に適用されても同等ロジックの上書きで無害。Rails メジャーアップ時に upstream の `exclusion_constraints`（schema_statements.rb の `predicate.from(2).to(-3)` 付近）を再確認し、修正されていたら本ファイルを削除する。initializer は `require "active_record/connection_adapters/postgresql_adapter"` で先読みしてから prepend すること（定数未ロードエラー防止）。
- verified: Rails 8.1.3 / PostgreSQL 17.10 / 2026-06-12（0b-4 Task 2 で発覚・レビューで診断訂正）。**PG 18.4 でも同挙動を直接プローブで再確認（2026-06-16・裸カラム `WHERE (a)` 単一括弧／演算子式 `WHERE ((b > 1))` 二重括弧）— 回避策据え置き**

### fx の SchemaDumper フックと exclusion-constraint パッチは共存できる（別メソッド prepend で順序非依存）

- **WHAT**: `fx`（DB トリガーを `create_trigger` として schema.rb に出力する gem）を導入しても、自前の `ExclusionConstraintWhereFix`（上記バグ修正）と衝突しない。schema.rb には exclusion_constraint と `create_trigger` の両方が出力され、`db:schema:load` でラウンドトリップする
- **WHY**: 両者は**別メソッドへの prepend** で干渉しない。fx は `ActiveRecord::SchemaDumper` 系に prepend して `create_trigger` 行を吐く出力フック、自前パッチは `PostgreSQL::SchemaStatements#exclusion_constraints` に prepend する読み取り修正。patch するメソッドが異なるため initializer のロード順に依存しない（どちらが先でも結果が同じ）
- **HOW**: 追記専用トリガー（`db/triggers/attendance_histories_no_mutate_v01.sql` 等）は fx の `create_trigger` で管理し、UserWorkPattern の exclusion constraint と同じ schema.rb に同居させる。新規にトリガー or exclusion を足したら `RAILS_ENV=test bin/rails db:schema:load`（or `db:test:prepare`）でラウンドトリップを 1 度通して両出力が壊れていないか確認する
- verified: fx 0.11.0 / Rails 8.1.3 / PG 17 / 2026-06-13（1-3 Task 1-2 で実装・schema.rb に exclusion_constraint と create_trigger 2 件が共存・load 実証済）

### fx のトリガー dump 順序が非決定的（同一テーブルに複数トリガーで churn）

- **WHAT**: 同一テーブルに複数トリガーがあると、`db:schema:dump` が出力する `create_trigger` 行の順序が PG バージョン・クエリ実行ごとに揺れ、schema.rb に無意味な diff（churn）が出る。
- **WHY**: fx 0.11.0 の `Triggers::TRIGGERS_WITH_DEFINITIONS_QUERY` は `ORDER BY pc.oid`（トリガーが属する**テーブル**の OID）のみ。同一テーブルのトリガー群は pc.oid が同値でタイブレークが無く、行順が PostgreSQL の物理ヒープ順（未規定）に委ねられる。PG17→18 で実踏 — **同一の手動クエリでも `[no_mutate, no_truncate]` と `[no_truncate, no_mutate]` の両順を観測**し非決定性を確証。
- **HOW**: `config/initializers/fx_trigger_dump_order_fix.rb` で `Triggers.all` を prepend し `super.sort` で name 昇順に決定化（`Fx::Trigger` は `include Comparable` で `<=>` を name に委譲）。SQL を複製しないため fx 本体のクエリ変更が透過的に流れ、fx が将来 ORDER BY を自前修正しても整列済み配列の再整列（no-op）で無害（自己無害化）。既存 `rails_exclusion_constraint_where_fix.rb` と同じ prepend 流儀。CI に `bin/rails db:schema:dump && git diff --exit-code db/schema.rb`（`db:test:prepare` 直後・rspec の `before(:suite)` がテスト専用表を作る前）を置き、本パッチ／exclusion パッチの回帰と migration 後の schema.rb commit 漏れを dump 方向で検知する。
- verified: fx 0.11.0 / PostgreSQL 18.4 / 2026-06-16（PG17→18 アップグレードで発覚・patch 後に `db:schema:dump` の schema.rb 差分ゼロを実証）

### precompiled な pg gem は libpq を自前同梱し Homebrew libpq に非依存（PG メジャー版アップで再ビルド不要）

- **WHAT**: Homebrew PostgreSQL をメジャーアップ（17→18）しても、`pg` gem の再ビルドは不要。サーバを入れ替えるだけでよい。
- **WHY**: 本機が使う precompiled `pg-1.6.3-arm64-darwin` を `otool -L` で検査すると、外部リンクは gem 同梱の `@loader_path/../../ports/arm64-darwin/lib/libpq-ruby-pg.1.dylib`（current version 5.18.0 = PG18 世代）と `/usr/lib/libSystem` のみで、`/opt/homebrew/opt/postgresql@NN/lib/libpq.dylib` を一切参照しない。サーバ版差はワイヤプロトコル互換で吸収される。当初「導入時の libpq に動的リンク・再ビルド必須」と想定したが実測で否定された。
- **HOW**: 確認は `otool -L "$(find "$(bundle show pg)" -name '*.bundle' | head -1)"`。`bundle config force_ruby_platform true` で source 版へ切替えた場合のみ Homebrew libpq 依存に戻るため、その時だけ `@NN/bin/pg_config` を指して再ビルドが要る。
- verified: pg 1.6.3 (arm64-darwin) / PostgreSQL 18.4 / 2026-06-16（PG17→18 で otool により Homebrew libpq 非依存を確認・サーバ 18 で rspec 589 緑）

## ActiveRecord association

### `dependent: :restrict_with_error` の association に `delete_all` を呼ぶと nullify になる

- **WHAT**: `user.attendance_records.delete_all` が DELETE ではなく `user_id = NULL` の UPDATE を発行し、NOT NULL 制約で `NotNullViolation` 500 になる（1-1 品質レビューの実験スクリプトが実踏）
- **WHY**: `CollectionProxy#delete_all` は引数なしだと association の `dependent` 戦略から削除方法を導出する。`:restrict_with_error` は delete_all の戦略表に無く、has_many 既定の `:nullify` 相当へフォールバックする（AR の仕様でありバグではない）
- **HOW**: 一括削除はクラス起点 `AttendanceRecord.where(user_id: ...).delete_all` で書く（4-2 バッチ等）。association 経由の一括削除を書かない。レビュー時は `.〜s.delete_all`（restrict 系 association への呼び出し）を疑う
- verified: Rails 8.1.3 / 2026-06-12（1-1 Task 2-4 品質レビューで実踏・本番コードに該当呼び出しなし）

---

### with_lock 内の副作用 — rescue するか伝播させるかは「巻き戻したいか」で決まる（2-2b・verified 2026-06-18）

- **WHAT:** `with_lock` 内の tx で失敗し得る副作用を `rescue` して握り潰すと、ロールバック済みの更新が消えたまま「成功」を返す（偽 success + 更新消失）。
- **WHY:** 2 つの正反対の正解が文脈で決まる。
  - **1-2 ClockOut→Recalculate:** 「打刻だけは保全したい」→ 失敗し得る後続（再計算）を **commit 後/savepoint に隔離**し、打刻本体を守る。
  - **2-2b Approve→ApplyApproval:** 「残高違反なら承認ごと無効が正」→ `OverBalanceError` を **rescue せず raise 伝播**させ、assignment 承認・残高加算・AR 生成・履歴を atomic に巻き戻す。controller 層で rescue して flash 再描画。
- **HOW:** 「この副作用が失敗したら主操作も無かったことにすべきか？」を先に問う。Yes → 同一 tx で raise 伝播。No → savepoint/commit 後へ隔離。機械的コピー厳禁。
- verified: Rails 8.1.3 / PG 17-18 / 2026-06-13・2026-06-18（1-2 品質レビュー②で初踏・2-2b で文脈別正解を確立）

---

## テスト / 検証プロセス

### bin/brakeman は `--ensure-latest` 注入 — 新版リリースで突然 exit 5

- **WHAT**: コード無変更でも brakeman の新版が出た瞬間から `bin/brakeman` が「not the latest version」で非ゼロ終了し、local も CI（security ジョブ）も落ちる
- **WHY**: rails new が生成する binstub は `ARGV.unshift("--ensure-latest")` を仕込んでおり、Gemfile.lock の版 ≠ 最新版だと警告 0 件でも exit 5 を返す
- **HOW**: `bundle update brakeman` で追従（Gemfile.lock 更新を伴うので bundle-audit も同時に回す）。`bundle exec brakeman` 直叩きは --ensure-latest が付かず素通りする — exit code の食い違いを見たらまず binstub を読む
- verified: brakeman 8.0.4→8.0.5 / 2026-06-13（1-2 preflight で実踏）

### bootsnap の ISeq cache が「同一バイト数の編集 + 同一秒内の revert」で stale 化

- **WHAT**: ファイルを同一バイト数で書き換えて（例: `.floor`→`.round` の mutation 実験）直後に revert すると、disk は `.floor` なのに実行時は `.round` の挙動を示すことがある
- **WHY**: bootsnap の ISeq cache key は mtime（秒精度）+ サイズ。同一秒内・同一サイズの変更は cache hit して旧バイトコードを返す
- **HOW**: mutation 実験や高速な編集 ↔ revert の検証では、前後に `touch <file>` するか `tmp/cache/bootsnap` を削除して cache bust する。Mutant 導入（ROADMAP 1-2 完了後）時は特に注意
- verified: Rails 8.1.3 / 2026-06-13（1-2 品質レビュー①で実踏 — 36,001 点中 18,000 点が幻の round 挙動・bust 後 0）

---

## メタ原則

- **レビューは書いた場所の近くに置く**: 設計レビューは設計の虫しか取れない。計画にコードを書くなら計画コードにレビューを、環境の虫（brakeman・CI）は各タスクの完了条件に
- **サブエージェントはフックをすり抜ける**: PostToolUse の自動整形・検証はサブエージェント内では保証されない。ディスパッチ指示に検証コマンド（rspec / rubocop / 必要なら brakeman）を完了条件として明記する（SF 版 lint-test-strategy の教訓と同一）
- 新しい罠を踏んだら / 仕留めたら、**修正 PR と同じブランチで本書に 1 項目追記**する

---

## Ruby / ツールチェーン

### Ruby 4.0 アップグレード: vips は環境要因・cgi は予防追加・bundler は明示 bump・frozen は hard-freeze 化

- **WHAT**: 3.3.11 → 4.0.2 移行で踏み得る 4 点
- **WHY/HOW**:
  - **bundler**: `bundle install` では `BUNDLED WITH` は上がらない（lock の 2.5.22 を尊重）。`bundle update --bundler` の明示実行で 4.0.x へ（本リポジトリは実測で 4.0.14＝Ruby 4.0.2 同梱版に着地）。放置すると Ruby 4.0 の rubygems と `Gem::Platform::* already initialized` 警告
  - **cgi**: Ruby 4.0 で default gem から削除（`cgi/escape` のみ残存）。`require "cgi"` を踏む依存は `gem "cgi"` 必須（rails/rails#56457 の真因）。本 app は未使用だが予防追加
  - **frozen_string_literal**: 4.0 の chilled は警告のみだが、磁気コメント付与は真に freeze＝mutation が即 FrozenError。一括付与時は green suite で mutation 監査が必須。本リポジトリでは全 `.rb`（178）＋ Gemfile/Rakefile/config.ru ＝計 181 ファイルへ一括付与（`db/*schema.rb` は rubocop の既存 Exclude で除外）
  - **ruby-vips**: ローカルのみ libvips 未導入で `require "vips"` が LoadError。3.3.11 でも同一＝環境要因（Ruby 4.0 回帰ではない）。`require: false` + 遅延ロードで suite 無影響。本番 Docker は libvips 同梱。ローカルで variant を扱うなら `brew install vips`
  - **rubocop TargetRubyVersion**: `.ruby-version`=4.0.2 から target 4.0 を推論し rubocop が未知版エラーにし得る。`AllCops: { TargetRubyVersion: 3.4 }` で固定可
- verified: Ruby 4.0.2 / Rails 8.1.3 / 2026-06-14（直行アップグレードで実測・rspec 523/0・rubocop・brakeman green）

### YJIT は Rails 8.1 既定で production のみ有効（明示設定は不要・むしろ drift 源）

- **WHAT**: 「YJIT を有効化する」変更は本リポジトリに実装対象が存在しない（既に有効）
- **WHY/HOW**: `config.load_defaults 8.1` の framework 既定が `config.yjit` を **env 依存で production のみ true**（dev/test は false）に設定し、Rails の boot initializer が production 起動時に `RubyVM::YJIT.enable` を呼ぶ。実測: production で `config.yjit==true` かつ `RubyVM::YJIT.enabled?==true`、dev/test は両方 false。Ruby 4.0.2 ビルドは `+YJIT` 同梱（`ruby -v --yjit` で確認）。production.rb への明示 `config.yjit = true` は omakase の「既定に委ねる」流儀に反し、将来 Rails が既定を変えた時の drift 源になるため**追加しない**
- verified: Ruby 4.0.2 / Rails 8.1.3 / 2026-06-14（production/dev/test を rails runner で実測・`config.yjit` と `RubyVM::YJIT.enabled?` を確認）

### Ruby アップグレード後、Bundler 管理外の MCP gem（rails-mcp-server）が新 Ruby に不在で `-32000`

- **WHAT**: `.ruby-version` を 3.3.11 → 4.0.2 に上げた後、`/mcp` で rails サーバーだけ `Failed to reconnect to rails: -32000`。jp-labor-evidence・postgres（npx）と sentry（http）は無事
- **WHY**: `.mcp.json` の rails は `rails-mcp-server`（引数・env なし）を起動し、その実体は rbenv shim。shim は cwd の `.ruby-version` で Ruby を解決するため、版を上げた瞬間 gem の入った 3.3.11 でなく 4.0.2 を見にいく。gem は旧 Ruby にしか無いので shim が `command not found` で即 exit → MCP の stdio ハンドシェイク不成立 → JSON-RPC の implementation-defined server error `-32000`（「相手プロセスが即死」の意）。`which rails-mcp-server` は shim パスを返すので一見存在するように見え、`rbenv which`（実体解決）まで踏まないと露見しない。Gemfile/bundle 管理下の gem は Ruby を上げても `bundle install` で追従するが、**`gem install` で直に入れた実行系ツールは bundle の外**ゆえ手動の再インストールが要る（rails MCP に固有の盲点）
- **HOW**: Ruby アップグレード PR では Bundler 管理外で `gem install` した実行系ツールを新 Ruby へ入れ直す。rails MCP は**プロジェクト直下**（`.ruby-version` が効く場所）で `gem install rails-mcp-server`。検証は ① `rbenv which rails-mcp-server` が新 Ruby の path を返す ② `initialize` リクエストを stdin に流して正常な JSON-RPC レスポンス（`serverInfo`）が返る、の 2 点。修正後は Claude Code の MCP 再接続（`/mcp` reconnect か再起動）が必要 — 既存セッションの失敗状態は自動回復しない
- verified: rails-mcp-server 1.5.1 / fast-mcp 1.6.0 / Ruby 4.0.2 / 2026-06-16（#27 の Ruby 移行で gem 再インストール漏れ・本セッションで診断。4.0.2 へ再 install し `rbenv which` 解決＋`initialize` 応答を実証）
