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
- **WHY**: Rails enum は値名でスコープ・述語メソッドを生成する。衝突先は 2 種ある — ① AR 組込メソッド（`none` / `new` / `valid` 等）、② **同一モデルの別 enum が同じ値名を持つ場合**（例: `AttendanceRecord` の `proxy_clock_reason` と `absence_reason` が共に `:other` を持ち、`other?` 述語が二重定義 → クラスロード時 `ArgumentError`）。②は「2 つ目の enum を足した瞬間」に顕在化するため、enum を増やす Phase で踏みやすい
- **HOW**: 衝突する側の enum に `prefix: <名前>`（または `prefix: true` ＝ enum 名を接頭辞化・例 `absence_reason_other?`）で生成メソッドを逃がす。**enum の値シンボル（`:none`/`:other` 等）は不変**ゆえ DB 値・factory・getter/setter（`absence_reason=`）・代入は変わらず、述語/スコープ名だけ変わる（`other?` 参照は `absence_reason_other?` へ）。`validate: true`/`validate: { allow_nil: true }` と併用可。ID 基点 model 検証（`xxx_only_on_yyy`）は status 述語（別 enum・非接頭辞）を使えば非干渉
- verified: Rails 8.1.3 / 2026-06-16（Phase 2-2a `LeaveRequest.half_day_type` ＝①AR 組込衝突）・2026-06-29（Phase 4-2a `AttendanceRecord.absence_reason` ＝②enum 間 `:other` 衝突を `prefix: true` で解消）

### `Date.strptime(str, "%Y-%m")` は厳格一致でない（1 桁月・末尾ゴミを黙認）

- **WHAT**: `Date.strptime("2026-3", "%Y-%m")` も `Date.strptime("2026-03foo", "%Y-%m")` も `ArgumentError` を投げず `2026-03-01` を返す（`%m` は 1〜2 桁を食い、末尾の残余文字は無視される）。`"2026-13"` 等の範囲外だけは `Date::Error`（`ArgumentError` 子孫）になるので「不正は弾ける」と誤解しやすい
- **WHY**: strptime はフォーマット一致後の trailing を検査せず、`%m` の桁数も緩い。`Date.parse` 同様、ラベルの厳格検証には使えない
- **HOW**: パース前に regex で形を固定する。本リポジトリの "YYYY-MM" は `AttendancePeriod::YEAR_MONTH_FORMAT`（`/\A\d{4}-(0[1-9]|1[0-2])\z/`・`MonthlyAttendanceSummary` の format バリデーションと同一）で `match?` してから `strptime` する
- verified: Ruby 4.0.2 / 2026-06-20（3-1 値オブジェクトのレビュー P3 で実踏）

### 削除済み行への `save!` は 0 行 UPDATE で成功し、例外を上げない（`lock_version` 不在時）

- **WHAT**: `record = Model.find_by(...)`（ロックなし）→ 別トランザクションが同じ行を DELETE して commit → `record.save!` が **`true` を返す**。UPDATE は 0 行に当たるが `ActiveRecord::StaleObjectError` も `RecordNotFound` も出ない。呼び出し側は「保存できた」と信じて後続の副作用（残高消費・監査行の追記）を確定させる
- **WHY**: `StaleObjectError` は optimistic locking（`lock_version` 列）が有る時にのみ 0 行 UPDATE を検出する。列が無ければ Rails は `affected_rows` を捨てる。READ COMMITTED では「ロックなし SELECT → UPDATE」の間に他 tx の DELETE が commit でき、この窓は Rails 側からは不可視
- **HOW**: 既存行の read-modify-write は **`Model.lock.find_by(...)` で FOR UPDATE を取ってから読む**。削除済み行に対する `SELECT ... FOR UPDATE` は READ COMMITTED で 0 行を返すため、`find_by` が nil になり `Model.new` の INSERT 経路へ落ちる（0 行 UPDATE が構造的に到達不能になる）。`find_or_initialize_by` は**ロックを取らない**ので、この用途には使えない
- verified: Rails 8.1.3 / PostgreSQL 18 / 2026-07-10（`attendance_records` に `lock_version` 無し。`Organization` で `delete_all` → `save!` が `true` を返すことを rails runner で実測。`LeaveRequests::ApplyApproval#upsert_attendance_records` が実際にこの形をしており、`Absences::Cancel` / `LeaveRequests::Withdraw` の `destroy!` が DELETE 側になる — 4-2c-3a 設計）

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

### 必須 `belongs_to` の同一組織 validator は presence と二重発火し model テストで単体検証できない

- **WHAT**: 必須 `belongs_to`（`target_user` 等）に付けた `x_must_belong_to_same_organization` を model spec の「他 org の id を代入 → `be_invalid`」で検証しても、**validator を消しても緑のまま**（単体検証できていない）。`errors[:x]` を見ても判別不能
- **WHY**: acts_as_tenant が関連を自テナントに default scope するため、他 org の id を代入すると `x` は `nil` ロード → **必須 `belongs_to` の presence 検証だけで invalid**（`errors[:x]` にも presence の "must exist" が入る）。custom validator は presence と同じ属性に二重発火し、出力が区別できない。**optional `belongs_to`（`subject_user` 等）は presence を通る**ため custom validator が唯一の砦＝ model `be_invalid` が判別的、という非対称がある
- **HOW**: 必須参照の検証可能な防衛線は**複合 FK**。`save!(validate: false)` で `ActiveRecord::InvalidForeignKey` を確認（model 層を貫通して DB 制約だけを露出）。model validator は §3.6-(2) 二層防御の belt-and-suspenders として残すが、テストの判別性は DB 層で担保する。spec 作法は `.claude/skills/gen-spec` 規約 4a/4b 参照
- verified: 2026-06-26（4-1a whole-branch review〔opus〕で顕在化・gen-spec 規約 #4 を二層化して還流）

---

### `ActsAsTenant.with_tenant(信頼できない record.organization)` はテナント境界ではなく昇格プリミティブ（4-2c-2・verified 2026-07-09）

- **WHAT**: 書き込みを伴う service が `with_tenant(@target_user.organization)` で自己ラップしていると、他テナントの `target_user` を渡された瞬間にテナント文脈がその org へ切り替わる。内側で作られるレコードは `organization_id`（`with_tenant` 由来）も `user_id`（引数由来）も侵入先 org のもので**整合する**ため、複合 FK `[organization_id, user_id] → users` も model 検証 `user_must_belong_to_same_organization` も**通過する**。二層防御が両層とも素通りする
- **WHY**: `with_tenant` は「現在の文脈と一致するか」を検証せず、引数のテナントへ無条件に切り替える。§3.6 の二層防御は「`organization_id` が現在のテナントから来る」ことを暗黙の前提にしており、その前提を service 自身が壊す。読み取り専用の利用（`ClosingLock`・`CompanyCalendarResolver`）では無害だが、**書き込み service では「その service 自身がテナント境界になれない」**ことを意味する
- **HOW**: 書き込み service は `with_tenant` へ入る**前**に、操作者（actor）と対象（target）の `organization_id` 一致を独立に検証する（`Absences::Confirm#guard_actor_same_organization!`）。controller の `policy_scope` が一次防衛だが、service 単体でも fail-closed に倒すこと。「複合 FK が最終防衛」と書かれたコメントを、`with_tenant` で自己ラップする service に対して信用しない
- verified: Rails 8.1.3 / 2026-07-09（4-2c-2 の tenant-isolation レビューで検出。実害到達経路は controller の `policy_scope(User)` と `warden_tenant_guard` により塞がれていたが、service 単体では素通りだった）

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

### `retry_on` のリトライ挙動は `perform_now` では検証できない（`perform_enqueued_jobs` で駆動する）

- **WHAT**: `retry_on(SomeError)` を持つジョブで「transient 失敗で raise する／枯渇で error 確定する」を `perform_now` でテストすると意図とズレる。`expect { perform_now }.to raise_error` は偽 FAIL（例外がテストに届かない）になる
- **WHY**: `retry_on` は内部で `rescue_from` を登録する。`perform_now` でもこの rescue が走り、例外を捕捉して `retry_job`（test adapter では再エンキュー）を呼ぶため、例外は呼び出し元へ伝播しない
- **HOW**: リトライ経路は `perform_enqueued_jobs { Job.perform_later(...) }` で駆動する（`wait: :polynomially_longer` のリトライも枯渇まで実行される）。枯渇時の確定処理は `retry_on(..., attempts:) do |job, error| ... end` の **block** に置くと block 形式ゆえ枯渇後 re-raise されず、`delivery.reload` で結果を assert できる（`job.executions` が試行回数）。なお SolidQueue は `retry_on` 無しでは自動再試行しない（transient リトライが要るなら `retry_on` を消さない）
- verified: Rails 8.1 / 2026-06-26（4-1b Task 3 NotificationEmailJob・当初 retry_on 除去案を probe 実走で却下）

### `have_broadcasted_to(obj).from_channel(Turbo::StreamsChannel)` は turbo-rails の `broadcast_*_to` に効かない

- **WHAT**: `Turbo::StreamsChannel.broadcast_prepend_to(user, ...)` を `have_broadcasted_to(user).from_channel(Turbo::StreamsChannel)` で検証すると常に FAIL する（repo 初の Turbo Streams broadcast テストで実踏）
- **WHY**: turbo-rails の `broadcast_*_to` は `ActionCable.server.broadcast(user.to_gid_param, content)` を **raw GID param** をキーに発行する。一方 ActionCable の `broadcasting_for(obj)` は `"ChannelClass:gid_param"` 形式を期待するため不一致
- **HOW**: `have_broadcasted_to(user.to_gid_param)` で raw GID param を直接照合する（または `Turbo::Broadcastable::TestHelper#assert_turbo_stream_broadcasts`）。署名（`turbo_stream_from` の signed_stream_name）は購読ハンドシェイクの検証のみで broadcast キーには関与しないため、サーバ `broadcast_*_to(user)` と client `turbo_stream_from(user)` は同一 raw GID param stream で一致する
- verified: turbo-rails 2.0.23 / 2026-06-26（4-1b Task 4 Notifier・reviewer が gem ソース照合）

### 1 回の呼び出しが複数 broadcast する時、`have_broadcasted_to` の既定 exactly-1 が崩れる（payload で判別する）

- **WHAT**: `Notifier.call` が同一 stream に prepend（ドロップダウン）+ replace（未読バッジ）の **2 件**を broadcast するようになると、カウント無しの `have_broadcasted_to(user.to_gid_param)`（＝exactly 1 を期待）が「2 件あって 1 件期待」で FAIL する。安易に `.at_least(:once)` へ緩めると、2 件のうち 1 件（例: prepend）が欠落しても残り 1 件で green になり**回帰を捕捉できなくなる**（判別性喪失）
- **WHY**: rspec-rails の `have_broadcasted_to` は引数無しだと exactly-once を期待する。`.at_least(:once)` は「stream に何か 1 件以上」しか保証せず、どの broadcast かを問わない
- **HOW**: 各 broadcast を**相互排他な payload マーカー**で個別検証する。`have_broadcasted_to(stream).with(a_string_including("notification-item"))`（prepend の partial の class）／ `...with(a_string_including("notification_bell_count"))`（replace の target id）。turbo は raw HTML **文字列**を送るため `.with` は string matcher（hash ではない・`hash_including(content:)` は不一致）。`.with` は「1 件以上が条件を満たす」照合ゆえ各 broadcast を別マーカーで独立に固定できる。不発火（幻通知防止）の判別は `not_to have_broadcasted_to` が担う
- verified: turbo-rails 2.0.23 / Rails 8.1 / 2026-06-27（4-1c Task 5 で件数 broadcast 追加時に実踏・当初 `.at_least(:once)` 案を review が判別性喪失と指摘→payload マーカーで仕留め）

---

### `disable_referential_integrity` は非トランザクション文脈で raise すると FK・追記専用トリガーを**無効のまま**残す

- **WHAT**: ブロックが例外を投げると、test DB の全 FK と全ユーザートリガーが無効化されたまま残る（実測: 20 テーブル・170 トリガーが `pg_trigger.tgenabled='D'`）。以後の run では複合 FK の越境が素通しになり、`attendance_histories_no_mutate` / `no_truncate`（§4.14 追記専用の**真の backstop**）まで黙って外れる。`connection.truncate_tables` は内部でこれを呼ぶため同じ罠を持つ（FK で参照されているテーブルを引数から取りこぼすと `PG::FeatureNotSupported` で落ちる）
- **WHY**: PostgreSQL アダプタの実装（activerecord-8.1.3 `postgresql/referential_integrity.rb:33-38`）は `ALTER TABLE ... DISABLE TRIGGER ALL` → `yield` → `ENABLE TRIGGER ALL` の 3 段だが、**`ensure` が無い**。`yield` が raise すると再有効化に到達しない。`ALTER TABLE ... DISABLE TRIGGER` は**セッションではなくテーブルに効く DDL** で、`pg_constraint.convalidated` は `'t'` のままゆえ制約定義を眺めても異常に見えない
- **HOW**: **`use_transactional_tests = true` の中でなら安全**（DDL もトランザクショナルなので example 末尾の ROLLBACK で巻き戻る。既存の `spec/services/approvals/route_resolver_spec.rb` が越境データを植えるのに使えているのはこの構造による）。**`self.use_transactional_tests = false` の文脈でだけ危険**。非トランザクションの後片付けは `truncate_tables` を避け **DELETE ベース**で行う（次項参照 — TRUNCATE はこのスキーマでは追記専用トリガーに阻まれる）。検知は `SELECT count(*) FROM pg_trigger WHERE tgenabled='D'`、復旧は `bin/rails db:test:prepare`。**症状は「FK を検証しているテストだけが赤くなる」**ため、防衛ではなくテストの方を疑いがちなのが最大の罠
- verified: Rails 8.1.3 / PostgreSQL 18 / 2026-07-10（4-2c-3a の並行テスト足場を試作中に実踏。transactional な `route_resolver_spec` 実行後は無効トリガー 0 件・非トランザクションで `disable_referential_integrity { raise }` 後は 170 件を実測。`db:test:prepare` で復旧）

### 追記専用テーブルがあると `TRUNCATE ... CASCADE` は非トランザクション後片付けに使えない（DELETE で総当たり）

- **WHAT**: 非トランザクションテストの後片付けに `TRUNCATE TABLE <全テーブル> RESTART IDENTITY CASCADE` は使えない。`attendance_histories` の `BEFORE TRUNCATE ... FOR EACH STATEMENT` トリガー（`attendance_histories_no_truncate`）が**行の有無を問わず無条件に発火**し `attendance_histories is append-only; TRUNCATE is blocked` で落ちるため。しかも PostgreSQL は「そのテーブルを参照する FK が存在する」というスキーマ構造だけで、親テーブル（`organizations` / `users`）の TRUNCATE に CASCADE か同時指定を要求し、CASCADE は追記専用テーブルまで巻き込む。よって親を含む TRUNCATE は**必ず**このトリガーに衝突する
- **WHY**: 「捨てプローブでは TRUNCATE CASCADE が通った」という観測は罠だった — 直前の `truncate_tables` 失敗（前項）が `no_truncate` トリガーを `tgenabled='D'` にしたまま残しており、**無効化されたトリガーの上で TRUNCATE が空振りしただけ**。`db:test:prepare` で復旧させると同じ TRUNCATE が拒否される。「テストが緑」は防衛が生きている証拠ではなく、直前の失敗が防衛を外していた証拠だった
- **HOW**: `TRUNCATE` でなく **`DELETE`** で消す。`DELETE` は行が実在する場合のみ FK 違反になり、`attendance_histories_no_mutate` は `FOR EACH ROW` ゆえ 0 件なら発火しない（＝履歴を書かないテストでは安全に完走）。依存順は固定リストにせず「削除できたテーブルから外す総当たり（消せた行が 1 つも無くなったら残りを報告して raise）」で解く（schema 変更・migration 順に依存しない）。実装は `spec/support/concurrency_helpers.rb#truncate_all_tables!`。`RESTART IDENTITY` 相当は失う（`DELETE` は sequence を戻さない）が、行ロック検証テストはそれに依存しない。**追記専用テーブルに実際に行を書く非トランザクションテストはこの helper では消せない**（親の DELETE が FK 違反で残る）— それは §4.14 の設計意図どおりの正しい失敗で、そのテストは transactional test にすべきという signal
- verified: Rails 8.1.3 / PostgreSQL 18 / 2026-07-12（Task 1 実装者が TRUNCATE 版の brief コードで FAIL を実測 → psql で `no_truncate`＝`FOR EACH STATEMENT`・`no_mutate`＝`FOR EACH ROW` を確認し DELETE 版へ。controller が単体 TRUNCATE の拒否を再実測して裏取り）

### 行ロックの競合テストは 2 接続が要る（バグの再現は 1 接続で足りる）

- **WHAT**: 「ロックが無いと壊れる」ことの証明と「ロックがあれば壊れない」ことの証明は、必要な足場が違う
- **WHY**: 「消えた行への read-modify-write」は SQL と Rails の性質であって並行性の性質ではない。1 接続で `read → delete_all → save!` と並べれば同じ SQL 列が流れる。一方 `SELECT ... FOR UPDATE` の効果は**他 tx を待たせること**なので、待ち手のいない 1 接続では観測できない
- **HOW**: 待たせる側の証明だけ 2 接続にする。① 対象 example group で `self.use_transactional_tests = false`（別接続は未コミットデータを見られない）② 保持スレッドは `ActiveRecord::Base.connection_pool.with_connection` で自前の接続を取る ③ **`ActsAsTenant.test_tenant` は `Thread.current` 局所**なので、スレッド内では改めて `ActsAsTenant.with_tenant(org)` で包む ④ 待ちを sleep で測らず `SET lock_timeout = '300ms'` を撃って `ActiveRecord::LockWaitTimeout` を期待する（決定的になる）⑤ 後片付けは `spec/support/concurrency_helpers.rb#truncate_all_tables!`（DELETE 総当たり — TRUNCATE は追記専用トリガーに阻まれる・前項）。`config/database.yml` の `max_connections: 5` でスレッド 2 本は収まる。足場は `ConcurrencyHelpers#hold_row_lock` / `#truncate_all_tables!` に固めてある
- verified: Rails 8.1.3 / PostgreSQL 18 / acts_as_tenant 1.0.1 / 2026-07-10（捨てプローブで A/B とも実測。既存の `spec/services/holiday_work_requests/apply_approval_spec.rb` は `Relation#lock` の `first` を 1 回だけ nil にする 1 接続シミュレーションで、下流は実挙動を走らせている＝この使い分けの先例）

### `hold_row_lock(...) { 同じ行への無 timeout write }` は自己デッドロックする

- **WHAT**: `hold_row_lock(AttendanceRecord, rec.id, org:) { AttendanceRecord.where(id: rec.id).delete_all }` のように、ロック保持ブロックの yield 内で**保持中の行そのもの**を待ち無し（`lock_timeout` 無し）で更新・削除すると、rspec が無期限ハングする（実測 5 分で kill）
- **WHY**: `hold_row_lock` はロック解放（`release << :go`）を `ensure` で**yield 復帰後**に行う設計。ところが yield 内の `delete_all` は保持スレッドが握る行ロックを待ち、その解放は yield が返るまで来ない → 相互待ち。Task 1 の `concurrency_helpers_spec.rb` の正しい使い方が `SET lock_timeout = '300ms'` を撃って `LockWaitTimeout` を**期待**しているのは、素の write が無期限に待つこの性質を回避するため
- **HOW**: 「保持スレッドが握る行を、別スレッドが待つ」構図で競合を作るなら 2 通り。① 待つ側に `lock_timeout` を設定し `LockWaitTimeout` を期待する（Task 1 helper spec の型）。② **保持を hold_row_lock に任せず**、deleter（未コミット DELETE を短時間保持）と approver（実サービス呼び出し）を別スレッド・別接続で並走させ、deleter が commit する前に approver をロック待ちへ入れる（Task 2 `apply_approval_spec.rb` の 2 接続テストの型 — `hold_row_lock` は「読み取り FOR UPDATE を保持して別 tx の write を待たせる」用途に向き、「実サービスの内部 write を競合させる」用途には deleter/approver 並走が要る）
- verified: Rails 8.1.3 / PostgreSQL 18 / 2026-07-12（Task 2 実装者が brief の hold_row_lock 流用コードでハングを実測 → deleter/approver 並走へ再設計。修正前 `rows.count=0` で判別性を確認）

### `find_each` はカスタム `order` を無視して id 昇順を強制する

- **WHAT**: `scope.order(:work_date).find_each { ... }` と書いても **work_date 順にならず id 昇順**で回る（Rails が警告を出しつつ order を捨てる）。行ロックを「特定の列順で取りたい」意図が黙って id 順にすり替わる
- **WHY**: `find_each` / `find_in_batches` はカーソルを主キー（id）で分割してバッチングするため、任意の order と両立しない。設計上 id 順が強制される
- **HOW**: ロック取得順を制御したい・件数が小さい（1 リクエストの日数ぶん等）なら `find_each` をやめて **`.order(:col).each`** にする（全件ロードするがバッチング不要な規模なら問題ない）。4-2c-3a では `Withdraw#restore_attendance_records` を `find_each`（id 順）→ `.order(:work_date).each` にして `ApplyApproval`（work_date 昇順でロック）と同一テーブル内のロック取得順を揃え、循環待ちを構造的に消した（設計書 §3.3 の同一テーブル内順序規約）。「find_each + order」は id 順に落ちるため**順序を揃えたつもりで揃っていない**罠になる
- verified: Rails 8.1.3 / 2026-07-12（4-2c-3a Task 3 レビューで実踏。`AttendanceRecord` は `[user_id, work_date]` unique ゆえ work_date が決定的な全順序キー）

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

### enum の排他検証（`X_only_on_status`）は「その status を出る遷移」で随伴列をクリアしないと上書き `save!` が RecordInvalid で親 tx を巻き戻す（4-2a・verified 2026-07-02）

- **WHAT:** ある status の時だけ非 nil を許す列に「非 status ∧ 非 nil → error」の排他検証を足すと（例: AR `absence_reason_only_on_absent`）、その status から**別 status へ上書きする既存パス**が随伴列をクリアしないまま `save!` した瞬間に `RecordInvalid`。副作用 service が「内側 rescue しない」設計（§9.5・with_lock 内伝播）なら承認/主操作の tx ごと atomic に rollback する。実例: `LeaveRequests::ApplyApproval#upsert_attendance_records` が `find_or_initialize_by(user_id:, work_date:)` で既存 `absent` AR を拾い `status=:on_leave` に上書き → `absence_reason` 残留で `Approvals::Approve` の承認全体が rollback（「承認できませんでした」に反転）。
- **WHY:** plain enum は AASM の exit フック（after_transition で随伴列を掃除する置き場）を持たない。「この status は単方向終端だから遷移後始末は不要」という前提で排他検証だけ足すと、実際には出辺のある status（SPEC §13.1 の `absent→on_leave`/`→working`）で地雷になる。検証を追加するスライスと、その status を出る遷移を起こすスライスが**別 PR**だと、追加時は全緑・consumer 出荷時に初めて live 化する dormant バグになる（4-2a 追加 → 4-2c 出荷で発火）。
- **HOW:** 排他検証を足す前に「この status を**出る**遷移が既存/将来にあるか」を §13.1 の状態機械図で確認。出辺があるなら、遷移を起こす各 apply_approval/service が随伴列クリアの責務を負う（上書き時に `record.x = nil` を明示）か、`before_validation { self.x = nil unless status_owning_x? }` で正規化する。回帰テストは「旧 status（随伴列有）→ 新 status への遷移が成功し随伴列が nil」を突く（検証単体の positive/negative だけでは遷移の地雷を捕まえられない）。
- **HOW（修正実装時の二次罠・capture-before-assign）:** クリア条件の旧 status 述語は**新 status を代入する前**に捕捉せよ。`record.status = new_status` を先に書いてから `record.absent?`（旧 status 述語）を見ると status は既に新値ゆえ**常に false → クリアも監査記録も無言で no-op** → 排他検証が依然発火し「fix したのに rollback」になる。正: `was_absent = record.absent?` を代入前に取り、`if was_absent` でクリア + 監査（例 `absence_to_paid`）。クリアは**遷移した時だけ**に gate（無条件クリアは非遷移 upsert の legit な随伴列＝別種の note 等を消す）。DB CHECK（`x IS NULL OR status = <owner>`）を対称に張ると clear 忘れを DB が backstop する。
- verified: Rails 8.1.3 / 2026-07-02（4-2 設計 2nd-pass で検出＝原則整合/労務/tx の 3 視点独立確認。**4-2c-1 PR で修正実装**: apply_approval の absent→on_leave に capture-before-assign の exit クリア + `absence_to_paid` 記録 + `absence_reason` DB CHECK・実 approve path 回帰。capture-before-assign の二次罠は接ぎ目レビュー §12② が予見し実装 task-reviewer が named-check で固定）

---

### `rescue RecordInvalid` で「並行レース」を吸収したつもりが本物の検証失敗を握り潰す（4-2c-2・verified 2026-07-09）

- **WHAT**: per-day savepoint の `rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid` に「並行 clock_in が同日 AR を先に作った等」というコメントを付けて skip 扱いにしていた。しかし `AttendanceRecord` は**同日 uniqueness のモデル検証を意図的に置いていない**（`attendance_record.rb` のコメントが明言・一次防衛は unique index）。したがってその競合は**必ず `RecordNotUnique`** で来る。`RecordInvalid` の arm が拾うのは越境検証・毒入力・監査行の不備といった**本物の失敗のみ**で、それが「既に勤怠記録があるためスキップしました」という事実と異なる flash に化け、ログにも残らなかった
- **WHY**: 「レースを吸収する」意図で例外クラスを 2 つ並べると、片方が実際には別の意味を持つことに気付けない。**モデルに uniqueness 検証があるかどうかで `RecordNotUnique` / `RecordInvalid` のどちらが飛ぶかが変わる**ため、モデル側の検証方針を読まずに rescue の広さを決めてはならない
- **HOW**: rescue する例外は「その経路で実際に飛び得るもの」だけに絞る。`RecordNotUnique` = DB unique index の競合（吸収してよい）／`RecordInvalid` = model 検証の失敗（ログ + `Rails.error.report` して再 raise・fail-closed・controller で 422 に落とす）。既存の正しい idiom は `HolidayWorkRequests::ApplyApproval#lock_or_create_balance`（`e.record.errors.details[:x]` で `:taken` 由来のみを握り潰し、他は再 raise）
- verified: Rails 8.1.3 / 2026-07-09（4-2c-2 で tenant-isolation と approval-engine の 2 レビュアーが独立に検出。mutation testing で「re-raise を skip に戻すと当該テストが落ちる」ことも実証）

---

### method-level `rescue RecordNotFound` は「同一アクション内の別の find」由来の例外まで一括捕捉する（4-2c-3b・verified 2026-07-23）

- **WHAT**: controller の `create` に、認可の `roster.find(params[:user_id])`（scope 外 = IDOR → `rescue_from` で 404 に落としたい）と、対象取得の `find_by!` / `with_lock` reload（対象消失 = 競合 → その場で 422/see_other に落としたい）の**両方**があり、`create` の method-level `rescue ActiveRecord::RecordNotFound` で後者だけを捕まえたつもりだった。Ruby の method-level rescue は**例外の発生元を区別しない**ため、`roster.find` の RecordNotFound（IDOR）まで同じ arm に飲まれ、`ApplicationController#rescue_from`（404）に届かず see_other に化けた。IDOR テスト（404 期待）が 303 で落ちて発覚
- **WHY**: 「roster.find が先に評価されるから 404 が先に返る」という直感は誤り。rescue は評価順ではなく**例外クラスの一致**で捕まえる。同一メソッドに「伝播させたい RecordNotFound」と「その場で握りたい RecordNotFound」が同居すると、後から書いた rescue が前者も奪う
- **HOW**: 「その場で握りたい find」だけを private メソッドへ切り出し、`rescue RecordNotFound` をそのメソッドに閉じ込める。「伝播させたい find」（認可の roster.find 等）は rescue を持たないメソッドに残し、`ApplicationController` の `rescue_from ActiveRecord::RecordNotFound`（404）へ届かせる。二段 find を持つ controller を書くときは「どの find の例外をどこで捕まえるか」を find ごとに設計する
- verified: Rails 8.1.3 / 2026-07-23（4-2c-3b Task 6 で implementer が plan のコードのバグとして検出・修正。task-reviewer が呼び出しグラフを独立トレースし `application_controller.rb` の `rescue_from` 実在を確認）

---

### `.includes(:user)` は孫関連（`user.organization`）を preload しない — ループ内で辿ると N+1（4-2c-3b・verified 2026-07-23）

- **WHAT**: `AttendanceRecord.absent.includes(:user)` した collection を view でループし、helper が `record.user.organization` を辿った。`includes(:user)` は `user` までしか eager load せず `user.organization`（孫）は各 record で lazy に引かれるため、distinct user 数に比例した SELECT が飛ぶ。コメントに「純計算・DB を叩かない」と書いていたが実態は N+1
- **WHY**: `includes` は指定した関連の 1 段だけを preload する。孫まで欲しければ `includes(user: :organization)` とネストが要る。だが本ケースは**そもそも record 依存で organization を引く必要が無かった**: `AttendanceRecord`（と `User`）は `acts_as_tenant` で単一テナントに絞られるため `record.user.organization` は request 中ずっと `current_user.organization` と同値
- **HOW**: テナントスコープ下で「record から辿った organization」を使う helper は、`current_user.organization`（Devise が request 単位でメモ化・追加 SELECT は高々 1 回）に置き換えられる。より一般には、view ループ内の helper が関連を辿っていないかを N+1 の観点で確認する（`includes` のネスト漏れは静かに N+1 化する）。コメントで「DB を叩かない」と書くなら実際に叩かないことを確認してから書く
- verified: Rails 8.1.3 / 2026-07-23（4-2c-3b Task 7・task-reviewer が「includes は user までで organization は preload しない」と指摘・current_user.organization への 1 行置換で解消）

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

### `/preflight` は Gemfile.lock 無変更だと bundle-audit を skip → CI security（常時 `--update`）と非対称で transitive vuln が PR で初顕在化

- **WHAT**: 依存を一切触らない PR（feature コード + spec のみ）でも CI の security ジョブ（`bin/bundler-audit check --update`）が突然 fail し得る。ローカル `/preflight` は緑なのに CI だけ赤、という形で現れる
- **WHY**: `/preflight` は diff scope 最適化で「Gemfile.lock 無変更 → bundle-audit skip」する設計（skill Phase 0）。一方 CI の security は**毎回 `--update` で最新アドバイザリ DB を取得**し全 lock を検査する。新規公開されたアドバイザリが既存の transitive gem（nokogiri・concurrent-ruby 等の Rails 依存）を flag すると、自分の diff と無関係に CI が落ちる。main を再実行しても同様に落ちる＝当該 PR の回帰ではない
- **HOW**: ① まず無実確認（`git diff --stat <base>..HEAD -- Gemfile Gemfile.lock` が 0 行なら diff 起因でない）。② `bundle update <gem> --conservative` で該当 gem のみ patch 級 bump（transitive でも対象指定可・手編集は `block-gemfile-lock-edit` フックで不可ゆえ bundle 経由）。③ `bin/bundler-audit check --update` が "No vulnerabilities found" になるまで全件詰める（1 件直すと次が現れることがある）。④ feature PR に混ぜず**独立の chore PR**で出すと reviewed diff が汚れず main 全体のゲートも復旧。⑤ 恒久候補: preflight に「lock 無変更でも audit を回す」オプション or CI security の非ブロッキング/定期実行分離（運用判断）
- verified: 2026-06-23（3-3a の PR #16 で security のみ fail。nokogiri 1.19.3→1.19.4・concurrent-ruby 1.3.6→1.3.7 の transitive 2 gem を chore PR で bump し解消＝両 gem は 3-3a の diff 外。bundler-audit "No vulnerabilities found" を実測）

### `org.today` 相対ロジックを持つ service の spec は「今日」の day_type を pin しないと実行日依存で flaky（4-2b・verified 2026-07-02）

- **WHAT**: 「今日が稼働日か」で分岐する service（例: `AttendanceAnomalies::Detect` の次稼働日ゲート `working_day?(org.today)`）の spec を `travel_to` も CompanyCalendar 登録もせず書くと、**テスト実行日の実曜日**で結果が変わる。2026-07-02（木・fallback で稼働日）に `notified_on == nil` を期待する例が `Thu, 02 Jul 2026` を得て落ちた。さらに、検知と通知を**同一 call の 2 パス**で回す service は、テストが「pass 2 起動の形式的トリガー」として渡した補助日付（例 `Date.new(2026,4,30)`・木）が稼働日だと、pass 1 が全 active user に対し**幽霊候補**を作り、pass 2 が同 call で即通知して通知件数を汚染する。
- **WHY**: `org.today = Time.current.in_time_zone(tz).to_date`。`travel_to` 未使用なら実 wall-clock。CompanyCalendarResolver は未登録日を曜日 fallback（`weekday`=稼働）で埋めるため、平日に走らせると「今日」も「補助日付」も稼働日扱いになり、`org.today` 依存の副作用（同一 run 内 detect→notify）が発火する。「別の run のトリガー」のつもりの引数が pass 1 の検知対象日を兼ねている点が盲点。
- **HOW**: ①「今日」に依存する assert は `create(:organization, time_zone: "UTC")` + `travel_to(Time.utc(Y,M,D,2))` で org.today を固定するか、**当該 org.today を `create(:company_calendar, date: org.today, day_type: :company_holiday/:weekday)` で明示登録**して day_type を pin する。②同一 call 2 パス service では、pass 2 起動用に渡す補助日付も holiday 登録して pass 1 の幽霊検知を止める。③「実行日 2026-05-01（金）等」に偶然一致すると `working_calendar(prev_day)` と二重登録で date-unique 制約に当たり得る点も留意（4-3 週次/月次バッチの spec でも同型に注意——本 service が規範実装）。
- verified: Rails 8.1.3 / 2026-07-02（4-2b Task 3 の SDD 実装で実踏。implementer が TDD RED で 3 例 flaky を検出→spec を holiday pin で決定化・production 無改変・task-reviewer が同一 call notify を正仕様と独立確認）

### zsh では `cmd $FILES` が単語分割されず、rubocop は「0 files inspected」で緑を返す（4-2c-2・verified 2026-07-09）

- **WHAT**: `FILES=$(git diff --name-only main...HEAD | grep '\.rb$' | tr '\n' ' ')` の後に `bundle exec rubocop --force-exclusion $FILES` と書くと、rubocop は `Inspecting 0 files` / `no offenses detected` と表示して **exit 0（緑）** を返す。実際には 1 ファイルも検査していない
- **WHY**: zsh は既定で `SH_WORD_SPLIT` が off であり、unquoted な変数展開を単語分割しない（bash とここが違う）。22 個のパスが結合された 1 個の巨大な引数として渡り、rubocop は存在しないパスを黙って無視する。**「lint が緑」と「lint が何かを検査した」は別の命題**
- **HOW**: `git diff --name-only main...HEAD | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion` とパイプで渡す（`/preflight` skill の Phase 1 は既にこの形で正しい）。実行結果の `Inspecting N files` の N が期待どおりか毎回確認する。鉄則 2（`--force-exclusion` を付けろ）と同根で、**付けても検査対象が 0 なら意味がない**
- verified: zsh 5.9 / rubocop / 2026-07-09（4-2c-2 の仕上げで実踏。22 ファイル渡したつもりが 0 ファイル検査だった）

### 読み取り専用のはずのレビュアーが共有ワークツリーでプロダクションコードを mutation する（4-2c-2・verified 2026-07-09）

- **WHAT**: サブエージェントのレビュアーに「テストの判別性を確認せよ（ガードを削除したら実際に落ちるか）」と指示すると、全ツールを持つ汎用エージェントは素直に **mutation testing**（実装を壊して spec を回す）を始める。共有チェックアウトで走ると、並行する implementer が「File has been modified since read」でブロックされ、レビュアーが途中終了すればプロダクションコードが壊れたまま残る。実例: `guard_actor_same_organization!` の中身が `# MUTATION-TEST: disabled` に一時置換された状態を、別 implementer が検出して報告した
- **WHY**: dispatch prompt に「コードは変更しないこと」と書いても、`general-purpose` エージェントは `Edit`/`Write`/`Bash` を持つ。「判別性を確認せよ」という要求と「編集するな」という制約が矛盾するため、前者が優先される。SDD は 1 つのワークツリーを implementer とレビュアーで共有するため、レビュアーの一時的な編集が他者の作業と衝突する
- **HOW**: ①レビュアーに判別性の**実証**を求めるなら `isolation: "worktree"` で隔離する ②あるいは「編集も rspec 実行も禁止・判別性は静的読解で論証せよ」と明示的に禁じる（実測より確度は落ちるが安全）③implementer 側には「衝突を検出したら上書きせず即報告せよ」と指示しておく（本件はこれが機能して実害ゼロで済んだ）
- verified: 2026-07-09（4-2c-2 の R3/R4 で実踏。mutation 自体は 4 つの kill を実証して有用だったが、走らせた場所が誤りだった）

---

## メタ原則

- **レビューは書いた場所の近くに置く**: 設計レビューは設計の虫しか取れない。計画にコードを書くなら計画コードにレビューを、環境の虫（brakeman・CI）は各タスクの完了条件に
- **サブエージェントはフックをすり抜ける**: PostToolUse の自動整形・検証はサブエージェント内では保証されない。ディスパッチ指示に検証コマンド（rspec / rubocop / 必要なら brakeman）を完了条件として明記する（SF 版 lint-test-strategy の教訓と同一）
- 新しい罠を踏んだら / 仕留めたら、**修正 PR と同じブランチで本書に 1 項目追記**する

---

## SolidQueue

### SolidQueue を dev で動かすには queue 用 DB 配線が要る（本番のみ既定設定）

- **WHAT**: Phase 3-2 まで queue adapter は本番のみ `:solid_queue` + 専用 queue DB。dev/test 未設定で、dev で job を enqueue しても処理されない。`connects_to` 不整合で `DatabaseNotSupported` や接続エラーが起き得る
- **WHY**: `config/environments/development.rb` に adapter 設定が無く、`database.yml` の dev が単一 DB（queue 接続先なし）だったため
- **HOW**:
  - `test.rb` に `config.active_job.queue_adapter = :test`（Rails 既定だが明示・assert_enqueued の安定化）
  - `development.rb` に `config.active_job.queue_adapter = :solid_queue` + `config.solid_queue.connects_to = { database: { writing: :queue } }`
  - `database.yml` の `development:` を primary/queue の multi-db 形へ変換（test: は単一のまま変えない）。queue に `database: gatcha_development_queue` + `migrations_paths: db/queue_migrate`
  - `db/queue_migrate/` ディレクトリ（空・.keep 付き）を作成（無いと db:migrate が dir-not-found で落ちる）
  - `bin/rails db:prepare RAILS_ENV=development` で `gatcha_development_queue` が自動作成され、Rails が `db/queue_schema.rb`（接続名 `queue` に対応するスキーマファイル）を auto-discover してロード → 11 テーブルが生成される
  - ワーカー起動: `bin/jobs`
- **fallback**: `connects_to` を外し SolidQueue テーブルを primary DB に置く方式も可（ENV 毎の接続分離は不要）
- verified: Rails 8.1 / SolidQueue / Ruby 4.0.2 / 2026-06-21（3-2 Task 15 で実踏。`db:prepare` が `db/queue_schema.rb` を自動ロード・rspec 975/0 確認）

### rspec 後の `db/queue_schema.rb` は「内容差なしの mtime ノイズ」（`git add` しない）

- **WHAT**: rspec 走行後に `git status` が `db/queue_schema.rb` を modified と**散発的に**表示するが、`git diff` は **0 行**（内容は `version: 1` で安定）。「schema を変えたか？」と誤認して `git add` すると無関係差分をコミットに混ぜる
- **WHY**: test 実行時の queue 接続が同ファイルを **mtime-touch** するだけで再生成はしない。racy stat ゆえ走行ごとに出たり出なかったりする（1 回目で flag・2 回目 clean を実測）
- **HOW**: **内容差が無いので `git add` しない**。コミット前に `git status` で混入していないことだけ確認（混入していれば `git checkout -- db/queue_schema.rb`・大半は no-op）。生成系スキーマ（schema.rb 同様）は手で触らない原則の延長
- verified: 2026-06-26（4-1a SDD で全タスク実踏。`git diff db/queue_schema.rb` 常に 0 行＝mtime のみ・「再生成で内容が変わる」は誤り）

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
