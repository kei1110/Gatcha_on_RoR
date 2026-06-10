# Phase 0a（基盤）設計仕様

- 日付: 2026-06-10
- 対象: SPEC §15 Phase 0 の前半（0a 基盤）。Phase 0 は **0a 基盤 → 0b マスタ CRUD** の二段に分割して進める
- ステータス: 多視点レビュー（原則整合・実用主義・YAGNI・セキュリティ・テスト網羅の 5 視点並列）反映済み
- 上位文書: [docs/SPEC.md](../../SPEC.md)（SSOT。§2.2・§3.1〜3.6・§4.1〜4.3・§15）

## 0. スコープと確定済み判断

| 論点 | 決定 |
|---|---|
| Phase 0 分割 | 0a 基盤（本書）→ 0b マスタ CRUD。それぞれ独立に spec→plan→実装 |
| CI | 0a に含め、最初の PR 緑化後に required status checks 登録まで完遂 |
| CSS | Tailwind CSS（`tailwindcss-rails`・Node 不要）。SPEC §2.1 への追記は 0a 実装時に行う |
| 0a 到達点 | seed 組織＋ログイン＋最小ホーム（テナント分離を E2E 検証可能な「動く骨格」） |
| マージゲート（改訂） | **required は自前 CI のみ**。CodeRabbit は全 PR 自動レビューだが required にしない（外部障害で merge が塞がるため。ブランチ戦略 spec §6 を本日付で改訂） |

**0a の範囲外:** マスタ 6 種 CRUD・OrganizationSetting・ユーザー管理 UI（→ 0b）。`User.email_enabled` カラム（→ Phase 4 通知で migration 追加。無言の欠落ではなく明示的後送り）。

## 1. rails new と Gem 構成

```bash
rails new . --name=gatcha --database=postgresql --css=tailwind \
  --skip-test --skip-jbuilder --skip-kamal --skip-thruster
```

- **`--name=gatcha` は必須**: ディレクトリ名 `Gatcha_on_RoR` からの導出を防ぎ、モジュール `Gatcha`・DB 名 `gatcha_development`/`gatcha_test`（作成済み）と一致させる
- `--skip-test`: minitest を生成せず RSpec を採用。`--skip-kamal --skip-thruster`: デプロイ先未定のため後日（両方 skip しないと thruster が残る）
- Rails 8 既定の Solid Queue/Cache/Cable・Hotwire・Propshaft はそのまま。ただし **development の Active Job は `:async` が既定**で SolidQueue は production のみ——ジョブ導入フェーズ（Phase 1 以降）で dev 設定を足す TODO として認識しておく
- 既存ファイル（`.gitignore`・`README.md`・`CLAUDE.md`）との衝突は手動マージ
- 0a の gem: `acts_as_tenant` / `devise` / `pundit` / `view_component`（スタック確定ゆえ導入するが 0a では未使用——空の `app/components/` を作り込まない）。テスト: `rspec-rails` / `factory_bot_rails` / `capybara` / `pundit-matchers`。AASM 等は出番のフェーズで導入

## 2. CI と必須チェック登録

- `--skip-test` 生成の `ci.yml` には test job が無い——**RSpec job は手書き**（Postgres 17 service・`db:test:prepare`・system spec 用ヘッドレス Chrome）。RuboCop（omakase）・Brakeman は生成物を活用
- 0a の最初の PR で CI が一度緑になったのち、main 保護 Ruleset（id 17476200）に **自前 CI のチェックのみ** required 登録（`gh` アカウント切り替え手順はブランチ戦略 plan の Deferred Task 参照）
- CodeRabbit は自動レビューを継続するが required にしない

## 3. テナント基盤（SPEC §3.1）

- `Organization`: `name` / `subdomain`（グローバル一意・format バリデーション）/ `time_zone`（既定 `Asia/Tokyo`）/ `fiscal_year_end_month` / `active`。テナントルートゆえ `acts_as_tenant` なし
- `ActsAsTenant.configure { |c| c.require_tenant = true }` — ラップ漏れを構造的に例外化
- `ApplicationController` で `set_current_tenant_through_filter` を宣言し、fail-closed の解決順序を実装:
  1. **サブドメイン解決**: 未知・`active=false` は 404 で打ち切り。`current_tenant` nil のまま続行する経路を作らない
  2. **認証**（Devise）
  3. **整合突合**: §5 の Warden hook で一点実装（コントローラ before_action には置かない）
- **サブドメイン抽出の信頼境界**: `request.host`（信頼プロキシ確定後の値）のみを入力源とし、許可ドメイン suffix の厳格一致で剥がす。`X-Forwarded-Host` を直接信頼しない。本番 `config.hosts` は本番ドメインに限定
- 開発環境: `acme.localhost:3000`（現代 OS/ブラウザはループバック解決・ネットワーク不要）。Rails 6+ は `.localhost` サブドメインを既定許可するため `config.hosts` 追記は不要
- **inactive 化の即時性**: 組織を `active=false` にした後の既存セッションも次リクエストで 404＋セッション破棄（新規アクセスだけでなく既存セッションも遮断）

## 4. 認証 — Devise テナントスコープ化（SPEC §3.2）

- modules: `database_authenticatable, recoverable, rememberable, lockable, trackable, timeoutable`。**`validatable` は載せない**——一意性検証だけの差し替えが不可能（devise#4767）なため、同等のバリデーションを自前で書く:
  - email: presence / format（`Devise.email_regexp`）/ **`validates_uniqueness_to_tenant`**
  - password: presence（新規・変更時）/ length（`Devise.password_length`）/ confirmation
- **`registerable` は載せない**（公開サインアップなし。ユーザー作成は seeds → 0b の管理 UI）
- **インデックス**: email のグローバル unique を張らず `(organization_id, email)` 複合 unique。`reset_password_token` / `unlock_token` は**グローバル unique を維持**（SPEC §3.2(3)。トークンはテナント無関係に一意でなければ衝突時に発行先不定となる）
- **認証クエリのスコープ**: `find_for_database_authentication` **と** `find_first_by_auth_conditions`（recoverable/lockable の発行系が通る）の両方を `ActsAsTenant.current_tenant` でスコープ。acts_as_tenant の自動スコープと重なるが「default_scope が外れた経路への防衛」としてコメント付きで明示実装
- **トークン消費の再検証**: `with_reset_password_token` / `with_unlock_token` で解決したユーザーは、消費直後にコントローラで `user.organization_id == ActsAsTenant.current_tenant.id` を再検証し、**不一致は 404**（トークンが属するテナントが正・URL のサブドメインを信頼しない）。`sign_in_after_reset_password` 既定 true による「別テナント上のセッション成立」を遮断
- **メール URL**: `deliver_later` はリクエストコンテキストを持たないため、コントローラの `default_url_options` では機能しない。**カスタム Devise mailer** で `record.organization.subdomain` から host を組み立てる
- **列挙耐性**: `config.paranoid = true`。ログイン・リセット・unlock の応答をユーザー存在に依存させない（サブドメイン総当り×応答差で「どのテナントに誰が居るか」が割れる攻撃への防御）
- `rememberable` × `timeoutable` の既定挙動（remembered ユーザーは timeout 免除）は**容認**し、その旨をコード上にコメントで明記

## 5. Warden 一点防御（整合突合・セッション衛生）

整合突合（§3.1③）を ApplicationController の before_action に置くと、**Devise のトークン経路・remember cookie 復元が素通りする**。よって認証確立の単一点である Warden hook に実装する:

- `Warden::Manager.after_set_user` で `user.organization_id != ActsAsTenant.current_tenant&.id` を検証。不一致は:
  1. `reset_session`（セッション固定対策を兼ねる）
  2. remember cookie 失効（`forget_me` 相当 + cookie 削除）
  3. `throw(:warden)` → HTML はサインイン画面へ redirect、Turbo fetch/API は 401
- **remember cookie の Domain はサブドメイン単位に限定**（親ドメインへ広げない。サブドメイン跨ぎ送出によるクロステナント復元の入口を閉じる）
- 認証成功時の `reset_session` は Devise 既定（`clean_up_csrf_token_on_authentication` 等）に乗りつつ、トークン経路でも session 再生成が走ることをテストで担保
- session cookie は本番で `Secure` / `HttpOnly` / `SameSite=Lax`

## 6. User スキーマ（SPEC §4.3 の 0a 分）

| カラム | 型 | 制約 |
|---|---|---|
| organization_id | bigint | NOT NULL・FK・複合インデックス先頭 |
| email | string | `(organization_id, email)` unique |
| encrypted_password ほか Devise 列 | — | recoverable/rememberable/lockable/trackable/timeoutable 分。トークン列はグローバル unique |
| **name** | string | **NOT NULL**（最小ホームの表示にも即必要） |
| employee_code | string | `(organization_id, employee_code)` unique |
| role | integer enum | `employee: 0, manager: 1, hr_admin: 2`・NOT NULL・default employee |
| manager_id | bigint | 自己参照・null 可・同一テナント強制（§7） |
| exempt_from_overtime | boolean | NOT NULL・default false（role とは別概念） |
| **active** | boolean | NOT NULL・default true。**`active_for_authentication?` に接続**し退職者のログインを拒否（fail-closed） |

- `email_enabled` は Phase 4（通知）で追加（§0 範囲外に明記済み）

## 7. ロール・上長・認可（SPEC §3.3–3.6）

- `manager_id` の同一テナント強制（§3.6(2) 最重要防御）:
  1. モデルバリデーション: `manager.organization_id == organization_id`（エラーは `errors[:manager_id]` に付与——テストで属性まで assert するため）
  2. 複合 FK: `(organization_id, manager_id) → users(organization_id, id)`
  3. **migration 順序**: 先に `users(organization_id, id)` の unique index → 後から複合 FK（順序を誤ると PG エラー）。`schema.rb` に複合 FK が正しく dump されることを 0a 内で確認
- Pundit:
  - `ApplicationPolicy` は既定 deny
  - `after_action :verify_authorized, unless: :devise_controller?` ——Devise コントローラ除外を忘れるとログイン画面で例外（定番穴）
  - `verify_policy_scoped` は **`only: :index`**（全アクション強制は skip 列挙の増殖を招く。Pundit README 準拠）
  - skip は明示列挙し、request spec で skip 一覧を固定（差分検知）
- **mass-assignment 防御**: `organization_id` / `role` / `exempt_from_overtime` / `manager_id` は permit リストから恒久除外。`organization_id` は acts_as_tenant が `current_tenant` から自動代入（コントローラで受け取らない）。`role` 等の変更は 0b の hr_admin 専用アクション＋専用 Policy で導入

## 8. seeds と最小ホーム

- seeds は **`Rails.env.development? || Rails.env.test?` ガード**で本番実行を拒否（既知パスワードの hr_admin が本番に残る事故の遮断）
- パスワードは `ENV.fetch("SEED_PASSWORD") { SecureRandom.alphanumeric(20).tap { |pw| puts "seed password: #{pw}" } }` 方式——固定値をリポジトリに置かない
- **組織ごとに `ActsAsTenant.with_tenant(org) { ... }` でラップ**（§3.6 が名指しする「リクエスト文脈を持たない経路」。require_tenant=true の例外化に頼らず設計意図として明文化）
- 構成: 2 組織（acme / globex）× 各 3 ユーザー（hr_admin / manager / employee、manager→employee の上長関係付き）。クロステナント検証を実地で踏める最小構成
- `HomeController#show`: ログイン必須。「誰として（name）・どの role で・どの組織に」入ったかを表示する最小画面。`verify_authorized` 対象（HomePolicy で全ロール許可——既定 deny の例外を Policy で明示する形を最初から踏む）

## 9. テスト戦略

### 9.1 基盤（rails_helper）

- **factory**: `organization { ActsAsTenant.current_tenant || association(:organization) }` を User 系 factory に持たせ、`require_tenant = true` 下でも動作させる。Organization factory は `sequence(:subdomain) { "org#{_1}" }`（グローバル unique ゆえ sequence 必須）
- **type 別テナント運用**: model/policy spec は `ActsAsTenant.test_tenant` を before で設定。**request/system spec は `test_tenant = nil`**——テナント解決フィルタ自身を検証するため（test_tenant が立っていると未知サブドメインでもクエリが通り偽テスト化する）。`config.after` で `current_tenant`/`test_tenant` を必ずクリア
- **canary**: `require_tenant` が test 環境で実際に効いていることを 1 本の恒久 regression として置く（`without_tenant` 外でのクエリが `NoTenantSet` を投げる）
- **Capybara**: `switch_tenant(org)` ヘルパで `Capybara.app_host = "http://#{org.subdomain}.localhost"` を切替

### 9.2 必須ケース

| 領域 | ケース |
|---|---|
| 一意性 | 同一テナント重複 invalid **＋ 別テナントなら同値 valid（鏡像）**。さらに `insert`（バリデーション迂回）で `ActiveRecord::RecordNotUnique` を確認し DB 制約の実在を実証 |
| manager 強制 | バリデーション: `errors[:manager_id]` の属性まで assert（偶然の別エラーで赤くなる「素通り」を防ぐ）。DB: `update_column` で他テナント ID を直接書き込み複合 FK が拒否 |
| テナント解決 | 正常 / 未知サブドメイン 404 / inactive 404 / apex（サブドメイン無し）/ `www` / 大文字 `ACME.` / 正常＋未ログイン→サインイン redirect（①→② の順序固定: 未知サブドメインは未ログインでも 404 が先） |
| 整合不一致 | 401 だけでなく**セッション破棄まで** assert（再リクエストで再ログイン要求）。remember cookie 失効も確認 |
| 認証 | globex のフォームに acme の資格情報→失敗（cookie 分離で空虚に通る「ログインしていない」assert は不可）。同一 email が両テナントに居るとき各々正しく認証。lockable の failed_attempts がテナント間で独立 |
| メール経路 | リセットメール URL に発行元テナントのサブドメイン / 同一 email 2 テナントで acme に要求→acme のみトークン更新・メール 1 通 / acme のトークンを globex サブドメインで消費→404 |
| データ不可視 | 不在 assert の前に「globex 自身のデータが見える」正のアンカー assert を置く（エラーページでも緑になる偽テスト防止） |
| 退職者 | `active=false` ユーザーのログイン拒否 |
| Pundit 強制 | authorize を呼ばないダミー action が `AuthorizationNotPerformedError` を起こす（rescue_from で握り潰していないことの確認を兼ねる）。HomePolicy は許可・非許可の両方向 |
| 列挙耐性 | paranoid 応答がユーザー存在に依存しないこと（メッセージ同一） |

## 10. エラーハンドリング

- テナント解決失敗・inactive → 404（fail-closed）
- 整合不一致 → Warden hook で reset_session + remember 失効。HTML はサインイン画面へ redirect、Turbo fetch/API は 401（素の 401 をブラウザフローに返さない）
- `Pundit::NotAuthorizedError` → 403
- `current_tenant` nil のまま進む経路は作らない（`require_tenant` が最終防衛）

## 11. 運用メモ

- rails console / rake では `ActsAsTenant.current_tenant = Organization.find_by!(subdomain: "acme")` を最初に実行（require_tenant ゆえ）。CLAUDE.md に一行追記する
- 多視点レビューの全指摘と採否は本書に反映済み。CodeRabbit ゲート改訂はブランチ戦略 spec §6 / plan Deferred Task に同日反映
