# Phase 4-1 通知基盤 — 設計

- 日付: 2026-06-26
- 対象: ROADMAP Phase 4-1「通知基盤」
- SPEC 参照: §3.6 / §4.3 / §4.15 / §4.17 / §4.18 / §9 / §10 / §12.1 / §1.4
- 関連 backlog: ROADMAP「LeaveRequest.last_stale_notified_on の未実装（CCR との非対称）」(#113 行)

## 0. ゴールと非ゴール

**ゴール**: 通知の**生成と配信の基盤**を確立する。producer（打刻漏れ・過重労働等）は SPEC で Phase 4-2/4-3 送りだが、基盤を end-to-end で実証するため**「承認/却下」通知 1 本を前倒し接続**し、消費面（ベル UI・通知設定）を備えて §1.4 到達性 DoD を満たす。

**非ゴール（後続 Phase）**:
- 代理打刻通知・打刻漏れ/欠勤候補/インターバル/連続勤務/過重労働/36 協定/有給 5 日 等の **producer 群**（4-2・4-3）
- `OrganizationSetting` の閾値系・36 協定系カラム（消費する Phase が同梱・§4.15 注記）
- 通知の archive/retention 自動化（§11.3 NotificationDelivery 90 日 — v1 は「消すジョブを書かない」§11.4 YAGNI）

## 1. 確定した設計判断（ブレインストーミング結果）

| # | 判断 | 根拠 |
|---|------|------|
| A | **基盤 + 消費面 + producer 1 本**を 4-1 の範囲とする（純配管にしない） | §1.4 到達性 DoD（built-but-unreachable 禁止）/ 配管の API は caller で実証する必要 |
| B | `email_enabled` は **`users` 列に置く**（SSOT）。`UserNotificationPreference` は抑制系のみ | ROADMAP「User.email_enabled migration…0a 後送り」/ §4.3 / 組織フラグとの AND ゲート（fallback ではない）意味論 |
| C | **3 サブ PR** に分割（4-1a データ層 / 4-1b 配信コア / 4-1c UI+producer） | 1 スライス = 1 PR・各 PR をレビュー可能な粒度に |
| D | 毎時ディスパッチャ = **取りこぼし回収 sweep + 規範実装**、happy path は `set(wait_until:)` | §9.3 と §10 の二機構を二重管理せず和解させる |
| E | producer は **承認/却下のみ前倒し**（代理打刻・バッチ検知は 4-2 据え置き） | 最小・request 文脈・compliance 計算なしで pipe を実証できる最軽量 producer |

**SPEC 不整合の解消（B に伴う docs 修正・4-1a に同梱）**: SPEC §4.17 UserNotificationPreference の `email_enabled` 行を削除し「個人メール opt-in は `User.email_enabled`（§4.3）、本テーブルは抑制系のみ」と注記する。

## 2. アーキテクチャ

通知の生成を**単一入口 `Notifier` に集約**する（ROADMAP「通知を送るコードを書く場所を 1 箇所に集める」）。producer は `Notifier.call(...)` のみを知り、チャネル判定・抑制・二重 opt-in・配信は基盤が引き受ける。

```
producer（承認/却下 …将来は打刻漏れ等）
        │  Notifier.call(target_user:, title:, body:, priority:, source_type:, subject_user:)
        ▼
   ┌─────────── Notifier（生成入口・1箇所） ───────────┐
   │ 1. Notification 作成（ベル実体）                    │
   │ 2. in_app: 即時 Turbo Stream broadcast（抑制対象外） │
   │ 3. email 要否 = 優先度 × 二重 opt-in 判定           │
   │    要なら SuppressionWindow で scheduled_at 算出    │
   │    → NotificationDelivery(email, pending) 作成      │
   │    → NotificationEmailJob.set(wait_until:).perform │
   └─────────────────────────────────────────────────┘
        ▼ (happy path: wait_until)        ▼ (safety-net: 毎時)
   NotificationEmailJob              NotificationDispatchJob（ディスパッチャ）
   ・with_lock + pending? 冪等        └→ Organization.active.find_each
   ・mailer.deliver / sent 記録          → NotificationDispatchTenantJob(org_id)
   ・retry_on（retry_count 反映）           └→ with_tenant { 未送 pending を再 enqueue }
```

**二機構の和解（判断 D）**: SPEC は配信を 2 か所で言及する — §9.3「`set(wait_until: scheduled_at).perform_later`」と §10 毎時 `notification_dispatch`。二重管理を避けるため役割を分ける:
- `set(wait_until:)` = **happy path**（抑制終了後に正確に送る）
- 毎時 `NotificationDispatchJob` = **取りこぼし回収 sweep**（wait_until ジョブが失われた・delivery だけ作られた等の `pending` を再投入）**兼「ディスパッチャ→子ジョブ」の規範実装**（4-2/4-3 が踏襲する雛形・§3.6/§10）

両者は同じ `NotificationEmailJob` に収束し、job 側の `pending?` チェック（`with_lock`）で**二重送信を防ぐ**。状態機械は SolidQueue を正とし、`NotificationDelivery` に独立した状態機械を持たせない（§4.18 注記）。

**in_app は抑制しない**（§4.18 注記「即時ゆえ Delivery を介す必然薄い」）。`NotificationDelivery` は **email 専用の配信監査記録**に純化する（いつ・どの channel に送ったか）。

## 3. データモデル（4-1a）

複合 FK は repo idiom `[organization_id, X] → users[organization_id, id]`（テナント越境参照を DB で拒否）。全新規モデルに `acts_as_tenant(:organization)`。migration は `/create-migration` 規約に従う。

### 3.1 既存テーブルへの追加

| テーブル | 追加列 | 型・既定 | 備考 |
|----------|--------|----------|------|
| `users` | `email_enabled` | boolean, default false, **null false** | 個人メール opt-in SSOT（判断 B） |
| `organization_settings` | `quiet_hours_enabled` | boolean, default true, null false | §4.15 |
| 〃 | `quiet_hours_start` | integer, default 19 | §4.15（時・0..23） |
| 〃 | `quiet_hours_end` | integer, default 8 | §4.15（時・0..23） |
| 〃 | `holiday_block_enabled` | boolean, default true, null false | §4.15 |
| 〃 | `email_notification_enabled` | boolean, default false, null false | 組織メール（二重 opt-in 組織側）§4.15 |
| `leave_requests` | `last_stale_notified_on` | date, null 可 | CCR §4.11 との非対称解消（ROADMAP #113）。消費は 4-2 滞留アラートだが ROADMAP 指定でここで追加 |

> `organization_settings` は **4-1 が消費する 5 列のみ**追加する（閾値系・36 協定系・`leave_expiry_reminder_days` 等は消費 Phase が同梱・§4.15 注記の YAGNI）。各列に既定値 + 妥当性検証（時刻は 0..23）。`Organization#setting` の lazy 生成既定に新列を反映。

### 3.2 新規テーブル

**`user_notification_preferences`**（1 ユーザー 1 行・任意。無ければ `OrganizationSetting` にフォールバック）

| 列 | 型 | 備考 |
|----|-----|------|
| organization_id | bigint | acts_as_tenant |
| user_id | bigint | 複合 FK `[org_id, user_id]→users`・**テナント内 unique**（`validates_uniqueness_to_tenant` + DB unique index） |
| quiet_hours_enabled | boolean | 個人の抑制 ON/OFF |
| quiet_hours_start / _end | integer | 個人の抑制時間帯（0..23） |
| holiday_block_enabled | boolean | 個人の休日ブロック |

※ `email_enabled` は持たない（判断 B で User へ）。

**`notifications`**（ベル通知の実体・§4.18）

| 列 | 型 | 備考 |
|----|-----|------|
| organization_id | bigint | acts_as_tenant |
| target_user_id | bigint | 通知先。複合 FK `[org_id, target_user_id]→users` |
| subject_user_id | bigint, null 可 | 通知対象者（重複制御キー）。複合 FK・null 可 |
| title | string | |
| body | text | |
| priority | integer (enum) | action_required / informational / reference |
| source_type | integer (enum) | request_approved / request_rejected（4-1 が生む分のみ） |
| read_at | timestamptz, null 可 | 既読時刻 |

index: `[organization_id, target_user_id, read_at]`（未読絞り込み）。

**`notification_deliveries`**（email 配信監査 + 抑制キュー・§4.18）

| 列 | 型 | 備考 |
|----|-----|------|
| organization_id | bigint | acts_as_tenant |
| notification_id | bigint | 複合 FK `[org_id, notification_id]→notifications` |
| channel | integer (enum) | in_app / email（実質 email のみ生成・§4.18 注記） |
| scheduled_at | timestamptz | 抑制終了後の送信予定時刻 |
| status | integer (enum), default pending | pending / sent / error |
| retry_count | integer, default 0 | `>3` で error 確定（§9.5） |

index: `[organization_id, status, scheduled_at]`（sweep 用）。

### 3.3 enum 定義

```ruby
# Notification
enum :priority,    { action_required: 0, informational: 1, reference: 2 }, validate: true
enum :source_type, { request_approved: 0, request_rejected: 1 }, validate: true  # 後続 Phase が拡張（integer enum ゆえ model 編集のみ）
# NotificationDelivery
enum :channel, { in_app: 0, email: 1 }, validate: true
enum :status,  { pending: 0, sent: 1, error: 2 }, validate: true
```

### 3.4 モデル責務

- `User`: `email_enabled`（boolean）/ `has_one :notification_preference` / `has_many :notifications, foreign_key: :target_user_id`
- `UserNotificationPreference`: `acts_as_tenant` / `belongs_to :user` / `validates_uniqueness_to_tenant :user_id` / 時刻 0..23 検証 / 自己テナント整合（複合 FK）
- `Notification`: `acts_as_tenant` / `belongs_to :target_user, class_name: "User"` / `belongs_to :subject_user, class_name: "User", optional: true` / enums / `scope :unread, -> { where(read_at: nil) }`
- `NotificationDelivery`: `acts_as_tenant` / `belongs_to :notification` / enums

## 4. 配信ロジック（4-1b）

### 4.1 優先度 × 二重 opt-in（§9.4）

二重 opt-in = 組織 `email_notification_enabled` ∧ 個人 `users.email_enabled` の両 true。

| 優先度 | ベル(in_app) | メール |
|--------|:---:|:---:|
| action_required | ✓ 即時 | **常時**（opt-in 無関係） |
| informational | ✓ 即時 | 二重 opt-in 時のみ |
| reference | ✓ 即時 | ― |

### 4.2 抑制（§9.3・email のみ）

`Notifications::SuppressionWindow`(**純 PORO・値注入**・§9 反映①②): preference の解決（`UserNotificationPreference` →（無ければ）`OrganizationSetting`）と休日判定（`CompanyCalendar`）という **AR 読み取りは `Notifier`(Service) 側で行い**、SuppressionWindow には**解決済みの値だけを注入**する — `SuppressionWindow.new(now_local:, quiet_enabled:, quiet_start:, quiet_end:, holiday_block:, holiday?:)`。これにより DB なしで境界算術を網羅テストできる（§2.2-1 PORO 契約を回復）。
- **`now_local` は組織ローカル時刻**（`Time.current` は UTC ゆえ `ActsAsTenant.current_tenant.time_zone` で `in_time_zone` してから渡す・organization.rb の `#today`/`#time_zone` idiom と同経路）。
- `quiet_enabled` ∧ `now_local` が `quiet_start`〜`quiet_end` 帯（**start 包含・end 排他**・日跨ぎ start=19/end=8 を扱う）
- または `holiday_block` ∧ 当日が休日

のいずれかなら `suppressed? = true`・`next_allowed_at`（抑制終了時刻・組織ローカル）を返す。非抑制なら即時（`scheduled_at = Time.current`）。`action_required` も抑制対象（§9.3 は優先度で除外しない）。

### 4.3 コンポーネント

| 種別 | 名前 | 責務 |
|------|------|------|
| service | `Notifier`（app/services/notifier.rb） | 生成入口。Notification 作成 → in_app broadcast → email 要否判定 → SuppressionWindow → NotificationDelivery 作成 + `NotificationEmailJob.set(wait_until: scheduled_at).perform_later(organization_id:, delivery_id:)`（org_id は `ActsAsTenant.current_tenant.id`） |
| PORO | `Notifications::SuppressionWindow` | `suppressed?` / `next_allowed_at`（quiet hours 境界・休日判定・日跨ぎ） |
| job | `NotificationEmailJob` | `perform(organization_id:, delivery_id:)`。冒頭 `with_tenant(org)` で**テナント再確立**（後送ゆえ実行時は文脈消失）→ `with_lock` で `pending?` を確認してから `NotificationMailer.notify(...).deliver_now`・`sent` 記録。`retry_on`（transient）で `retry_count`++・`>3` で `status: error`。**error 多発時は当面ログ + メトリクスのみ**（hr_admin 集約通知は §9.5 だが、通知失敗が通知を生む自己再帰を避け producer の整う 4-2 以降へ送る） |
| job | `NotificationDispatchJob`（ディスパッチャ） | `Organization.active.find_each { NotificationDispatchTenantJob.perform_later(org.id) }`（Organization はスコープ外で列挙・§3.6） |
| job | `NotificationDispatchTenantJob`（子） | `with_tenant(org) { NotificationDelivery.email.pending.where("scheduled_at <= ?", now).find_each { NotificationEmailJob.perform_later(...) } }` |
| mailer | `NotificationMailer#notify(notification)` | 汎用通知メール。リンクに**サブドメインを含める**（§3.2・テナント再確定） |

`config/recurring.yml` に `notification_dispatch`（`class: NotificationDispatchJob` / `every hour`）を追加（§10）。

### 4.4 ジョブのテナント安全（§3.6・最重要）

- ディスパッチャ `NotificationDispatchJob` は `current_tenant = nil` 前提で `Organization` をスコープ外列挙し、**子ジョブに org_id だけ渡す**。
- 子 `NotificationDispatchTenantJob` / `NotificationEmailJob` は perform 冒頭で `ActsAsTenant.with_tenant(org)` ラップ必須（`check-job-tenant-wrap` フックの対象）。
- `require_tenant = true` でラップ漏れを例外検出。これが ROADMAP「ディスパッチャ→子ジョブのテナント反復パターン確立」の規範実装となり、4-2/4-3 のバッチが踏襲する。

## 5. 消費面 UI + producer（4-1c）

### 5.1 ベル（Turbo Streams）

- `NotificationBellComponent`（ViewComponent・`GlobalNavComponent` 内に配置）— 未読バッジ（件数）+ ドロップダウン（直近 N 件）。
- ビューで `turbo_stream_from current_user`（per-user stream）を購読。`Notifier` の in_app broadcast が新着を prepend + 件数更新。
- SolidCable は導入済み（gem + `cable.yml`・dev は async adapter で in-process 動作）— **新規セットアップ不要・使うのみ**。本 slice が repo 初の Turbo Streams 利用。

### 5.2 通知一覧 / 既読

- `NotificationsController`: `index`（自分宛の Notification 一覧・policy_scope）/ `update`（既読 = `read_at` セット・PATCH）。Pundit `authorize`。

### 5.3 通知設定（§12.1 通知設定エリア）

- `NotificationPreferencesController`: 単数リソース `edit` / `update`（`current_user` の `UserNotificationPreference` を編集・無ければ既定で生成）。
- フォームは **抑制系（UserNotificationPreference: 抑制 ON/OFF・時間帯・休日ブロック）+ メール opt-in（`User.email_enabled`）を 1 画面**で扱う（2 モデル更新を 1 アクションで）。

### 5.4 producer 接続（pipe 実証・判断 E）

- 接ぎ目: **承認 tx が確定した後**に `Notifier.call`（§9 反映③・最重要）。`Approvals::Approve#call` は `with_lock` 内で `apply_*_effects!` を呼び、LeaveRequest 承認は `OverBalanceError` で **rollback し得る**（approve.rb:20-27,52 + RAILS_GOTCHAS 2-2b）。`Notifier` を tx/`with_lock` 内に置くと in_app broadcast が即時に飛び、rollback 時に**幻の承認ベル**が残る。**発火点は `Approvals::Approve.call` / `Approvals::Reject.call` の戻り後（controller 層で `approvable.approved? / rejected?` を見て呼ぶ）か host モデルの `after_commit` に固定**し、`apply_*_effects!`/`with_lock` 内には**置かない**。
  - target_user = requester、priority = **informational**（§9.1「申請の承認/却下｜情報提供｜ベル｜即時」）、source_type = `request_approved` / `request_rejected`、subject_user = requester。
  - informational ゆえ既定はベルのみ（二重 opt-in 時のみメール）= §9.1 の「ベル」と一致。
  - **多段承認**: 中間段階では通知せず、**終端（全段承認 = `finalize!` / 却下）でのみ**発火（2 段ルートの 1 人目承認では requester 通知ゼロ）。
- 既存の承認/却下サービス（LeaveRequest / ClockChangeRequest / HolidayWorkRequest を `Approvable` で共通化）の seam を**実コードで特定**し、副作用の atomicity（承認確定 tx との境界）を確認。**approval-engine-reviewer 必須**。

### 5.5 §1.4 動線マップ行追加

| アクター | 目的 | 起点 route | nav 入口 | 結果 | 状態 |
|----------|------|-----------|----------|------|------|
| 社員 | 申請の承認/却下通知を受け取り確認したい | `/notifications`（+ 🔔 ベル） | GlobalNav 🔔 | 通知一覧・既読 | ✅ |
| 社員 | 通知設定（抑制・メール opt-in）を変更したい | `/notification_preferences/edit` | GlobalNav | 設定保存 | ✅ |

## 6. テスト戦略

| 層 | 観点 |
|----|------|
| model | validation / enum / scope / テナント scoping / 複合 FK 越境拒否 |
| service | `Notifier`: 優先度 × 二重 opt-in × 抑制のマトリクス（in_app 常時 / email 条件 / suppressed→scheduled_at）。`SuppressionWindow`: quiet hours 境界・日跨ぎ・休日 |
| job | `NotificationDispatchJob`: **テナント越境ゼロ**（他社 delivery を拾わない）。`NotificationEmailJob`: 冪等（sent 済を二重送信しない）・retry_count・error 確定 |
| mailer | `NotificationMailer#notify`: 件名/本文/サブドメイン入りリンク |
| component | `NotificationBellComponent`: 未読件数・ドロップダウン |
| request | notifications（index/既読）・notification_preferences（edit/update・2 モデル更新） |
| 統合 | **承認 → requester に Notification が生成されベルに出る**（pipe を端から端まで） |

## 7. レビュー・DoD

- **設計段階**: 本 design に `multi-perspective-review`（多視点並列 critique）を当ててから writing-plans（大物・CLAUDE.md 慣行）。
- **マージ前**:
  - `tenant-isolation-reviewer`（models / jobs / migrations に触れる全 PR）
  - `approval-engine-reviewer`（4-1c の producer 接続）
  - `/preflight`・`bundle exec rspec`・`bundle exec rubocop --force-exclusion`・`bin/brakeman --no-pager`
  - **§1.4 到達性 DoD**（4-1c）: 追加行の起点 route が実在し nav から到達可能・状態 ✅ が実態と一致
  - 各 PR で ROADMAP 該当行更新（チェック + PR 番号）

## 8. サブ PR 分割

| PR | 範囲 | reachable? | レビュアー |
|----|------|:---:|------|
| **4-1a** データ層 | §3 の migrations + models + SPEC §4.17 不整合修正 | —（データ層・§1.4 行なし） | tenant-isolation |
| **4-1b** 配信コア | §4 の Notifier / SuppressionWindow / jobs / mailer / recurring.yml + 単体テスト | —（内部 API・caller は 4-1c） | tenant-isolation |
| **4-1c** UI+producer | §5 のベル / 一覧 / 設定 / 承認接続 / §1.4 行 + 統合テスト | ✅ | tenant-isolation + approval-engine |

> 4-1a データ層は §1.4 行を持たない（到達面ゼロ）。これは §1.4 が「ユーザー向け動線の到達性」を測る指標であり、データ層 slice には動線が無いことを正直に反映したもの（行を持たないことが整合）。phase 4-1 全体としては 4-1c で reachable に着地する。

## 9. 多視点レビュー反映（2026-06-26・binding 追補）

5 視点（原則整合 / 実用主義 / YAGNI / セキュリティ・テナント / テスト網羅）の並列 critique を反映。**本節は §2〜§6 を上書きする拘束力を持つ**（writing-plans は本節を必須要件として扱う）。骨格（3 サブ PR・二機構の和解・enum+SolidQueue）は妥当と確認され、以下は「明示の追補」。

### ① タイムゾーン（実用 High・視点一致）
quiet hours 境界は**組織ローカル時刻**で判定する。`Time.current` は UTC ゆえ `ActsAsTenant.current_tenant.time_zone` で `in_time_zone` してから hour 比較（organization.rb の `#today`/`#time_zone` と同経路）。§4.2 を改訂済。テストは JST 固定 `travel_to` で境界を pin。

### ② SuppressionWindow を純 PORO 化（原則整合 Med）
AR 読み取り（preference 解決・休日判定）は `Notifier`(Service) に置き、SuppressionWindow には**解決済み値を注入**（§4.2 改訂済）。§2.2-1 の「DB なし網羅テスト」契約を回復。

### ③ producer 接ぎ目の atomicity（原則整合/実用/テスト 一致・最重要）
`Notifier.call` は**承認 tx 確定後**に発火（§5.4 改訂済）。`apply_*_effects!`/`with_lock` 内に置かない。`Notifier` 自身の DB 書き込み（Notification + NotificationDelivery）は**明示 tx で囲み、in_app broadcast と job enqueue は after_commit 後**に発火（`enqueue_after_transaction_commit` 設定 + 手動 broadcast の発火点固定）。これで sweep が「未コミット行」を拾う事故も防ぐ。

### ④ model レベル同一組織検証（セキュリティ High）
複合 FK（DB 最終防衛）に加え、**AR 検証 `*_must_belong_to_same_organization` を二重防御として付与**（repo 全モデルの idiom・`approval_assignment.rb` 踏襲）:
- `Notification#target_user` / `#subject_user`（optional は早期 return）
- `NotificationDelivery#notification`
- `UserNotificationPreference#user`

### ⑤ NotificationPolicy / Scope / 既読 IDOR（セキュリティ High・テスト High）
acts_as_tenant は**テナント越境のみ**遮断（同一テナント他人は素通り）。Pundit で塞ぐ:
- `NotificationPolicy::Scope#resolve = scope.where(target_user_id: user.id)`
- `NotificationPolicy#update? = record.target_user_id == user.id`（既読化）
- controller は `policy_scope(Notification).find(...)` で取得（bare `Notification.find` 禁止・二重防御）
- `NotificationPreferencePolicy` を立て edit/update も Pundit 一元化（原則 §2.2-4・"current_user だから安全" の暗黙認可層を作らない）

### ⑥ 通知設定フォームの境界（セキュリティ Med・テスト Med）
- User 更新は **current_user 限定・permit は `:email_enabled` のみ**。Preference の `user_id`/`organization_id` は**サーバ権威**（current_user 由来・params で受けない）。
- 2 モデル更新（User + UserNotificationPreference）は**単一 tx**（`update!` 2 本）。片方失敗で部分更新を残さない。`find_or_initialize_by` で lazy 生成。

### ⑦ NotificationMailer（実用 Med・セキュリティ Med）
- `default from: ENV.fetch("MAILER_SENDER", ...)`（`ApplicationMailer` の placeholder `from@example.com` を継承しない）。
- リンク host は **job 文脈に request が無い**ため `notification.organization.subdomain` から構築（`request.subdomain` 不可）。§3.2 のテナント再確定を満たす。

### ⑧ retry の出所と配信ロックの注記（実用 Low/Med）
- error 確定（`>3`）の判定は **ActiveJob 組込 `executions`** を正とし、`retry_count` 列はその**監査ミラー**（job が反映）。SolidQueue と二重管理しない（§2 と整合）。
- `deliver_now` を `with_lock` 内で実行＝SMTP I/O 間の行ロック保持は**意図的**（4-1 は低ボリューム前提）。volume 増時は claim-then-send（`sending` へ flip→commit→ロック外 deliver）に分解する旨を注記。
- status 遷移の書き込みは**単一メソッド（with_lock 内）に集約**（enum が散在状態機械にならないよう・原則 §13 精神）。

### ⑨ Turbo Stream 署名不変条件（原則整合 Med・セキュリティ Med）
`turbo_stream_from current_user`（GlobalID 署名 stream）を使い、**未署名の独自 ActionCable channel を新設しない**。broadcast 先も target_user の GlobalID stream に限定。ベル描画は `policy_scope(Notification)` 経由。**repo 初の Turbo Streams 利用ゆえ DoD に固定**。dev は async adapter（in-process）= 4-1 producer は request 文脈ゆえベルは出るが、**将来 worker 文脈 broadcast は dev async では不可視**（本番 solid_cable は別 DB 経由で可）の注記を残す。

### ⑩ Organization.active（セキュリティ Low）
ディスパッチャの `Organization.active.find_each` が依存する `scope :active, -> { where(active: true) }` を `Organization` に追加（未定義・`resolve_tenant` は生 `where(active: true)`）。子→email の enqueue は `(organization_id: org.id, delivery_id:)` を明示。

### ⑪ sweep の根拠言い換え（実用 Low・YAGNI Med）
毎時 sweep の正当化を「scheduled job が失われた」から **「enqueue 取りこぼし回収（Delivery 作成済・enqueue 前クラッシュ）＋ 4-2/4-3 が踏襲する dispatcher 雛形の規範実装」**に言い換え（SolidQueue scheduled job は DB 永続で耐久的・二重機構自体は §10 準拠で正当）。

### ⑫ ROADMAP reconcile（YAGNI Med・drift 防止）
承認/却下 producer を 4-1c へ前倒しするため、**ROADMAP 4-2 行の「承認/却下接続」を「4-1c で充足済」へ更新**し、4-2 での二重実装を防ぐ（4-1c の PR に同梱）。

### ⑬ テスト負例の明文化（テスト High×4 ＋ Med 群）
§6 の各層に**負例を明示列挙**（positive 素通り防止）:
- **既読 IDOR**: 他人/他テナントの notification を PATCH→403/404・`read_at` 不変。index の policy_scope が自分宛のみ
- **quiet hours 境界**: 18:59 非抑制 / 19:00 抑制（start 包含）/ 07:59 抑制 / 08:00 非抑制（end 排他）/ 各 `next_allowed_at` 実値。非日跨ぎ窓（start=8/end=19）と start==end 縮退も
- **二重 opt-in AND ゲート**: informational で 組織on×個人off→メール無 / 組織off×個人on→メール無 / 両on→有 の **3 セル個別**。reference は両 opt-in でも Delivery 0 件。action_required は全 off でも email Delivery 生成
- **却下経路**: reject 経由でも requester に Notification（source_type: request_rejected）+ broadcast（承認と対の 2 ケース）
- **休日判定**: どの `day_type`（saturday/sunday/holiday/legal_holiday/company_holiday）が「休日」か・未登録日 fallback（Resolver :sunday）の扱いを表で固定
- **冪等二重発火**: 同一 delivery に perform 2 回（wait_until + sweep 相当）→ `ActionMailer.deliveries` 1 通
- **dispatch 絞り込み**: scheduled_at 未来 / sent・error / 非 active org を拾わない
- **承認 tx rollback**: 後続副作用失敗で rollback→Notification 0 件・broadcast 0 件（幻通知なし）
- **多段中間**: 1 人目承認で通知ゼロ・終端で 1 件
- **broadcast/enqueue assertion**: `have_broadcasted_to(current_user)`・`have_enqueued_job(NotificationEmailJob).with(wait_until:, organization_id:, delivery_id:)`（repo 初の broadcast テストゆえ基盤ごと固定）
- **OrganizationSetting 新 5 列**の lazy 既定（quiet 19/8・各 enabled）

### 是認（変更不要と確認された設計判断）
`source_type` 2 値限定 / `channel` の `in_app` 予約値（SPEC §4.18 準拠・再番号は逆に drift）/ `NotificationDispatchTenantJob` 別クラス（親=スコープ外列挙と子=with_tenant は同居不可）/ `last_stale_notified_on` の 1 フェーズ早い追加（ROADMAP #113 明示・nullable で安価）/ org_settings 5 列限定 / §9.5 error→hr_admin 見送り / archive 見送り（§11.4）。
