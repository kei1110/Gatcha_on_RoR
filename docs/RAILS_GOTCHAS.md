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

## テスト基盤

### `sign_in` / `login_as` は本物のセッション復元経路を踏まない

- **WHAT**: Devise/Warden のテストヘルパは user を直接 set するため、`serialize_from_session`（cookie からの復元）のバグはヘルパ経由 1 リクエスト目では**絶対に再現しない**
- **HOW**: セッション復元まわりを検証するときは「1 リクエスト目で cookie を確立 → 2 リクエスト目で実 deserialize を踏む」構成にする（spec/requests/authentication_spec.rb の回帰 spec が見本）
- verified: warden 1.2.9 / 2026-06-11（本番 500 が 0a のテストをすり抜けた原因）

### メール本文は `body.decoded` で読む

- **WHAT**: `body.encoded` + quoted-printable のソフト改行除去（`gsub("=\r\n", "")`）はエンコーディング依存の dead code になりがち（実際の CTE が base64 だと一切発火しない）
- **HOW**: `ActionMailer::Base.deliveries.last.body.decoded` 一本。エンコーディング非依存
- verified: mail gem / 2026-06-11

### `ActionMailer::Base.deliveries` は example 間で自動クリアされない

- **WHAT**: `deliveries.last` 直読みは、並列実行や同ファイルへの example 追加で他のメールを掴む
- **HOW**: spec/support で `before(:each, type: :system) { ActionMailer::Base.deliveries.clear }` + 件数は change matcher で assert（gen-spec 規約）
- verified: 2026-06-11

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
- verified: Rails 8.1.3 / PostgreSQL 17.10 / 2026-06-12（0b-4 Task 2 で発覚・レビューで診断訂正）

---

## メタ原則

- **レビューは書いた場所の近くに置く**: 設計レビューは設計の虫しか取れない。計画にコードを書くなら計画コードにレビューを、環境の虫（brakeman・CI）は各タスクの完了条件に
- **サブエージェントはフックをすり抜ける**: PostToolUse の自動整形・検証はサブエージェント内では保証されない。ディスパッチ指示に検証コマンド（rspec / rubocop / 必要なら brakeman）を完了条件として明記する（SF 版 lint-test-strategy の教訓と同一）
- 新しい罠を踏んだら / 仕留めたら、**修正 PR と同じブランチで本書に 1 項目追記**する
