# Phase 4-1c 通知 UI + producer 接続 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 4-1 通知基盤の最終スライス。消費面（ベル UI・通知一覧/既読・通知設定）を備え、承認/却下 producer 1 本を接続して通知パイプを端から端まで実証し、§1.4 到達性 DoD を満たす。

**Architecture:** 4-1b で作った単一入口 `Notifier`（生成 → tx 後 in_app broadcast + email enqueue）の **caller を接続**する。producer は `approval_assignments_controller#approve/#reject` の **承認 tx 確定後（controller 層・`with_lock` の外）** に `Notifier.call` を呼ぶ。消費面は per-user 署名 Turbo Stream（`turbo_stream_from current_user`）を購読する `NotificationBellComponent` をグローバルナビに常設し、Notifier の broadcast が新着 prepend + 未読件数 replace を流す。一覧/既読は `NotificationsController`、通知設定は `NotificationPreferencesController`（User.email_enabled + UserNotificationPreference を 1 画面・単一 tx）。

**Tech Stack:** Rails 8.1 / Hotwire(Turbo Streams 初導入) / ViewComponent / Pundit / Devise / acts_as_tenant / SolidCable(導入済・dev は async adapter)

**設計 SSOT:** `docs/superpowers/specs/2026-06-26-phase4-1-notification-infrastructure-design.md` の **§5（消費面 UI + producer）と §9（多視点レビュー反映・binding 追補）**。本計画の各タスク要件は暗黙に §9 全体を含む。

## Global Constraints（§9 binding 追補から逐語・全タスクに適用）

- **§5.4/§9③ producer 接ぎ目の atomicity（最重要）**: `Notifier.call` は**承認 tx 確定後**に発火。`Approvals::Approve#call` / `Reject#call` は内部で `with_lock` し、`apply_*_effects!` が `OverBalanceError` で **rollback し得る**。Notifier を tx/`with_lock` 内に置くと in_app broadcast が即時に飛び rollback 時に**幻ベル**が残る。発火点は **service 戻り後の controller 層**に固定（`with_lock` の内側に置かない）。Notifier はテナント文脈下からのみ呼ぶ（文脈外は `NoTenantSet` で fail-closed）。
- **発火ガード（対称二択）**: approve は `if approvable.approved?`（中間段階 `applying?` は不発火・取下げ承認 `:withdrawn` も `approved?` 偽ゆえ不発火）。reject は `if approvable.rejected?`（取下げ却下は `:approved` へ復帰し `rejected?` 偽ゆえ不発火）。**多段承認は終端でのみ通知**（§5.4）。
- **通知属性**: target_user = `approvable.requester`、priority = **`informational`**（承認・却下とも・§9.1）、source_type = `request_approved` / `request_rejected`、subject_user = `approvable.requester`。informational ゆえ既定はベルのみ（二重 opt-in 時のみメール）。
- **§9⑤ IDOR/Pundit**: acts_as_tenant は越境のみ遮断（同一テナント他人は素通り）。Pundit で塞ぐ — `NotificationPolicy::Scope#resolve = scope.where(target_user_id: user.id)` / `NotificationPolicy#update? = record.target_user_id == user.id`（既読化）/ controller は `policy_scope(Notification).find(...)` で取得（bare `Notification.find` 禁止・二層）。ベル描画は `current_user.notifications`（= 上記 Scope と同一述語 `target_user_id = user.id`・本人ルートゆえ越境不能）。`NotificationPreferencePolicy` を立て edit/update も Pundit 一元化（headless symbol authorize）。
- **§9⑥ 通知設定フォーム境界**: User 更新は **current_user 限定・permit は `:email_enabled` のみ**。UNP の `user_id`/`organization_id` は**サーバ権威**（current_user 由来・params で受けない）。User + UNP の 2 モデル更新は**単一 tx**（`update!` 2 本）。`find_or_initialize_by`/has_one builder で lazy 生成。
- **§9⑨ Turbo Stream 署名不変条件**: `turbo_stream_from current_user`（**単一引数**・GlobalID 署名 stream）を購読。broadcast 先も target_user の GlobalID stream（`broadcast_*_to(@target_user)`＝生 GID param）。**両者は同一 raw GID param stream で一致**（署名は購読ハンドシェイクのみ・broadcast キーに非関与・RAILS_GOTCHAS「have_broadcasted_to」項）。**未署名の独自 ActionCable channel を新設しない**。repo 初の Turbo Streams 利用ゆえ DoD に固定。
- **§9⑫ ROADMAP reconcile**: 承認/却下 producer を 4-1c へ前倒すため ROADMAP 4-2 の「承認/却下接続」を「4-1c 充足済」へ更新（本 PR 同梱）。
- **書き込み系 redirect は `status: :see_other`**（Turbo の PATCH メソッド保持 redirect 罠・RAILS_GOTCHAS）。
- **検証**: app/ 変更ゆえ各タスク完了条件に `bundle exec rspec <該当>` / `bundle exec rubocop --force-exclusion <files>`、ブランチ仕上げに `bin/brakeman --no-pager`。マージ前レビュアー: **tenant-isolation-reviewer**（全 PR）+ **approval-engine-reviewer**（producer・Task 6）。

## File Structure

| ファイル | 責務 | タスク |
|----------|------|--------|
| `db/migrate/*_add_notification_query_indexes.rb` | 部分 unread index・deliveries[org,notification_id]・subject_user_id（クエリ形状が定まった 4-1c で対称化・ROADMAP backlog） | 1 |
| `spec/models/notification_spec.rb` / `notification_delivery_spec.rb`（既存に追記） | 必須 belongs_to の DB 層 FK 負例 + subject_user の判別的 model validator 負例（4-1a RAILS_GOTCHAS 還流） | 2 |
| `app/policies/notification_policy.rb` | index?/update?/Scope（§9⑤） | 3 |
| `app/controllers/notifications_controller.rb` | index（一覧・policy_scope）/ update（既読） | 3 |
| `app/views/notifications/index.html.erb` | 通知一覧 + 既読ボタン | 3 |
| `app/views/notifications/_notification.html.erb`（既存を再整形） | broadcast/一覧 共用の 1 項目（既読スタイル） | 3 |
| `config/routes.rb`（追記） | `resources :notifications, only: %i[index update]` | 3 |
| `app/policies/notification_preference_policy.rb` | edit?/update?（headless・§9⑤） | 4 |
| `app/controllers/notification_preferences_controller.rb` | edit / update（User+UNP 単一 tx・§9⑥） | 4 |
| `app/views/notification_preferences/edit.html.erb` | 抑制 + メール opt-in フォーム | 4 |
| `config/routes.rb`（追記） | `resource :notification_preferences, only: %i[edit update]` | 4 |
| `app/components/notification_bell_component.rb` + `.html.erb` | 未読バッジ + ドロップダウン（GlobalNav 内） | 5 |
| `app/views/notifications/_bell_count.html.erb` | バッジ件数（component と broadcast 共用・DRY） | 5 |
| `app/components/global_nav_component.html.erb`（追記） | ベルを右側 flex に挿入 | 5 |
| `app/views/layouts/application.html.erb`（追記） | `turbo_stream_from current_user`（§9⑨） | 5 |
| `app/services/notifier.rb`（broadcast 拡張） | prepend に加え未読件数 replace を broadcast | 5 |
| `app/controllers/approval_assignments_controller.rb`（追記） | approve/reject 後に `Notifier.call`（producer・§5.4） | 6 |
| `docs/SPEC.md` §1.4 / `docs/ROADMAP.md` | 動線 2 行追加 + 4-2 reconcile + 4-1 行チェック | 7 |

---

## Task 1: 通知クエリ用 perf index migration

**Files:**
- Create: `db/migrate/<ts>_add_notification_query_indexes.rb`
- Modify: `db/schema.rb`（migration が自動更新）

**Interfaces:**
- Consumes: 既存テーブル `notifications` / `notification_deliveries`（4-1a）。
- Produces: index のみ（モデル API 変化なし）。Task 3 のベル未読件数クエリ（`Notification.unread.where(target_user:)`）と Task 6 の delivery→notification 結合の裏付け。

> 参照: `/create-migration` 規約（複合 index 命名・partial index）。ROADMAP backlog「perf index（subject_user_id / deliveries[org,notification_id] / 部分 index WHERE read_at IS NULL）はクエリ形状が定まる 4-1c で対称化」。各 index の根拠 — **部分 unread**: ベル/一覧の未読件数ホットパス（`WHERE read_at IS NULL`）。**deliveries[org, notification_id]**: 複合 FK 結合・notification からの配信引き（PG は FK に index を自動生成しない）。**subject_user_id**: 重複制御キーの将来 dedup（消費は後続だが ROADMAP 指定の対称化・nullable で安価）。

- [ ] **Step 1: migration を作成**

```ruby
# frozen_string_literal: true

class AddNotificationQueryIndexes < ActiveRecord::Migration[8.1]
  def change
    # 未読件数のホットパス（ベルバッジ・一覧フィルタ）。部分 index で小さく保つ。
    add_index :notifications, %i[organization_id target_user_id],
              where: "read_at IS NULL",
              name: "index_notifications_on_org_target_unread"

    # 重複制御キー（subject_user）の将来 dedup。nullable・安価（ROADMAP 対称化）。
    add_index :notifications, %i[organization_id subject_user_id],
              name: "index_notifications_on_org_subject_user"

    # 複合 FK [organization_id, notification_id]→notifications の結合裏付け（PG は FK 自動 index 無し）。
    add_index :notification_deliveries, %i[organization_id notification_id],
              name: "index_notification_deliveries_on_org_notification"
  end
end
```

- [ ] **Step 2: migrate して schema.rb を更新**

Run: `bin/rails db:migrate`
Expected: 3 index が `db/schema.rb` に追記される（migration が schema を再 dump）。

- [ ] **Step 3: schema ラウンドトリップを検証**

Run: `RAILS_ENV=test bin/rails db:schema:load && bin/rails db:migrate:status`
Expected: load がエラーなく通り、本 migration が `up`。`git diff db/schema.rb` に 3 index 行のみ（手編集なし・`block-schema-edit` フック遵守）。

- [ ] **Step 4: 既存スイートで回帰なしを確認**

Run: `bundle exec rspec spec/models/notification_spec.rb spec/models/notification_delivery_spec.rb`
Expected: 全 PASS（index 追加は挙動不変）。

- [ ] **Step 5: Commit**

```bash
git add db/migrate db/schema.rb
git commit -m "feat: 通知クエリ用 index（部分 unread / subject_user / deliveries[org,notification_id]）"
```

---

## Task 2: 必須 belongs_to の DB 層 FK 負例 + subject_user 判別的 model 負例（4-1a 還流）

**Files:**
- Modify: `spec/models/notification_spec.rb`
- Modify: `spec/models/notification_delivery_spec.rb`
- Test: 同上（spec 自体の強化）

**Interfaces:**
- Consumes: 既存 `Notification` / `NotificationDelivery` モデル（4-1a）と複合 FK。
- Produces: なし（テスト網羅の対称化のみ）。

> 根拠（RAILS_GOTCHAS「必須 belongs_to の同一組織 validator は presence と二重発火し model テストで単体検証できない」）: 必須参照（`target_user` / `notification`）は acts_as_tenant が他 org id を `nil` ロードするため model `be_invalid` が presence と二重発火で判別不能 → **検証可能な防衛線は複合 FK**（`save!(validate: false)` で `ActiveRecord::InvalidForeignKey`）。一方 **optional 参照（`subject_user`）は presence を通る**ため custom validator が唯一の砦＝model `be_invalid` が判別的。gen-spec 規約 #4a/#4b。

- [ ] **Step 1: Notification の DB 層 FK 負例 + subject_user 判別的負例を追記**

`spec/models/notification_spec.rb` の `describe "テナント分離 / 複合 FK"`（無ければ新設）に追加:

```ruby
  describe "同一組織強制（§3.6・二層防御）" do
    let(:org)   { create(:organization) }
    let(:other) { create(:organization) }
    let(:other_user) { ActsAsTenant.with_tenant(other) { create(:user) } }

    it "必須 target_user の他組織 id は DB 複合 FK で拒否（model 層を貫通）" do
      ActsAsTenant.with_tenant(org) do
        n = build(:notification, target_user: nil)
        n.target_user_id = other_user.id # 他組織 id を直挿（acts_as_tenant の nil ロードを迂回）
        expect { n.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
      end
    end

    it "optional subject_user の他組織 id は model validator が判別的に弾く" do
      ActsAsTenant.with_tenant(org) do
        n = build(:notification, subject_user_id: other_user.id)
        expect(n).to be_invalid
        expect(n.errors[:subject_user]).to be_present
      end
    end
  end
```

- [ ] **Step 2: NotificationDelivery の DB 層 FK 負例を追記**

`spec/models/notification_delivery_spec.rb` に追加:

```ruby
  describe "同一組織強制（§3.6・二層防御）" do
    let(:org)   { create(:organization) }
    let(:other) { create(:organization) }
    let(:other_notification) do
      ActsAsTenant.with_tenant(other) { create(:notification) }
    end

    it "必須 notification の他組織 id は DB 複合 FK で拒否" do
      ActsAsTenant.with_tenant(org) do
        d = build(:notification_delivery, notification: nil)
        d.notification_id = other_notification.id
        expect { d.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
      end
    end
  end
```

- [ ] **Step 3: テストが意図通り（FK/validator を消すと落ちる方向で）通ることを確認**

Run: `bundle exec rspec spec/models/notification_spec.rb spec/models/notification_delivery_spec.rb`
Expected: 全 PASS。`InvalidForeignKey` 負例は複合 FK が、subject_user 負例は model validator が拒否することを判別的に示す。

- [ ] **Step 4: Commit**

```bash
git add spec/models/notification_spec.rb spec/models/notification_delivery_spec.rb
git commit -m "test: 通知モデルの DB 層 FK 負例 + subject_user 判別的負例（4-1a 還流）"
```

---

## Task 3: NotificationsController（一覧 + 既読）+ Policy + routes + views

**Files:**
- Create: `app/policies/notification_policy.rb`
- Create: `app/controllers/notifications_controller.rb`
- Create: `app/views/notifications/index.html.erb`
- Modify: `app/views/notifications/_notification.html.erb`（4-1b の最小要素を再整形）
- Modify: `config/routes.rb`
- Test: `spec/policies/notification_policy_spec.rb` / `spec/requests/notifications_spec.rb`

**Interfaces:**
- Consumes: `Notification`（scope `:unread`・`read_at`）/ `current_user.notifications`。
- Produces: route helper `notifications_path`（index）/ `notification_path(id)`（PATCH 既読）。`_notification` partial（Task 5 ベル・Notifier broadcast が共用）。

- [ ] **Step 1: NotificationPolicy の失敗するテストを書く**

`spec/policies/notification_policy_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationPolicy do
  let(:org)   { create(:organization) }
  let(:owner) { ActsAsTenant.with_tenant(org) { create(:user) } }
  let(:other) { ActsAsTenant.with_tenant(org) { create(:user) } }
  let(:notification) { ActsAsTenant.with_tenant(org) { create(:notification, target_user: owner) } }

  it "update?（既読化）は target_user 本人のみ true" do
    expect(described_class.new(owner, notification).update?).to be(true)
    expect(described_class.new(other, notification).update?).to be(false)
  end

  describe "Scope" do
    it "自分宛のみ解決する（同一テナント他人は除外）" do
      ActsAsTenant.with_tenant(org) do
        mine = create(:notification, target_user: owner)
        theirs = create(:notification, target_user: other)
        resolved = NotificationPolicy::Scope.new(owner, Notification).resolve
        expect(resolved).to include(mine)
        expect(resolved).not_to include(theirs)
      end
    end
  end
end
```

Run: `bundle exec rspec spec/policies/notification_policy_spec.rb`
Expected: FAIL（`NotificationPolicy` 未定義）。

- [ ] **Step 2: NotificationPolicy を実装**

```ruby
# frozen_string_literal: true

# 通知の認可（設計 §9⑤）。acts_as_tenant は越境のみ遮断ゆえ同一テナント他人を Pundit で塞ぐ。
class NotificationPolicy < ApplicationPolicy
  def index? = user.present?
  def update? = record.target_user_id == user.id # 既読化は本人のみ（IDOR 防止）

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(target_user_id: user.id)
  end
end
```

Run: `bundle exec rspec spec/policies/notification_policy_spec.rb`
Expected: PASS。

- [ ] **Step 3: NotificationsController の request spec（IDOR 負例込み）を書く**

`spec/requests/notifications_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Notifications", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:owner) { ActsAsTenant.with_tenant(org) { create(:user, name: "本人") } }
  let!(:other) { ActsAsTenant.with_tenant(org) { create(:user, name: "他人") } }

  describe "GET index" do
    it "自分宛のみ一覧する（他人宛は出さない）" do
      ActsAsTenant.with_tenant(org) do
        create(:notification, target_user: owner, title: "自分の通知")
        create(:notification, target_user: other, title: "他人の通知")
      end
      sign_in owner
      get notifications_url(host: tenant_host(org))
      expect(response.body).to include("自分の通知")
      expect(response.body).not_to include("他人の通知")
    end
  end

  describe "PATCH update（既読化）" do
    it "自分宛の通知を既読にする" do
      n = ActsAsTenant.with_tenant(org) { create(:notification, target_user: owner) }
      sign_in owner
      patch notification_url(n, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(ActsAsTenant.with_tenant(org) { n.reload.read_at }).to be_present
    end

    it "他人宛の既読化は 404・read_at 不変（IDOR）" do
      n = ActsAsTenant.with_tenant(org) { create(:notification, target_user: other) }
      sign_in owner
      patch notification_url(n, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(ActsAsTenant.with_tenant(org) { n.reload.read_at }).to be_nil
    end

    it "他テナントの通知の既読化は 404（acts_as_tenant default_scope）" do
      other_org = create(:organization)
      n = ActsAsTenant.with_tenant(other_org) { create(:notification) }
      sign_in owner
      patch notification_url(n, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
    end
  end
end
```

Run: `bundle exec rspec spec/requests/notifications_spec.rb`
Expected: FAIL（route/controller 未定義）。

- [ ] **Step 4: routes を追加**

`config/routes.rb` の `resources :monthly_attendance_summaries ... end` の後（`root` の前）に追記:

```ruby
  resources :notifications, only: %i[index update]
```

- [ ] **Step 5: NotificationsController を実装**

```ruby
# frozen_string_literal: true

# 通知一覧 + 既読化（設計 §5.2 / §9⑤）。policy_scope + authorize の二層で IDOR を塞ぐ。
class NotificationsController < ApplicationController
  def index
    authorize Notification
    @notifications = policy_scope(Notification).order(created_at: :desc)
  end

  def update
    @notification = policy_scope(Notification).find(params[:id]) # 他人/他テナントは 404
    authorize @notification # update? = 本人のみ（二層目）
    @notification.update!(read_at: Time.current)
    redirect_to notifications_path, status: :see_other, notice: "既読にしました"
  end
end
```

- [ ] **Step 6: `_notification` partial をドロップダウン/一覧共用に再整形**

`app/views/notifications/_notification.html.erb`（4-1b の最小要素を置換）:

```erb
<%# broadcast(ベル prepend) と一覧で共用する 1 項目。既読は淡色化 %>
<li id="<%= dom_id(notification) %>" class="notification-item border-b border-gray-100 px-3 py-2 text-sm <%= notification.read_at? ? "text-gray-500" : "font-semibold text-gray-900" %>">
  <%= notification.title %>
</li>
```

- [ ] **Step 7: index ビューを作成**

`app/views/notifications/index.html.erb`:

```erb
<% content_for :title, "通知" %>
<div class="w-full max-w-2xl">
  <h1 class="mb-4 text-lg font-bold">通知</h1>
  <% if @notifications.empty? %>
    <p class="text-sm text-gray-500">通知はありません。</p>
  <% else %>
    <ul id="notifications_index" class="rounded border border-gray-200 bg-white">
      <% @notifications.each do |notification| %>
        <li class="flex items-center justify-between border-b border-gray-100 px-3 py-2 text-sm <%= notification.read_at? ? "text-gray-500" : "font-semibold text-gray-900" %>">
          <span><%= notification.title %></span>
          <% unless notification.read_at? %>
            <%= button_to "既読にする", notification_path(notification), method: :patch,
                  class: "rounded bg-gray-800 px-2 py-1 text-xs text-white" %>
          <% end %>
        </li>
      <% end %>
    </ul>
  <% end %>
</div>
```

- [ ] **Step 8: テストを通す**

Run: `bundle exec rspec spec/requests/notifications_spec.rb spec/policies/notification_policy_spec.rb`
Expected: 全 PASS。

- [ ] **Step 9: rubocop**

Run: `bundle exec rubocop --force-exclusion app/controllers/notifications_controller.rb app/policies/notification_policy.rb`
Expected: 0 offenses。

- [ ] **Step 10: Commit**

```bash
git add app/policies/notification_policy.rb app/controllers/notifications_controller.rb app/views/notifications config/routes.rb spec/policies/notification_policy_spec.rb spec/requests/notifications_spec.rb
git commit -m "feat: 通知一覧 + 既読化（NotificationsController/Policy・IDOR 二層）"
```

---

## Task 4: NotificationPreferencesController（通知設定・User+UNP 単一 tx）

**Files:**
- Create: `app/policies/notification_preference_policy.rb`
- Create: `app/controllers/notification_preferences_controller.rb`
- Create: `app/views/notification_preferences/edit.html.erb`
- Modify: `config/routes.rb`
- Test: `spec/requests/notification_preferences_spec.rb`

**Interfaces:**
- Consumes: `current_user`（`email_enabled` / `notification_preference` has_one）/ `UserNotificationPreference`（抑制系）/ `ActsAsTenant.current_tenant.setting`（既定値フォールバック）。
- Produces: route helper `edit_notification_preferences_path` / `notification_preferences_path`（PATCH）。

> §9⑥: User 更新は permit `:email_enabled` のみ・current_user 限定。UNP の `user_id`/`organization_id` はサーバ権威。2 モデル更新は単一 tx。`NotificationPreferencePolicy` は headless symbol authorize（`authorize :notification_preference, :edit?`）で Pundit 一元化。

- [ ] **Step 1: request spec を書く（2 モデル更新・permit 境界・単一 tx）**

`spec/requests/notification_preferences_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "NotificationPreferences", type: :request do
  let!(:org)  { create(:organization, subdomain: "acme") }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user, email_enabled: false) } }

  describe "GET edit" do
    it "設定画面を表示する（UNP 未作成でも組織既定で描画）" do
      sign_in user
      get edit_notification_preferences_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end
  end

  describe "PATCH update" do
    it "User.email_enabled と UNP 抑制設定を同時に更新する" do
      sign_in user
      patch notification_preferences_url(host: tenant_host(org)), params: {
        user: { email_enabled: "1" },
        notification_preference: {
          quiet_hours_enabled: "1", quiet_hours_start: "22", quiet_hours_end: "7", holiday_block_enabled: "0"
        }
      }
      expect(response).to have_http_status(:see_other)
      ActsAsTenant.with_tenant(org) do
        expect(user.reload.email_enabled).to be(true)
        pref = user.notification_preference
        expect(pref.quiet_hours_enabled).to be(true)
        expect(pref.quiet_hours_start).to eq(22)
        expect(pref.quiet_hours_end).to eq(7)
        expect(pref.holiday_block_enabled).to be(false)
        expect(pref.user_id).to eq(user.id)           # サーバ権威
        expect(pref.organization_id).to eq(org.id)    # サーバ権威
      end
    end

    it "UNP の user_id/organization_id は params で乗っ取れない（サーバ権威）" do
      other = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in user
      patch notification_preferences_url(host: tenant_host(org)), params: {
        user: { email_enabled: "0" },
        notification_preference: { user_id: other.id, organization_id: 999_999,
                                   quiet_hours_enabled: "1", quiet_hours_start: "19",
                                   quiet_hours_end: "8", holiday_block_enabled: "1" }
      }
      expect(response).to have_http_status(:see_other)
      ActsAsTenant.with_tenant(org) do
        expect(user.notification_preference.user_id).to eq(user.id)
        expect(user.notification_preference.organization_id).to eq(org.id)
      end
    end

    it "不正値（quiet_hours_start 範囲外）は部分更新せず再描画" do
      sign_in user
      patch notification_preferences_url(host: tenant_host(org)), params: {
        user: { email_enabled: "1" },
        notification_preference: { quiet_hours_enabled: "1", quiet_hours_start: "99",
                                   quiet_hours_end: "8", holiday_block_enabled: "1" }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(ActsAsTenant.with_tenant(org) { user.reload.email_enabled }).to be(false) # User も巻き戻る（単一 tx）
    end
  end
end
```

Run: `bundle exec rspec spec/requests/notification_preferences_spec.rb`
Expected: FAIL（route/controller/policy 未定義）。

- [ ] **Step 2: routes を追加**

`config/routes.rb` の Task 3 で足した `resources :notifications` の後に追記:

```ruby
  resource :notification_preferences, only: %i[edit update] # singular（current_user 自身の設定）
```

- [ ] **Step 3: NotificationPreferencePolicy を実装**

```ruby
# frozen_string_literal: true

# 通知設定の認可（設計 §9⑤）。current_user 自身の設定ゆえ presence で開く（headless）。
class NotificationPreferencePolicy < ApplicationPolicy
  def edit? = user.present?
  def update? = user.present?
end
```

- [ ] **Step 4: NotificationPreferencesController を実装**

```ruby
# frozen_string_literal: true

# 通知設定（設計 §5.3 / §9⑥）。User.email_enabled（個人メール opt-in SSOT）と
# UserNotificationPreference（抑制系）を 1 画面・単一 tx で更新。UNP の所有は current_user 固定。
class NotificationPreferencesController < ApplicationController
  def edit
    authorize :notification_preference, :edit?
    @preference = current_user.notification_preference || build_default_preference
  end

  def update
    authorize :notification_preference, :update?
    @preference = current_user.notification_preference || current_user.build_notification_preference
    ActiveRecord::Base.transaction do
      current_user.update!(user_params)          # permit は :email_enabled のみ
      @preference.update!(preference_params)      # user_id/organization_id は受けない（サーバ権威）
    end
    redirect_to edit_notification_preferences_path, status: :see_other, notice: "通知設定を更新しました"
  rescue ActiveRecord::RecordInvalid
    @preference ||= build_default_preference
    flash.now[:alert] = "通知設定を更新できませんでした"
    render :edit, status: :unprocessable_entity
  end

  private

  # UNP 未作成時の表示既定は OrganizationSetting フォールバック（§4.2）。has_one builder が user_id を設定。
  def build_default_preference
    s = ActsAsTenant.current_tenant.setting
    current_user.build_notification_preference(
      quiet_hours_enabled: s.quiet_hours_enabled,
      quiet_hours_start: s.quiet_hours_start,
      quiet_hours_end: s.quiet_hours_end,
      holiday_block_enabled: s.holiday_block_enabled
    )
  end

  def user_params
    params.require(:user).permit(:email_enabled)
  end

  def preference_params
    params.require(:notification_preference)
          .permit(:quiet_hours_enabled, :quiet_hours_start, :quiet_hours_end, :holiday_block_enabled)
  end
end
```

- [ ] **Step 5: edit ビューを作成（checkbox は hidden + checkbox で未チェック=false を担保）**

`app/views/notification_preferences/edit.html.erb`:

```erb
<% content_for :title, "通知設定" %>
<div class="w-full max-w-xl">
  <h1 class="mb-4 text-lg font-bold">通知設定</h1>
  <%= form_with url: notification_preferences_path, method: :patch do %>
    <fieldset class="mb-6">
      <legend class="mb-2 font-semibold">メール通知</legend>
      <label class="flex items-center gap-2 text-sm">
        <%= hidden_field_tag "user[email_enabled]", "0" %>
        <%= check_box_tag "user[email_enabled]", "1", current_user.email_enabled %>
        メール通知を受け取る（組織側も有効な場合のみ送信）
      </label>
    </fieldset>

    <fieldset class="mb-6">
      <legend class="mb-2 font-semibold">抑制（夜間・休日）</legend>
      <label class="mb-2 flex items-center gap-2 text-sm">
        <%= hidden_field_tag "notification_preference[quiet_hours_enabled]", "0" %>
        <%= check_box_tag "notification_preference[quiet_hours_enabled]", "1", @preference.quiet_hours_enabled %>
        夜間はメールを送らない
      </label>
      <div class="mb-2 flex items-center gap-2 text-sm">
        <label>開始
          <%= number_field_tag "notification_preference[quiet_hours_start]", @preference.quiet_hours_start,
                in: 0..23, class: "w-16 rounded border px-1" %> 時</label>
        <label>終了
          <%= number_field_tag "notification_preference[quiet_hours_end]", @preference.quiet_hours_end,
                in: 0..23, class: "w-16 rounded border px-1" %> 時</label>
      </div>
      <label class="flex items-center gap-2 text-sm">
        <%= hidden_field_tag "notification_preference[holiday_block_enabled]", "0" %>
        <%= check_box_tag "notification_preference[holiday_block_enabled]", "1", @preference.holiday_block_enabled %>
        休日はメールを送らない
      </label>
    </fieldset>

    <%= submit_tag "保存", class: "rounded bg-gray-800 px-4 py-2 text-sm text-white" %>
  <% end %>
</div>
```

- [ ] **Step 6: テストを通す**

Run: `bundle exec rspec spec/requests/notification_preferences_spec.rb`
Expected: 全 PASS。

- [ ] **Step 7: rubocop**

Run: `bundle exec rubocop --force-exclusion app/controllers/notification_preferences_controller.rb app/policies/notification_preference_policy.rb`
Expected: 0 offenses。

- [ ] **Step 8: Commit**

```bash
git add app/policies/notification_preference_policy.rb app/controllers/notification_preferences_controller.rb app/views/notification_preferences config/routes.rb spec/requests/notification_preferences_spec.rb
git commit -m "feat: 通知設定（User.email_enabled + UNP 抑制を単一 tx・サーバ権威）"
```

---

## Task 5: NotificationBellComponent + 署名 Stream 購読 + Notifier 件数 broadcast

**Files:**
- Create: `app/components/notification_bell_component.rb`
- Create: `app/components/notification_bell_component.html.erb`
- Create: `app/views/notifications/_bell_count.html.erb`
- Modify: `app/components/global_nav_component.html.erb`
- Modify: `app/views/layouts/application.html.erb`
- Modify: `app/services/notifier.rb`
- Test: `spec/components/notification_bell_component_spec.rb` / `spec/services/notifier_spec.rb`（追記）

**Interfaces:**
- Consumes: `current_user.notifications`（= `NotificationPolicy::Scope` 述語）/ `_notification` partial（Task 3）/ `Notification.unread`。
- Produces: DOM 契約 — `<ul id="notifications">`（broadcast prepend 先）/ `id="notification_bell_count"`（broadcast replace 先）。`_bell_count` partial（component と Notifier 共用）。

> §9⑨: `turbo_stream_from current_user`（単一引数）と `broadcast_*_to(@target_user)` は同一 raw GID param stream。Notifier は prepend（既存）に加え件数 replace を broadcast。ベルは `current_user.notifications`（本人ルート・bare `Notification` 不使用）。dev は async adapter（in-process）ゆえ request 文脈 producer のベルは出る。

- [ ] **Step 1: `_bell_count` partial を作成（component/broadcast 共用・DRY）**

`app/views/notifications/_bell_count.html.erb`:

```erb
<%# 未読バッジ。broadcast replace の target ゆえ id を保持。0 件は数字非表示 %>
<span id="notification_bell_count" class="<%= count.positive? ? "ml-1 rounded-full bg-red-600 px-1.5 text-xs text-white" : "" %>">
  <%= count.positive? ? count : "" %>
</span>
```

- [ ] **Step 2: NotificationBellComponent の失敗するテストを書く**

`spec/components/notification_bell_component_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationBellComponent, type: :component do
  let(:org)  { create(:organization) }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user, name: "本人") } }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  it "未読件数をバッジに出す（既読は数えない）" do
    create(:notification, target_user: user, read_at: nil)
    create(:notification, target_user: user, read_at: Time.current)
    render_inline(described_class.new(current_user: user))
    expect(page).to have_css("#notification_bell_count", text: "1")
  end

  it "未読ゼロはバッジ数字なし（要素は存在＝broadcast 先確保）" do
    render_inline(described_class.new(current_user: user))
    expect(page).to have_css("#notification_bell_count")
    expect(page.find("#notification_bell_count").text.strip).to eq("")
  end

  it "直近通知をドロップダウン list（#notifications）に出す" do
    create(:notification, target_user: user, title: "申請が承認されました")
    render_inline(described_class.new(current_user: user))
    expect(page).to have_css("ul#notifications")
    expect(page).to have_text("申請が承認されました")
  end
end
```

Run: `bundle exec rspec spec/components/notification_bell_component_spec.rb`
Expected: FAIL（component 未定義）。

- [ ] **Step 3: NotificationBellComponent を実装**

```ruby
# frozen_string_literal: true

# グローバルナビ常設の通知ベル（設計 §5.1）。未読バッジ + 直近通知ドロップダウン。
# 描画は current_user.notifications（= NotificationPolicy::Scope の述語 target_user_id=user.id・
# 本人ルートゆえ越境不能・§9⑤）。bare Notification を触らない。
class NotificationBellComponent < ViewComponent::Base
  RECENT_LIMIT = 10

  def initialize(current_user:)
    @current_user = current_user
  end

  attr_reader :current_user

  def recent
    @recent ||= current_user.notifications.order(created_at: :desc).limit(RECENT_LIMIT)
  end

  def unread_count
    current_user.notifications.unread.count
  end
end
```

- [ ] **Step 4: NotificationBellComponent の template を作成**

`app/components/notification_bell_component.html.erb`:

```erb
<%# ネイティブ disclosure（JS 不要）。#notifications=prepend 先 / #notification_bell_count=件数 replace 先 %>
<details class="relative">
  <summary class="flex cursor-pointer list-none items-center rounded px-2 py-1.5 hover:bg-gray-100">
    <span aria-label="通知" title="通知">🔔</span>
    <%= render "notifications/bell_count", count: unread_count %>
  </summary>
  <div class="absolute right-0 z-10 mt-1 w-72 rounded border border-gray-200 bg-white shadow">
    <ul id="notifications" class="max-h-80 overflow-y-auto">
      <% recent.each do |notification| %>
        <%= render "notifications/notification", notification: notification %>
      <% end %>
    </ul>
    <div class="border-t border-gray-100 px-3 py-2 text-center text-xs">
      <%= link_to "すべての通知", helpers.notifications_path, class: "text-gray-600 hover:underline" %>
    </div>
  </div>
</details>
```

Run: `bundle exec rspec spec/components/notification_bell_component_spec.rb`
Expected: PASS。

- [ ] **Step 5: GlobalNav にベルを挿入**

`app/components/global_nav_component.html.erb` の右側 flex（`<span><%= current_user.name %>` の前）にベルを差す:

```erb
    <div class="flex items-center gap-3 text-sm text-gray-600">
      <%= render NotificationBellComponent.new(current_user: current_user) %>
      <span><%= current_user.name %><% if ActsAsTenant.current_tenant %>（<%= ActsAsTenant.current_tenant.name %>）<% end %></span>
      <%= button_to "ログアウト", helpers.destroy_user_session_path, method: :delete,
            class: "rounded bg-gray-800 px-3 py-1.5 text-white" %>
    </div>
```

- [ ] **Step 6: layout に署名 Stream 購読を追加（§9⑨・単一引数）**

`app/views/layouts/application.html.erb` の `<% if user_signed_in? %>` ブロック内、GlobalNav render の直後に追記:

```erb
    <% if user_signed_in? %>
      <%= render GlobalNavComponent.new(current_user: current_user) %>
      <%= turbo_stream_from current_user %><%# §9⑨ 単一引数=Notifier の broadcast_*_to(@target_user) と同一 GID stream %>
    <% end %>
```

- [ ] **Step 7: GlobalNav spec がベル混入で壊れないこと + ベルが出ることを確認/追記**

`spec/components/global_nav_component_spec.rb` は `User.new`（未永続・テナント無）で render する。ベルは `current_user.notifications`（DB クエリ）を呼ぶため、**未永続 User だと壊れる**。GlobalNav spec のベル依存を切るため、ベル描画を伴う検証は component spec（Task 5 Step 2）に委ね、GlobalNav spec 側はベルの存在のみ薄く確認する。GlobalNav spec の各 `render_at` は `User.new` ゆえ `notifications` が `ActiveRecord::Associations` で空配列を返すか確認 — 未永続 AR の has_many は空 Relation（クエリ未発行で `.limit.to_a`=[]・`.unread.count`=0）。実機で確認し、もし `NoTenantSet`/クエリ発行で落ちるなら GlobalNav spec のユーザーを永続化（`ActsAsTenant.with_tenant(org) { create(:user, ...) }`）+ `around` でテナント包む方式へ移行する。

Run: `bundle exec rspec spec/components/global_nav_component_spec.rb`
Expected: PASS（必要なら上記の永続化対応を施す）。

> 実装者へ: 未永続 `User.new.notifications.unread.count` が `NoTenantSet` で落ちる場合、GlobalNav spec を `let(:org){create(:organization)}` + `around { ActsAsTenant.with_tenant(org){ } }` + `create(:user, role:, name:)` へ書き換える（既存 4 例の `User.new(role:, name:)` を置換）。この判断は実機の 1 回実行で確定すること。

- [ ] **Step 8: Notifier に件数 broadcast を追加（既存 prepend は維持）**

`app/services/notifier.rb` の `broadcast_in_app` を置換:

```ruby
  # 署名 stream（GlobalID）にのみ broadcast（§9⑨）。prepend（ドロップダウン）+ 件数 replace（バッジ）。
  def broadcast_in_app(notification)
    Turbo::StreamsChannel.broadcast_prepend_to(
      @target_user, target: "notifications",
      partial: "notifications/notification", locals: { notification: }
    )
    Turbo::StreamsChannel.broadcast_replace_to(
      @target_user, target: "notification_bell_count",
      partial: "notifications/bell_count",
      locals: { count: Notification.unread.where(target_user: @target_user).count }
    )
  end
```

- [ ] **Step 9: Notifier spec に件数 broadcast の例を追記**

`spec/services/notifier_spec.rb` の `describe "in_app（常時・優先度/opt-in 非依存）"` に追加:

```ruby
    it "未読件数バッジを署名 stream に replace broadcast する（§9⑨）" do
      expect { call }.to have_broadcasted_to(target.to_gid_param)
        .with(hash_including(content: a_string_including("notification_bell_count")))
    end
```

> 注: 既存の `have_broadcasted_to(target.to_gid_param)`（prepend）例は **broadcast を 1 件以上**で照合するため、replace 追加で壊れない。replace 内容の特定は `content` の `notification_bell_count` 包含で行う。実機で matcher 形（`.with(hash_including(...))`）が turbo の payload と噛み合わない場合は `assert_turbo_stream_broadcasts` 系へ切替（RAILS_GOTCHAS の broadcast 項参照）。

- [ ] **Step 10: 全テストを通す**

Run: `bundle exec rspec spec/components/notification_bell_component_spec.rb spec/services/notifier_spec.rb spec/components/global_nav_component_spec.rb`
Expected: 全 PASS。

- [ ] **Step 11: rubocop**

Run: `bundle exec rubocop --force-exclusion app/components/notification_bell_component.rb app/services/notifier.rb`
Expected: 0 offenses。

- [ ] **Step 12: Commit**

```bash
git add app/components/notification_bell_component.rb app/components/notification_bell_component.html.erb app/views/notifications/_bell_count.html.erb app/components/global_nav_component.html.erb app/views/layouts/application.html.erb app/services/notifier.rb spec/components/notification_bell_component_spec.rb spec/services/notifier_spec.rb spec/components/global_nav_component_spec.rb
git commit -m "feat: 通知ベル（署名 stream 購読 + 未読バッジ/ドロップダウン・件数 broadcast）"
```

---

## Task 6: producer 接続（承認/却下 → requester 通知）

**Files:**
- Modify: `app/controllers/approval_assignments_controller.rb`
- Test: `spec/requests/approval_assignments_spec.rb`（追記）

**Interfaces:**
- Consumes: `Approvals::Approve`/`Reject`（戻り後の `approvable.approved?`/`rejected?`）/ `approvable.requester` / `Notifier.call`。
- Produces: なし（副作用＝requester への Notification + broadcast）。

> §5.4/§9③: service 戻り後（`with_lock` の外・tx commit 済）に発火。approve は `if approvable.approved?`（中間 `applying?`・取下げ承認 `:withdrawn` は不発火）、reject は `if approvable.rejected?`（取下げ却下 `:approved` 復帰は不発火）。両者 informational・subject_user=requester。**approval-engine-reviewer 必須**。

- [ ] **Step 1: producer の request spec を既存 fixture 流用で書く**

`spec/requests/approval_assignments_spec.rb` に追記（既存 `let!` の `org/boss/dept/emp/leave` と `assignment_for` を流用。2 段ルート `[boss, dept]`）:

```ruby
  describe "producer 接続（承認/却下 → requester 通知・§5.4）" do
    include ActiveJob::TestHelper

    it "終端承認（全段）で requester に request_approved 通知 + broadcast" do
      sign_in boss
      patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org)) # 中間（pos1）
      sign_in dept
      expect {
        patch approve_approval_assignment_url(assignment_for(2), host: tenant_host(org)) # 終端（pos2）
      }.to have_broadcasted_to(emp.to_gid_param)
      ActsAsTenant.with_tenant(org) do
        n = Notification.where(target_user: emp, source_type: :request_approved)
        expect(n.count).to eq(1)
        expect(n.first.priority).to eq("informational")
        expect(n.first.subject_user_id).to eq(emp.id)
      end
    end

    it "中間段階（pos1 のみ承認・applying）では通知ゼロ" do
      sign_in boss
      expect {
        patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org))
      }.not_to have_broadcasted_to(emp.to_gid_param)
      ActsAsTenant.with_tenant(org) do
        expect(leave.reload.approval_status).to eq("applying")
        expect(Notification.where(target_user: emp).count).to eq(0)
      end
    end

    it "却下で requester に request_rejected 通知" do
      sign_in boss
      expect {
        patch reject_approval_assignment_url(assignment_for(1), host: tenant_host(org), params: { comment: "却下理由" })
      }.to have_broadcasted_to(emp.to_gid_param)
      ActsAsTenant.with_tenant(org) do
        expect(leave.reload.approval_status).to eq("rejected")
        n = Notification.where(target_user: emp, source_type: :request_rejected)
        expect(n.count).to eq(1)
        expect(n.first.priority).to eq("informational")
      end
    end
  end

  describe "producer の幻通知防止（over-balance rollback・§9③）" do
    let!(:paid_type) { ActsAsTenant.with_tenant(org) { create(:leave_type, system_type: :annual, paid_leave: true) } }
    let!(:paid_leave) do
      ActsAsTenant.with_tenant(org) do
        LeaveRequests::Create.call(requester: emp, leave_type: paid_type, start_date: Date.new(2026, 5, 1),
                                   end_date: Date.new(2026, 5, 1), half_day_type: "none", reason: "有給")
      end
    end
    def paid_assignment(pos) = ActsAsTenant.with_tenant(org) { paid_leave.approval_assignments.find_by(position: pos) }

    it "残高ゼロの最終承認は rollback → Notification 0 件・broadcast 0 件（幻ベルなし）" do
      sign_in boss
      patch approve_approval_assignment_url(paid_assignment(1), host: tenant_host(org))
      sign_in dept
      expect {
        patch approve_approval_assignment_url(paid_assignment(2), host: tenant_host(org)) # OverBalanceError → rollback
      }.not_to have_broadcasted_to(emp.to_gid_param)
      ActsAsTenant.with_tenant(org) do
        expect(paid_leave.reload.approval_status).to eq("applying") # rollback で applying のまま
        expect(Notification.where(target_user: emp).count).to eq(0)
      end
    end
  end
```

Run: `bundle exec rspec spec/requests/approval_assignments_spec.rb`
Expected: 新規例は FAIL（producer 未接続）。既存例は PASS のまま。

- [ ] **Step 2: producer を controller に接続**

`app/controllers/approval_assignments_controller.rb` の `approve`/`reject` を修正し private に `notify_decision` を追加:

```ruby
  def approve
    authorize @assignment, :approve?
    approvable = @assignment.approvable
    Approvals::Approve.call(approvable:, approver: current_user, comment: params[:comment])
    notify_decision(approvable, :request_approved) if approvable.approved? # 終端のみ（中間/取下げ承認は不発火）
    redirect_to approval_assignments_path, status: :see_other, notice: "承認しました"
  rescue Approvals::OverBalanceError
    redirect_to approval_assignments_path, status: :see_other,
                alert: "残高不足で承認できません（人事へ残高の付与をご依頼ください）"
  rescue Approvals::ClosingLockedError
    redirect_to approval_assignments_path, status: :see_other,
                alert: "対象月は締め済みのため承認できません（管理者へ差戻し依頼をご検討ください）"
  rescue Approvals::ConflictError
    msg = @assignment.purpose_withdrawal? ? "対象記録が変更されているため撤回できません" :
                                            "変更前時刻が現在の記録と一致しません（申請者へ再申請をご依頼ください）"
    redirect_to approval_assignments_path, status: :see_other, alert: msg
  rescue ActiveRecord::RecordInvalid
    redirect_to approval_assignments_path, status: :see_other,
                alert: "承認できませんでした（記録の整合性エラー）"
  rescue AASM::InvalidTransition, Approvals::NotCurrentApprover
    redirect_to approval_assignments_path, status: :see_other, alert: "この申請は既に処理されています"
  end

  def reject
    authorize @assignment, :reject?
    approvable = @assignment.approvable
    Approvals::Reject.call(approvable:, approver: current_user, comment: params[:comment])
    notify_decision(approvable, :request_rejected) if approvable.rejected? # 取下げ却下（approved 復帰）は不発火
    redirect_to approval_assignments_path, status: :see_other, notice: "却下しました"
  rescue ArgumentError
    redirect_to approval_assignments_path, status: :see_other, alert: "却下理由を入力してください"
  rescue AASM::InvalidTransition, Approvals::NotCurrentApprover
    redirect_to approval_assignments_path, status: :see_other, alert: "この申請は既に処理されています"
  end

  private

  # 承認/却下の終端でのみ requester へ通知（§5.4・informational・既定ベル）。
  # service 戻り後ゆえ承認 tx は commit 済 → Notifier が最外 tx（§9③ / ROADMAP 申し送り）。
  # テナント文脈は ApplicationController の resolve_tenant_from_subdomain で確立済。
  def notify_decision(approvable, source_type)
    verb = source_type == :request_approved ? "承認" : "却下"
    Notifier.call(
      target_user: approvable.requester,
      title: "申請が#{verb}されました",
      body: "あなたの申請が#{verb}されました。",
      priority: :informational,
      source_type:,
      subject_user: approvable.requester
    )
  end
```

> 注（同一インスタンス前提）: controller で `approvable = @assignment.approvable` を 1 度だけ取り service に渡す。service は同一オブジェクトを `with_lock`/AASM `approve!`/`reject!` で変異させるため、戻り後の `approvable.approved?`/`rejected?` は commit 後状態を反映（reload 不要）。

- [ ] **Step 3: テストを通す**

Run: `bundle exec rspec spec/requests/approval_assignments_spec.rb`
Expected: 全 PASS（producer 例 + 既存承認/却下例）。

- [ ] **Step 4: rubocop**

Run: `bundle exec rubocop --force-exclusion app/controllers/approval_assignments_controller.rb`
Expected: 0 offenses。

- [ ] **Step 5: Commit**

```bash
git add app/controllers/approval_assignments_controller.rb spec/requests/approval_assignments_spec.rb
git commit -m "feat: 承認/却下 producer 接続（終端のみ requester 通知・tx 後発火・幻通知防止）"
```

---

## Task 7: §1.4 動線 2 行 + ROADMAP reconcile（drift 防止）

**Files:**
- Modify: `docs/SPEC.md`（§1.4 テーブル）
- Modify: `docs/ROADMAP.md`（4-1 行チェック + 4-2 reconcile）

**Interfaces:** docs のみ（コード変化なし）。

> §1.4 到達性 DoD: 追加行の起点 route が実在し nav から到達可能・状態 ✅ が実態と一致（Task 3/4/5 完了が前提）。§9⑫: 4-2 の承認/却下接続を 4-1c 充足へ更新。

- [ ] **Step 1: §1.4 に 2 行追加**

`docs/SPEC.md` §1.4 の社員行の末尾に追記（既存テーブルの列構成に合わせる。列は実ファイルの見出しに厳密一致させること）:

```
| 社員 | 通知を確認し既読にしたい | `/notifications` | GlobalNav 🔔ベル | 通知一覧・既読 flagging | ✅ | §4.18 |
| 社員 | 通知設定（抑制・メール opt-in）を変更したい | `/notification_preferences/edit` | GlobalNav 🔔 →「すべての通知」近傍 | quiet_hours / email_enabled 更新 | ✅ | §4.15 / §4.17 |
```

> 実装者へ: §1.4 の実テーブル列順（アクター/目的/起点 route/nav 入口/結果/状態/§参照 等）を Read で確認し、列数・区切りを既存行に厳密一致させてから挿入する（列ズレは表崩れ）。

- [ ] **Step 2: ROADMAP の 4-1 行を更新 + 4-2 reconcile**

`docs/ROADMAP.md` の 4-1 行（`4-1c UI+承認/却下 producer は後続` の部分）を **`4-1c UI+producer ✅ PR #<番号>`** に更新し、4-1c 申し送り/backlog のうち本スライスで消化した項目（perf index 対称化・必須 belongs_to discriminating 化）に消化済マークを付す。さらに 4-2 行の「承認/却下接続」に **「4-1c で充足済（§9⑫）」** を注記する（4-2 での二重実装防止）。

> 未消化のまま 4-1c 後へ残す backlog（ROADMAP に明示維持）: `NotificationDispatchJob` の `queue_as` 明示（4-2/4-3）・`next_allowed_at` 連続休日考慮（producer live 化前）。これらは 4-1c スコープ外（本計画は接続せず）。

- [ ] **Step 3: Commit**

```bash
git add docs/SPEC.md docs/ROADMAP.md
git commit -m "docs: §1.4 通知動線 2 行 + ROADMAP 4-1c ✅/4-2 reconcile（§9⑫）"
```

> PR 番号は finishing-a-development-branch で PR 作成後に確定。ROADMAP の `PR #<番号>` は PR 作成後のフォローコミット（または PR にローカル追従コミットを含める）で埋める。

---

## 仕上げ（全タスク後）

1. **全スイート + 静的検証**:
   - `bundle exec rspec`（全緑・既存 pending は Approvals 自己承認 #2 のみ）
   - `bundle exec rubocop --force-exclusion $(git diff --name-only main...HEAD | grep '\.rb$')`
   - `bin/brakeman --no-pager`（app/ 変更ゆえ・0 warning 目標）
2. **§1.4 到達性 DoD 手検**: dev で `🔔` → `/notifications` → 既読 → `/notification_preferences/edit` が nav から到達可能・状態 ✅ が実態一致。
3. **マージ前レビュアー**: `tenant-isolation-reviewer`（models/jobs 不変だが controller/Notifier の broadcast テナント文脈確認）+ **`approval-engine-reviewer`**（Task 6 の発火点が `with_lock` 外・終端ガード・幻通知防止）。
4. **whole-branch review**（最強モデル）→ finishing-a-development-branch。
5. **RAILS_GOTCHAS 還流**: 本スライスで新たに踏んだ罠（例: 未永続 User での component 描画・turbo broadcast matcher 形）があれば本 PR で追記。

## Self-Review（writing-plans 規約）

- **Spec coverage（§5/§9 binding）**: §5.1 ベル=Task5 / §5.2 一覧・既読=Task3 / §5.3 設定=Task4 / §5.4 producer=Task6 / §5.5 §1.4 行=Task7 / §9⑤ IDOR=Task3,4 / §9⑥ フォーム境界=Task4 / §9⑨ 署名 stream=Task5 / §9⑫ reconcile=Task7 / §9⑬ 負例（IDOR/却下経路/多段中間/rollback/二重 opt-in は 4-1b 済）=Task2,3,6。perf index/discriminating 負例（ROADMAP backlog 対称化）=Task1,2。
- **Placeholder scan**: 全コードブロックは実コード。PR 番号のみ後埋め（finishing 後・明示）。GlobalNav spec の未永続 User 対応は「実機 1 回で確定」の条件分岐として明記（曖昧さを実装者判断に投げない指示付き）。
- **Type consistency**: `Notifier.call(target_user:, title:, body:, priority:, source_type:, subject_user:)`（4-1b 実シグネチャ）/ `current_user.notifications`（has_one/has_many 実在）/ `approvable.requester`（3 型共通 belongs_to）/ `approvable.approved?`/`rejected?`（Approvable AASM 述語）/ `broadcast_prepend_to`/`broadcast_replace_to`（turbo-rails）/ DOM 契約 `#notifications`・`#notification_bell_count`（partial と broadcast target 一致）— 全て調査で実在確認済。
