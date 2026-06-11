# Phase 0b-1（ユーザー管理）設計仕様

- 日付: 2026-06-10（多視点レビュー反映済み: 原則整合・実用主義・YAGNI・テナント分離・テスト網羅の 5 視点並列）
- 対象: ROADMAP Phase 0b-1。社員 CRUD（hr_admin 専用）・role / manager_id / exempt_from_overtime の変更 UI・招待メール
- 上位文書: [docs/SPEC.md](../../SPEC.md)（§3.3〜3.4・§4.3・§12.3・§16.7）/ [docs/ROADMAP.md](../../ROADMAP.md)
- 前提: Phase 0a 基盤（テナント解決 fail-closed・Devise テナントスコープ・Pundit 既定 deny・TenantDeviseMailer）

## 0. スコープと確定済み判断

| 論点 | 決定 |
|---|---|
| 招待方式 | **案 1: recoverable 転用 + 不可知ランダムパスワード**（SPEC §16.7-3 準拠）。devise_invitable は不採用（テナントスコープ防御の再実装コストに見合わない）。初期パスワード手渡しは不採用（既知パスワード平文流通の事故経路） |
| 締め出し防止 | **最後のアクティブ hr_admin を保護** — 降格・無効化をモデルバリデーションで拒否（自分でも他人でも）。他にアクティブな hr_admin がいれば自己降格も可 |
| 退職（無効化）と部下 | **ブロック型** — アクティブな部下がいる間は無効化を拒否し、付け替えを促す。一括付け替え UI は作らない（個別編集で誘導）。**代入側も対称に守る**（ガード④: 非アクティブ上長の指定拒否） |
| 管理画面の器 | **`Admin::` 名前空間 + 最小ナビ** — `Admin::BaseController`（hr_admin ゲート一括）+ タブナビ ViewComponent。タブは当面「社員」のみ、0b-2 以降は追加するだけ |
| 物理削除 | 提供しない。無効化（`active=false`）のみ（将来の勤怠 FK・履歴保全。退職処理の本体は SPEC §4.3 → 後続フェーズ） |
| mass-assignment | `role` / `manager_id` / `exempt_from_overtime` は **Admin 名前空間のコントローラのみ**が明示 permit。`active` は permit に含めず **deactivate / activate メンバーアクション専用**（経路一本化）。一般経路の恒久除外は維持。**本決定は 0a 設計 §7・ROADMAP 0b-1 行の「専用アクション」方式を supersede する**（アクション細分は AttendanceHistory 不在の現時点では YAGNI）— §5 で SSOT 側の文言も更新する |
| hr_admin の email 編集 | ログイン済みユーザーの email 差し替え + 再送で事実上のアカウント引き継ぎが可能だが、**hr_admin の強権として受容**（confirmable は導入しない。操作の監査はユーザー管理監査の設計時に扱う） |
| devise バージョン | `gem "devise", "~> 5.0"` に悲観固定（protected メソッド・内部オーバーライドへの依存があるため。メジャーアップは system spec を通してから） |

**0b-1 の範囲外:** 一括 CSV インポート・部下の一括付け替え・プロフィール自己編集（社員本人による変更）・退職処理の連動（UserWorkPattern 無効化等 → 0b-4 以降）・ユーザー管理操作の監査記録（**AttendanceHistory は勤怠イベント専用スキーマで受け皿にならない**。必要になった時点で別途設計）。

## 1. 構成

```
config/routes.rb                            # namespace :admin { resources :users, except: :destroy + member patch ×3 }
app/controllers/admin/base_controller.rb    # hr_admin ゲート（多層防御の外殻）
app/controllers/admin/users_controller.rb   # index/show/new/create/edit/update + deactivate/activate/resend_invitation
app/policies/admin/user_policy.rb           # hr_admin? のみ許可・Scope = 組織全員（inactive 含む）・`organization_id` 明示（without_tenant 文脈でも横断しない）・resend_invitation? に条件
app/models/user.rb                          # ガード 4 種 + 招待（send_invitation_instructions）
app/mailers/tenant_devise_mailer.rb         # invitation_instructions 追加（record.organization からホスト構成・current_tenant 非依存）
app/views/admin/users/ + devise/mailer/invitation_instructions.*
app/views/devise/passwords/edit.html.erb    # gem 既定（英語 "Change your password"）を生成し「パスワード設定/変更」兼用の日本語文言へ
app/components/admin/nav_component.*        # タブナビ（「社員」のみ）
```

- **認可の規約（多層防御）:** `Admin::BaseController` の before_action ゲートは名前空間の外殻であり、`verify_authorized` を満たした扱いにしない。各アクションは必ずレコード（または `[:admin, User]`）に対し `authorize` を呼ぶ。一覧は `policy_scope` 起点（SPEC §3.4）。対象指定は scope への `find` で解決し、他テナント id は 404（IDOR）— read 系だけでなく **write 系（update / deactivate / resend_invitation）も同経路**
- 招待の「保存 → トークン発行 → 送付」は Service Object にしない: 2 ステップで構成され、送付失敗は「招待再送」で回復できるため（§2.2-2 と §2.2-5 のバランス。多段のロールバックを要する副作用がない）

## 2. 招待フロー（recoverable 転用）

1. **作成:** `/admin/users/new` — 氏名・メール・社員番号・role・上長・管理監督者フラグ。パスワード欄なし。モデルが作成時に `SecureRandom.hex(32)` を内部セット（§2.2-2 の「軽微な値セット」に該当。表示・ログ・メール本文に出さない）
2. **送付:** モデルに公開ラッパー **`User#send_invitation_instructions`** を定義し（protected な `set_reset_password_token` への依存をモデル内 1 箇所へ閉じ込める。recoverable の `send_reset_password_instructions` の鏡像）、`TenantDeviseMailer#invitation_instructions`（専用文面）を送る。**配送はリクエスト文脈内の `deliver_now`**（0a の Devise 経路と同型）。`deliver_later` 化する場合は user_id + organization_id をプリミティブで渡し `ActsAsTenant.with_tenant` でラップした子ジョブとする（SPEC §3.6-(1)）。**`without_tenant` による回避は禁止**。mailer は `record.organization.subdomain` からホストを組み、`current_tenant` に依存しない
3. **受諾:** 標準の `devise/passwords#edit`（文言調整済み・§1）でパスワード設定 → サインイン。テナント突合（`with_reset_password_token` の 404）は 0a 実装がそのまま守る。既知事項: hr_admin が自分のブラウザでリンクを検証するとログイン済みのため弾かれる（`require_no_authentication`・仕様通り）（実装時に判明: devise の prepend before_action がテナント解決より先に走るため `User.serialize_from_session` を without_tenant 化し、テナント突合は warden_tenant_guard が単一点で担う。already_authenticated で root へリダイレクトされる）
4. **期限・再送・自己救済:** トークン期限は Devise 既定 6 時間のまま（`reset_password_within` 延長は通常リセットの安全性を下げるため不採用）。期限切れの主回復経路は**本人による `passwords#new`（パスワードを忘れた）からの自己再発行**——招待ユーザーも recoverable ゆえ機能する。メール文面と期限切れエラー画面にこの導線を案内する。補助として一覧の未受諾ユーザーに「招待再送」ボタン（再送で旧トークン失効）。招待メール自体を紛失した場合（リンクもサブドメインも不明）の救済が再送の主用途
5. **再送条件のサーバ側強制:** `Admin::UserPolicy#resend_invitation?` = `hr_admin? && record.sign_in_count == 0 && record.active?`。UI のボタン表示条件と同一の条件をポリシーで強制し、直接 POST は 403（ログイン済みユーザーへのトークン強制発行を塞ぐ）。注: `sign_in_count == 0` を「未受諾」とみなす判定は `sign_in_after_reset_password` 既定 true に依存する（コードコメントで明記）
6. **誤入力の回復:** hr_admin がメールを編集 → 旧トークンは Devise が自動失効（`clear_reset_password_token?`）→ update 成功時に `email_previously_changed? && sign_in_count == 0` なら **flash で再送を促す**（自動送信はしない。送信は明示操作に限る）

## 3. モデルガード 4 種

| ガード | 実装 | エラーメッセージ |
|---|---|---|
| ① 最後の hr_admin 保護 | `on: :update`: `role` が hr_admin から変わる or `active` が false になるとき、**自分以外のアクティブな hr_admin** が同一組織に不在なら拒否。判定クエリは **`organization_id` を明示条件に含める**（`where(organization_id:, role: :hr_admin, active: true).where.not(id:)` — `without_tenant` 文脈の console/seed でも fail-open しない。0a の二重防衛規約と同型） | 「組織最後の管理者は降格・無効化できません」 |
| ② 部下持ち無効化のブロック | `active` → false 時に `subordinates.where(active: true)` が存在すれば拒否（inactive のみなら許可） | 「アクティブな部下が N 名います。先に上長を付け替えてください」 |
| ③ 上長の自己参照・循環の拒否 | `manager_id == id` 拒否 + 上長チェーンを **visited-set（既訪問 id 集合）方式**で遡上し、自分または既訪問 id に到達したら拒否（深さ定数は持たない — §2.2-5 の「再帰ガード」型を避ける） | 「（`:manager_id` に）は循環しています」 |
| ④ 非アクティブ上長の拒否 | `manager_id` 変更時 **または再有効化（active が true に変わる）時**、指定先が `active: false` なら拒否（②の代入側の対称。フォームの上長候補も `active` スコープで絞る） | 「は在籍中（アクティブ）のユーザーである必要があります」 |

- ③の前倒し根拠: **Phase 1 の `subordinate_of?`（部下可視性・§3.4）が上長チェーンを全段遡上する**ため、循環データの混入は参照認可の無限ループになる（Phase 2 の固定 2 段ルートは 2 hop のみで根拠としては副次的）。0b-1 は `manager_id` の唯一の UI 書き込み点であり、不変条件は書き込み時に守るのが最安
- **既知の限界（v1 受容）:** ①は「2 人の hr_admin を並行リクエストで同時降格」、③は「A.manager=B / B.manager=A の同時 save」の競合窓がバリデーション読み取りと更新の間に残る。発生頻度・影響に対し行ロックは過剰のため v1 はバリデーションのみとし、ここに明記して受容する。**引き継ぎ:** Phase 1 の実行時遡上（`subordinate_of?` 等）は検証時ガードをバックストップにせず、自身でも visited-set / 深さ上限を持つこと
- 鏡像が必須: 他テナントの hr_admin の存在は①の判定に影響しない（`organization_id` 明示によりスコープ非依存で成立。spec で固定する）。②③④のクロステナントは複合 FK `(organization_id, manager_id)` が構造的に遮断（0a 実装済み）

## 4. テスト（/gen-spec 規約）

**model:**
- ガード①: 2×2 マトリクス（降格×無効化 / 自分×他人）+ 「他に hr_admin はいるが inactive → 拒否（救済要員に数えない）」+ 「他にアクティブ hr_admin がいれば自己降格可」+ 鏡像（他テナントの hr_admin がいても保護）+ **`without_tenant` 下の save でも保護されること**
- ガード②: 拒否（アクティブ部下あり・メッセージの N 名まで assert）/ 成功（部下なし・**inactive の部下のみ**）
- ガード③: 自己参照 / 2 ノード循環 A→B→A / 3 ノード以上の循環 / 正当な長鎖は valid、の 4 象限
- ガード④: inactive 上長の指定拒否 / active 上長は許可
- 招待用内部パスワードで作成が通ること
- 招待トークンの他テナント消費不可は **0a の password_reset_spec が同一コード経路を担保済み（委譲・再実装しない）**

**policy:** `Admin::UserPolicy` — hr_admin 許可 / manager・employee 全拒否。`resend_invitation?` の 3 条件（role・sign_in_count・active）。Scope は組織全員 + **inactive ユーザーを含む**（1 名混ぜて assert）+ 他テナント漏れなし

**request:**
- CRUD・非 hr_admin 403（**同一リクエストを hr_admin で行うと 200 になる対照 example とペア** — fail-closed による素通り防止）
- IDOR: 他テナント user id × {show, **update, deactivate, resend_invitation**} → 404
- 再送の負例: ログイン済み（`sign_in_count > 0`）403 / inactive 403 / **再送後に旧 raw トークンで `PUT /users/password` → パスワード不変** / **期限切れ（`travel 7.hours`）→ 拒否**
- create 失敗（バリデーション NG）時に `deliveries` が増えないこと（送付タイミングの固定）
- ガード発火は `user.reload` の状態不変 + エラーメッセージ文言まで assert（status のみの assert は素通りの芽）
- activate 正常系 + 「無効化された元・最後の hr_admin の再有効化」とガード①の相互作用
- DELETE ルート不在（物理削除なしの regression 防止・1 example）

**mailer:**
- **鏡像（偽テスト防止の要）:** `ActsAsTenant.with_tenant(org_B)` 下で org_A のユーザー宛て招待を生成し、URL が `org_A.subdomain` であり org_B を含まないこと（`current_tenant` からホストを組む誤実装を検出）
- 文面: 期限の案内・`passwords#new` への導線を含む / 内部パスワード片を含まない

**system:** 招待 → メールリンク → パスワード設定 → 当該テナントでログイン成功の E2E 一周。実行前提を明記: `include ActiveJob::TestHelper` + `perform_enqueued_jobs`・`ActionMailer::Base.deliveries` から URL 抽出・`switch_tenant` ヘルパ・正のアンカー assert（0a の password_reset_spec / tenant_isolation_spec の流儀を踏襲）

共通規約: メール件数は change matcher で assert（`deliveries.last` 直読みはランダム順実行で他 example のメールを掴む）。

## 5. 実装後の確認

- `tenant-isolation-reviewer`（models 変更あり）
- ROADMAP 0b-1 の行更新を PR に含める — チェックボックスに加え、**「mass-assignment 恒久除外の専用アクション」の文言を「Admin 名前空間限定の明示 permit（本設計 §0 で supersede）」へ修正**する
- Gemfile の devise を `~> 5.0` に固定（本スライスの diff に含める）

## 6. 実装中の追加決定（レビュー反映）

- ① `enum role` は `validate: true` を付与（不正値は ArgumentError でなく 422 Unprocessable Content として返す）
- ② 書き込み系アクション（create / update / deactivate / activate / resend_invitation）の redirect は一律 303 See Other（Turbo が PATCH/DELETE 後の 302 を元メソッドで再試行する問題の回避）
- ③ メール送信失敗（`deliver_now` 例外）は `rescue` + `Rails.error.report` で観測しつつ再送導線（招待再送ボタン）へ誘導する（500 にしない）
