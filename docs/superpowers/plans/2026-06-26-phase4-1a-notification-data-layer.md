# Phase 4-1a 通知基盤データ層 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 通知基盤の永続層（users.email_enabled・organization_settings 抑制/opt-in 列・Notification / NotificationDelivery / UserNotificationPreference テーブルとモデル）を、テナント安全（複合 FK + 同一組織検証の二重防御）に整備する。配信ロジック・UI・producer は 4-1b/4-1c。

**Architecture:** マルチテナント複合 FK idiom（`[organization_id, X] → users[organization_id, id]`）でクロステナント参照を DB 層で遮断し、モデルの `*_must_belong_to_same_organization`（ID 基点 fail-closed）と二層で守る。enum は integer・boolean は `null: false, default`。本スライスはデータ層のみで振る舞い無し（§1.4 動線行を持たない）。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / acts_as_tenant / FactoryBot / RSpec。

**設計参照:** `docs/superpowers/specs/2026-06-26-phase4-1-notification-infrastructure-design.md` の §3（データモデル）・§9④（同一組織検証）・§9⑬（テスト負例）。SPEC §4.4 / §4.15 / §4.17 / §4.18。

## Global Constraints

- **コミット identity:** kei1110 <eoh2145@gmail.com>（local config 済）。remote は `github-kei1110`。
- **コミットメッセージ末尾:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
- **schema.rb / queue_schema.rb は手編集禁止**（`bin/rails db:migrate && bin/rails db:test:prepare` で自動更新）。rspec 実行で `db/queue_schema.rb` が再生成されたら `git checkout -- db/queue_schema.rb` でコミットから除外。
- **migration は generate → body 差し替え**（`block-schema-edit` フックゆえ）。`<ts>` は generate が確定する実タイムスタンプ。
- **複合 FK 必須:** ユーザー参照・他テーブル参照は `add_foreign_key ..., column: %i[organization_id xxx_id], primary_key: %i[organization_id id]`。単純 FK にしない（§3.6）。
- **rubocop:** `bundle exec rubocop --force-exclusion <files>`（ファイル明示時は `--force-exclusion` 必須・db/schema.rb 等の Exclude を効かせる）。
- **検証コマンド（各タスク完了条件）:** `bundle exec rspec <該当spec>` 緑 + `bundle exec rubocop --force-exclusion <触ったファイル>` 緑。
- **マージ前:** models / migrations に触れるため `tenant-isolation-reviewer` を回す。
- **テナント文脈:** model spec は `let(:org) { create(:organization) }` + `around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }`。

---

### Task 1: users.email_enabled + SPEC §4.17 不整合解消

個人メール opt-in フラグの SSOT を `users` 列に確定（設計 判断 B）。SPEC §4.17 の重複記載（UserNotificationPreference 側の email_enabled）を削除し不整合を解消する。

**Files:**
- Create: `db/migrate/<ts>_add_email_enabled_to_users.rb`
- Modify: `docs/SPEC.md`（§4.17 の email_enabled 行削除 + 注記）
- Test: `spec/models/user_spec.rb`（既存に example 追記）

**Interfaces:**
- Produces: `User#email_enabled`（boolean・既定 false・null false）。4-1b の二重 opt-in 判定が読む。

- [ ] **Step 1: migration 生成 + body 差し替え**

```bash
bin/rails generate migration AddEmailEnabledToUsers
```

生成された `db/migrate/<ts>_add_email_enabled_to_users.rb` の body を全置換:

```ruby
# frozen_string_literal: true

class AddEmailEnabledToUsers < ActiveRecord::Migration[8.1]
  def change
    # 個人メール通知 opt-in（SPEC §4.4・二重 opt-in の個人側 SSOT）。
    # 既定 false（opt-out から開始）・boolean は NULL 三値を作らない
    add_column :users, :email_enabled, :boolean, null: false, default: false
  end
end
```

- [ ] **Step 2: migrate 実行**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `add_column(:users, :email_enabled...)` が走り schema.rb 自動更新。

- [ ] **Step 3: 失敗するテストを書く**

`spec/models/user_spec.rb` に追記（既存の describe 構造に合わせ新 describe を追加）:

```ruby
  describe "email_enabled（個人メール opt-in・§4.4）" do
    it "既定は false" do
      expect(create(:user).email_enabled).to be(false)
    end
  end
```

- [ ] **Step 4: テスト実行（緑を確認）**

Run: `bundle exec rspec spec/models/user_spec.rb -e "email_enabled"`
Expected: PASS（DB 既定 false ゆえ実装不要・列追加で緑）。

- [ ] **Step 5: SPEC §4.17 の不整合解消**

`docs/SPEC.md` の §4.17 UserNotificationPreference テーブルから `email_enabled` 行を削除し、表の直後に注記を追加。該当の現行行:

```markdown
| email_enabled | boolean | 個人メール opt-in（組織側が true のときのみ有効・二重 opt-in） |
```

を削除し、§4.17 の表の下に以下を追記:

```markdown
> **email_enabled は本テーブルに持たない（4-1a で確定）:** 個人メール opt-in は `User.email_enabled`（§4.4）が SSOT。本テーブルは抑制系（quiet hours / 休日ブロック）のみを個人上書きとして持つ。組織フラグ `email_notification_enabled`（§4.15）との AND ゲートであり、組織設定への fallback を持つ抑制系とは意味論が異なるため分離する。
```

- [ ] **Step 6: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion db/migrate/<ts>_add_email_enabled_to_users.rb spec/models/user_spec.rb
git checkout -- db/queue_schema.rb 2>/dev/null || true
git add db/migrate/<ts>_add_email_enabled_to_users.rb db/schema.rb docs/SPEC.md spec/models/user_spec.rb
git commit -m "$(cat <<'EOF'
feat: users.email_enabled 追加 + SPEC §4.17 不整合解消（4-1a）

個人メール opt-in の SSOT を users 列に確定（設計判断 B）。
§4.17 UserNotificationPreference の重複 email_enabled を削除。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: organization_settings 抑制/opt-in 5 列

4-1 が消費する 5 列のみ追加（閾値系・36 協定系は消費 Phase が同梱・§4.15 注記の YAGNI）。`Organization#setting` の lazy 生成は DB 既定値を使うためモデル変更不要だが、時刻列に妥当性検証を足す。

**Files:**
- Create: `db/migrate/<ts>_add_notification_columns_to_organization_settings.rb`
- Modify: `app/models/organization_setting.rb`
- Test: `spec/models/organization_setting_spec.rb`（新規 or 既存に追記）

**Interfaces:**
- Produces: `OrganizationSetting#quiet_hours_enabled / #quiet_hours_start / #quiet_hours_end / #holiday_block_enabled / #email_notification_enabled`。4-1b の SuppressionWindow・二重 opt-in が `Organization#setting` 経由で読む。

- [ ] **Step 1: migration 生成 + body 差し替え**

```bash
bin/rails generate migration AddNotificationColumnsToOrganizationSettings
```

body 全置換:

```ruby
# frozen_string_literal: true

class AddNotificationColumnsToOrganizationSettings < ActiveRecord::Migration[8.1]
  def change
    # 通知抑制・二重 opt-in の組織側（SPEC §4.15）。4-1 が消費する 5 列のみ追加。
    # 閾値系・36 協定系は消費する Phase の PR が同梱（§4.15 注記）
    add_column :organization_settings, :quiet_hours_enabled, :boolean, null: false, default: true
    add_column :organization_settings, :quiet_hours_start, :integer, null: false, default: 19 # 時（0..23）
    add_column :organization_settings, :quiet_hours_end, :integer, null: false, default: 8    # 時（0..23）
    add_column :organization_settings, :holiday_block_enabled, :boolean, null: false, default: true
    add_column :organization_settings, :email_notification_enabled, :boolean, null: false, default: false # 二重 opt-in 組織側
  end
end
```

- [ ] **Step 2: migrate 実行**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: 5 列追加で schema.rb 自動更新。

- [ ] **Step 3: 失敗するテストを書く**

`spec/models/organization_setting_spec.rb`（無ければ新規作成）:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrganizationSetting do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  describe "通知列の lazy 既定（§4.15）" do
    it "Organization#setting が抑制/opt-in の既定値を返す" do
      setting = org.setting
      expect(setting.quiet_hours_enabled).to be(true)
      expect(setting.quiet_hours_start).to eq(19)
      expect(setting.quiet_hours_end).to eq(8)
      expect(setting.holiday_block_enabled).to be(true)
      expect(setting.email_notification_enabled).to be(false)
    end
  end

  describe "quiet hours の時刻範囲検証（0..23）" do
    it "0..23 の外は無効" do
      setting = org.setting
      setting.quiet_hours_start = 24
      expect(setting).to be_invalid
      setting.quiet_hours_start = -1
      expect(setting).to be_invalid
    end

    it "0 と 23 は有効" do
      setting = org.setting
      setting.quiet_hours_start = 0
      setting.quiet_hours_end = 23
      expect(setting).to be_valid
    end
  end
end
```

- [ ] **Step 4: テスト実行（lazy 既定は緑・検証は赤を確認）**

Run: `bundle exec rspec spec/models/organization_setting_spec.rb`
Expected: lazy 既定 PASS、時刻範囲検証は FAIL（検証未実装）。

- [ ] **Step 5: モデルに検証を追加**

`app/models/organization_setting.rb` の既存 validates 群の後に追記:

```ruby
  validates :quiet_hours_start, :quiet_hours_end, inclusion: { in: 0..23 } # 時（SPEC §4.15）
```

- [ ] **Step 6: テスト実行（緑を確認）**

Run: `bundle exec rspec spec/models/organization_setting_spec.rb`
Expected: 全 PASS。

- [ ] **Step 7: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion db/migrate/<ts>_add_notification_columns_to_organization_settings.rb app/models/organization_setting.rb spec/models/organization_setting_spec.rb
git checkout -- db/queue_schema.rb 2>/dev/null || true
git add db/migrate/<ts>_add_notification_columns_to_organization_settings.rb db/schema.rb app/models/organization_setting.rb spec/models/organization_setting_spec.rb
git commit -m "$(cat <<'EOF'
feat: organization_settings 抑制/opt-in 5 列（4-1a）

quiet hours / 休日ブロック / 組織メール opt-in（SPEC §4.15）。
4-1 が消費する分のみ追加。時刻は 0..23 検証。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: UserNotificationPreference（個人の抑制設定）

1 ユーザー 1 行（任意）。無ければ OrganizationSetting にフォールバック（読み取りは 4-1b）。email_enabled は持たない（判断 B）。

**Files:**
- Create: `db/migrate/<ts>_create_user_notification_preferences.rb`
- Create: `app/models/user_notification_preference.rb`
- Create: `spec/factories/user_notification_preferences.rb`
- Modify: `app/models/user.rb`（`has_one :notification_preference`）
- Test: `spec/models/user_notification_preference_spec.rb`

**Interfaces:**
- Consumes: `users(organization_id, id)` 複合 unique index（既存）。
- Produces: `UserNotificationPreference`（`belongs_to :user`・quiet_hours_enabled / _start / _end / holiday_block_enabled）。`User#notification_preference`。

- [ ] **Step 1: migration 生成 + body 差し替え**

```bash
bin/rails generate migration CreateUserNotificationPreferences
```

body 全置換:

```ruby
# frozen_string_literal: true

class CreateUserNotificationPreferences < ActiveRecord::Migration[8.1]
  def change
    create_table :user_notification_preferences do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.boolean :quiet_hours_enabled, null: false, default: true
      t.integer :quiet_hours_start, null: false, default: 19 # 時（0..23）
      t.integer :quiet_hours_end, null: false, default: 8     # 時（0..23）
      t.boolean :holiday_block_enabled, null: false, default: true
      t.timestamps
    end

    # クロステナント参照を DB 層で遮断（§3.6 複合 FK）
    add_foreign_key :user_notification_preferences, :users,
                    column: %i[organization_id user_id], primary_key: %i[organization_id id]

    add_index :user_notification_preferences, %i[organization_id id], unique: true # 規約（将来の複合 FK 参照先）
    # 1 ユーザー 1 行（テナント内）— DB 最終防衛
    add_index :user_notification_preferences, %i[organization_id user_id],
              unique: true, name: "index_user_notification_preferences_unique"
  end
end
```

- [ ] **Step 2: migrate 実行**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: テーブル作成・schema.rb 自動更新。

- [ ] **Step 3: 失敗するテストを書く**

`spec/factories/user_notification_preferences.rb`:

```ruby
# frozen_string_literal: true

FactoryBot.define do
  factory :user_notification_preference do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    user { association(:user) }
    quiet_hours_enabled { true }
    quiet_hours_start { 19 }
    quiet_hours_end { 8 }
    holiday_block_enabled { true }
  end
end
```

`spec/models/user_notification_preference_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe UserNotificationPreference do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def in_savepoint = ActiveRecord::Base.transaction(requires_new: true) { yield }

  describe "1 ユーザー 1 行（テナント内一意）" do
    it "同一 user の 2 行目はモデル検証で無効" do
      first = create(:user_notification_preference)
      dup = build(:user_notification_preference, user: first.user)
      expect(dup).to be_invalid
    end

    it "別テナントなら同一 user_id でも valid（鏡像）" do
      create(:user_notification_preference)
      other = create(:organization)
      ActsAsTenant.with_tenant(other) do
        u = create(:user, organization: other)
        mirror = build(:user_notification_preference, organization: other, user: u)
        expect(mirror).to be_valid
      end
    end

    it "DB 最終防衛: validate:false でも複合 unique を弾く" do
      first = create(:user_notification_preference)
      expect {
        in_savepoint do
          build(:user_notification_preference, user: first.user).save!(validate: false)
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "時刻範囲（0..23）" do
    it "範囲外は無効" do
      pref = build(:user_notification_preference, quiet_hours_start: 24)
      expect(pref).to be_invalid
    end
  end

  describe "同一組織検証（§3.6）" do
    it "他テナントの user は DB 複合 FK で拒否（validate:false）" do
      other = create(:organization)
      foreign_user = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
      expect {
        in_savepoint do
          pref = build(:user_notification_preference)
          pref.user_id = foreign_user.id # org は自テナントのまま user_id だけ越境
          pref.save!(validate: false)
        end
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "他テナントの user はモデル検証でも無効（fail-closed）" do
      other = create(:organization)
      foreign_user = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
      pref = build(:user_notification_preference)
      pref.user_id = foreign_user.id
      expect(pref).to be_invalid
    end
  end
end
```

- [ ] **Step 4: テスト実行（赤を確認）**

Run: `bundle exec rspec spec/models/user_notification_preference_spec.rb`
Expected: FAIL（`UserNotificationPreference` 未定義）。

- [ ] **Step 5: モデル実装**

`app/models/user_notification_preference.rb`:

```ruby
# frozen_string_literal: true

# 個人の通知抑制設定（SPEC §4.17）。1 ユーザー 1 行・任意（無ければ OrganizationSetting にフォールバック）。
# email_enabled は持たない（個人メール opt-in は User.email_enabled が SSOT・設計判断 B）。
class UserNotificationPreference < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :user

  validates_uniqueness_to_tenant :user_id
  validates :quiet_hours_start, :quiet_hours_end, inclusion: { in: 0..23 } # 時（§4.15）
  validate :user_must_belong_to_same_organization

  private

  # ID 基点 fail-closed（leave_balance.rb 同型・§3.6）。複合 FK と二層で守る
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id

    errors.add(:user, "は同一組織でなければなりません")
  end
end
```

`app/models/user.rb` の関連定義群（`has_many :leave_balances` 付近）に追記:

```ruby
  has_one :notification_preference, class_name: "UserNotificationPreference", dependent: :destroy
```

- [ ] **Step 6: テスト実行（緑を確認）**

Run: `bundle exec rspec spec/models/user_notification_preference_spec.rb`
Expected: 全 PASS。

- [ ] **Step 7: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion db/migrate/<ts>_create_user_notification_preferences.rb app/models/user_notification_preference.rb app/models/user.rb spec/factories/user_notification_preferences.rb spec/models/user_notification_preference_spec.rb
git checkout -- db/queue_schema.rb 2>/dev/null || true
git add db/migrate/<ts>_create_user_notification_preferences.rb db/schema.rb app/models/user_notification_preference.rb app/models/user.rb spec/factories/user_notification_preferences.rb spec/models/user_notification_preference_spec.rb
git commit -m "$(cat <<'EOF'
feat: UserNotificationPreference（個人抑制設定・4-1a）

1 ユーザー 1 行・複合 FK + 同一組織検証の二重防御（§3.6）。
email_enabled は持たない（User.email_enabled が SSOT）。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Notification（ベル通知の実体）

**Files:**
- Create: `db/migrate/<ts>_create_notifications.rb`
- Create: `app/models/notification.rb`
- Create: `spec/factories/notifications.rb`
- Modify: `app/models/user.rb`（`has_many :notifications`）
- Test: `spec/models/notification_spec.rb`

**Interfaces:**
- Consumes: `users(organization_id, id)` 複合 unique（既存）。
- Produces: `Notification`（`belongs_to :target_user, :subject_user`・enum `priority` {action_required:0, informational:1, reference:2}・enum `source_type` {request_approved:0, request_rejected:1}・`read_at`・`scope :unread`）。4-1b の Notifier が作成、4-1c のベルが読む。Task 5 が `notifications(organization_id, id)` を複合 FK で参照。

- [ ] **Step 1: migration 生成 + body 差し替え**

```bash
bin/rails generate migration CreateNotifications
```

body 全置換:

```ruby
# frozen_string_literal: true

class CreateNotifications < ActiveRecord::Migration[8.1]
  def change
    create_table :notifications do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :target_user_id, null: false  # 通知先
      t.bigint :subject_user_id              # 通知対象者（重複制御キー・null 可）
      t.string :title, null: false
      t.text :body, null: false
      t.integer :priority, null: false       # enum: action_required:0 / informational:1 / reference:2
      t.integer :source_type, null: false    # enum: request_approved:0 / request_rejected:1
      t.timestamptz :read_at                  # 既読時刻（null = 未読）
      t.timestamps
    end

    # クロステナント参照を DB 層で遮断（§3.6 複合 FK）
    add_foreign_key :notifications, :users,
                    column: %i[organization_id target_user_id], primary_key: %i[organization_id id]
    add_foreign_key :notifications, :users,
                    column: %i[organization_id subject_user_id], primary_key: %i[organization_id id]

    add_index :notifications, %i[organization_id id], unique: true # 規約（NotificationDelivery が複合 FK で参照）
    add_index :notifications, %i[organization_id target_user_id read_at],
              name: "index_notifications_target_unread" # 未読絞り込み
  end
end
```

- [ ] **Step 2: migrate 実行**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: テーブル作成・schema.rb 自動更新。

- [ ] **Step 3: 失敗するテストを書く**

`spec/factories/notifications.rb`:

```ruby
# frozen_string_literal: true

FactoryBot.define do
  factory :notification do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    target_user { association(:user) }
    subject_user { nil }
    title { "申請が承認されました" }
    body { "あなたの休暇申請が承認されました。" }
    priority { :informational }
    source_type { :request_approved }
  end
end
```

`spec/models/notification_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notification do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def in_savepoint = ActiveRecord::Base.transaction(requires_new: true) { yield }

  describe "enum" do
    it "priority / source_type を取りうる" do
      n = build(:notification, priority: :action_required, source_type: :request_rejected)
      expect(n).to be_valid
      expect(n.action_required?).to be(true)
      expect(n.request_rejected?).to be(true)
    end
  end

  describe "scope :unread" do
    it "read_at nil のみ返す" do
      unread = create(:notification, read_at: nil)
      create(:notification, read_at: Time.current)
      expect(described_class.unread).to contain_exactly(unread)
    end
  end

  describe "subject_user は任意（null 可）" do
    it "subject_user なしで valid" do
      expect(build(:notification, subject_user: nil)).to be_valid
    end
  end

  describe "同一組織検証（§3.6・§9④）" do
    it "他テナントの target_user は DB 複合 FK で拒否（validate:false）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
      expect {
        in_savepoint do
          n = build(:notification)
          n.target_user_id = foreign.id
          n.save!(validate: false)
        end
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "他テナントの target_user はモデル検証でも無効（fail-closed）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
      n = build(:notification)
      n.target_user_id = foreign.id
      expect(n).to be_invalid
    end

    it "他テナントの subject_user はモデル検証で無効" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) { create(:user, organization: other) }
      n = build(:notification)
      n.subject_user_id = foreign.id
      expect(n).to be_invalid
    end
  end
end
```

- [ ] **Step 4: テスト実行（赤を確認）**

Run: `bundle exec rspec spec/models/notification_spec.rb`
Expected: FAIL（`Notification` 未定義）。

- [ ] **Step 5: モデル実装**

`app/models/notification.rb`:

```ruby
# frozen_string_literal: true

# ベル通知の実体（SPEC §4.18）。配信監査は NotificationDelivery（email 専用）。
# 状態機械は持たない（read_at の有無のみ・遅延/リトライは SolidQueue が正・§4.18 注記）。
class Notification < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :target_user, class_name: "User"
  belongs_to :subject_user, class_name: "User", optional: true
  has_many :notification_deliveries, dependent: :destroy

  enum :priority, { action_required: 0, informational: 1, reference: 2 }, validate: true
  # 後続 Phase が値を追加（integer enum ゆえ model 編集のみ・append-only）
  enum :source_type, { request_approved: 0, request_rejected: 1 }, validate: true

  validates :title, :body, presence: true
  validate :target_user_must_belong_to_same_organization
  validate :subject_user_must_belong_to_same_organization

  scope :unread, -> { where(read_at: nil) }

  private

  # ID 基点 fail-closed（leave_balance.rb 同型・§3.6・複合 FK と二層）
  def target_user_must_belong_to_same_organization
    return if target_user_id.nil?
    return if target_user&.organization_id == organization_id

    errors.add(:target_user, "は同一組織でなければなりません")
  end

  # optional ゆえ nil は早期 return
  def subject_user_must_belong_to_same_organization
    return if subject_user_id.nil?
    return if subject_user&.organization_id == organization_id

    errors.add(:subject_user, "は同一組織でなければなりません")
  end
end
```

`app/models/user.rb` の関連定義群に追記（Task 3 の `has_one :notification_preference` の近く）:

```ruby
  has_many :notifications, foreign_key: :target_user_id, inverse_of: :target_user, dependent: :destroy
```

- [ ] **Step 6: テスト実行（緑を確認）**

Run: `bundle exec rspec spec/models/notification_spec.rb`
Expected: 全 PASS。

- [ ] **Step 7: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion db/migrate/<ts>_create_notifications.rb app/models/notification.rb app/models/user.rb spec/factories/notifications.rb spec/models/notification_spec.rb
git checkout -- db/queue_schema.rb 2>/dev/null || true
git add db/migrate/<ts>_create_notifications.rb db/schema.rb app/models/notification.rb app/models/user.rb spec/factories/notifications.rb spec/models/notification_spec.rb
git commit -m "$(cat <<'EOF'
feat: Notification モデル（ベル通知の実体・4-1a）

priority/source_type enum・scope :unread・target/subject_user の
同一組織検証（複合 FK + model 二重防御・§3.6・§9④）。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: NotificationDelivery（email 配信監査記録）

email 配信の監査記録（いつ・どの channel に送ったか）+ 抑制キュー。独立状態機械は持たず status は SolidQueue 結果の反映（§4.18 注記）。

**Files:**
- Create: `db/migrate/<ts>_create_notification_deliveries.rb`
- Create: `app/models/notification_delivery.rb`
- Create: `spec/factories/notification_deliveries.rb`
- Test: `spec/models/notification_delivery_spec.rb`

**Interfaces:**
- Consumes: `notifications(organization_id, id)` 複合 unique（Task 4）。`Notification#notification_deliveries`（Task 4 で定義済）。
- Produces: `NotificationDelivery`（`belongs_to :notification`・enum `channel` {in_app:0, email:1}・enum `status` {pending:0, sent:1, error:2}・`scheduled_at`・`retry_count`）。4-1b の Notifier が作成・Dispatch/Email ジョブが更新。

- [ ] **Step 1: migration 生成 + body 差し替え**

```bash
bin/rails generate migration CreateNotificationDeliveries
```

body 全置換:

```ruby
# frozen_string_literal: true

class CreateNotificationDeliveries < ActiveRecord::Migration[8.1]
  def change
    create_table :notification_deliveries do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :notification_id, null: false
      t.integer :channel, null: false                 # enum: in_app:0 / email:1（実質 email のみ生成）
      t.timestamptz :scheduled_at, null: false        # 抑制終了後の送信予定
      t.integer :status, null: false, default: 0       # enum: pending:0 / sent:1 / error:2
      t.integer :retry_count, null: false, default: 0  # >3 で error 確定（§9.5・監査ミラー）
      t.timestamps
    end

    # クロステナント参照を DB 層で遮断（§3.6 複合 FK）
    add_foreign_key :notification_deliveries, :notifications,
                    column: %i[organization_id notification_id], primary_key: %i[organization_id id]

    add_index :notification_deliveries, %i[organization_id id], unique: true # 規約
    add_index :notification_deliveries, %i[organization_id status scheduled_at],
              name: "index_notification_deliveries_sweep" # sweep（pending かつ scheduled_at<=now）用
  end
end
```

- [ ] **Step 2: migrate 実行**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: テーブル作成・schema.rb 自動更新。

- [ ] **Step 3: 失敗するテストを書く**

`spec/factories/notification_deliveries.rb`:

```ruby
# frozen_string_literal: true

FactoryBot.define do
  factory :notification_delivery do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    notification { association(:notification) }
    channel { :email }
    scheduled_at { Time.current }
    status { :pending }
    retry_count { 0 }
  end
end
```

`spec/models/notification_delivery_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationDelivery do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def in_savepoint = ActiveRecord::Base.transaction(requires_new: true) { yield }

  describe "enum と既定" do
    it "channel / status を取り、既定は pending / retry_count 0" do
      d = create(:notification_delivery)
      expect(d.email?).to be(true)
      expect(d.pending?).to be(true)
      expect(d.retry_count).to eq(0)
    end
  end

  describe "同一組織検証（§3.6・§9④）" do
    it "他テナントの notification は DB 複合 FK で拒否（validate:false）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:notification, organization: other, target_user: create(:user, organization: other))
      end
      expect {
        in_savepoint do
          d = build(:notification_delivery)
          d.notification_id = foreign.id
          d.save!(validate: false)
        end
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "他テナントの notification はモデル検証でも無効（fail-closed）" do
      other = create(:organization)
      foreign = ActsAsTenant.with_tenant(other) do
        create(:notification, organization: other, target_user: create(:user, organization: other))
      end
      d = build(:notification_delivery)
      d.notification_id = foreign.id
      expect(d).to be_invalid
    end
  end
end
```

- [ ] **Step 4: テスト実行（赤を確認）**

Run: `bundle exec rspec spec/models/notification_delivery_spec.rb`
Expected: FAIL（`NotificationDelivery` 未定義）。

- [ ] **Step 5: モデル実装**

`app/models/notification_delivery.rb`:

```ruby
# frozen_string_literal: true

# email 配信の監査記録 + 抑制キュー（SPEC §4.18）。
# 独立状態機械は持たない — status は SolidQueue ジョブ結果の反映（遅延/リトライは SolidQueue が正）。
class NotificationDelivery < ApplicationRecord
  acts_as_tenant(:organization)

  belongs_to :notification

  enum :channel, { in_app: 0, email: 1 }, validate: true
  enum :status, { pending: 0, sent: 1, error: 2 }, validate: true

  validates :scheduled_at, presence: true
  validate :notification_must_belong_to_same_organization

  private

  # ID 基点 fail-closed（§3.6・複合 FK と二層）
  def notification_must_belong_to_same_organization
    return if notification_id.nil?
    return if notification&.organization_id == organization_id

    errors.add(:notification, "は同一組織でなければなりません")
  end
end
```

- [ ] **Step 6: テスト実行（緑を確認）**

Run: `bundle exec rspec spec/models/notification_delivery_spec.rb`
Expected: 全 PASS。

- [ ] **Step 7: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion db/migrate/<ts>_create_notification_deliveries.rb app/models/notification_delivery.rb spec/factories/notification_deliveries.rb spec/models/notification_delivery_spec.rb
git checkout -- db/queue_schema.rb 2>/dev/null || true
git add db/migrate/<ts>_create_notification_deliveries.rb db/schema.rb app/models/notification_delivery.rb spec/factories/notification_deliveries.rb spec/models/notification_delivery_spec.rb
git commit -m "$(cat <<'EOF'
feat: NotificationDelivery モデル（email 配信監査・4-1a）

channel/status enum・notification の同一組織検証（複合 FK + model）。
独立状態機械は持たない（SolidQueue が正・§4.18）。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: leave_requests.last_stale_notified_on（CCR との非対称解消）

SPEC §4.9 は LeaveRequest に `last_stale_notified_on` を記載するが schema には CCR 側（§4.11）にしか無い。消費（滞留アラート §7.5）は 4-2 だが、ROADMAP backlog #113 の指定どおりここで非対称を解消する（4-1 側に検証/ロジックは掛けない）。

**Files:**
- Create: `db/migrate/<ts>_add_last_stale_notified_on_to_leave_requests.rb`
- Test: `spec/models/leave_request_spec.rb`（既存に example 追記）

**Interfaces:**
- Produces: `LeaveRequest#last_stale_notified_on`（date・null 可）。4-2 の滞留アラートが重複防止に読む。

- [ ] **Step 1: migration 生成 + body 差し替え**

```bash
bin/rails generate migration AddLastStaleNotifiedOnToLeaveRequests
```

body 全置換:

```ruby
# frozen_string_literal: true

class AddLastStaleNotifiedOnToLeaveRequests < ActiveRecord::Migration[8.1]
  def change
    # 承認滞留アラートの重複防止（SPEC §4.9）。CCR §4.11 との非対称解消（ROADMAP #113）。
    # 消費は 4-2（滞留アラート §7.5）— 本スライスは列のみ・検証/ロジックは掛けない
    add_column :leave_requests, :last_stale_notified_on, :date
  end
end
```

- [ ] **Step 2: migrate 実行**

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: 列追加・schema.rb 自動更新。

- [ ] **Step 3: 失敗するテストを書く**

`spec/models/leave_request_spec.rb` に追記（既存の describe 構造に合わせる）:

```ruby
  describe "last_stale_notified_on（滞留アラート重複防止・§4.9）" do
    it "既定は nil・date を保持できる" do
      lr = create(:leave_request)
      expect(lr.last_stale_notified_on).to be_nil
      lr.update!(last_stale_notified_on: Date.current)
      expect(lr.reload.last_stale_notified_on).to eq(Date.current)
    end
  end
```

> 注: `:leave_request` factory の必須属性が揃っているか確認。揃わず作成失敗する場合は既存 leave_request_spec の `let`/factory 利用法に合わせて最小構成で生成する（本タスクは列の存在確認が目的ゆえ、既存 spec が使う生成パターンを踏襲する）。

- [ ] **Step 4: テスト実行（緑を確認）**

Run: `bundle exec rspec spec/models/leave_request_spec.rb -e "last_stale_notified_on"`
Expected: PASS（列追加のみ・実装不要）。

- [ ] **Step 5: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion db/migrate/<ts>_add_last_stale_notified_on_to_leave_requests.rb spec/models/leave_request_spec.rb
git checkout -- db/queue_schema.rb 2>/dev/null || true
git add db/migrate/<ts>_add_last_stale_notified_on_to_leave_requests.rb db/schema.rb spec/models/leave_request_spec.rb
git commit -m "$(cat <<'EOF'
feat: leave_requests.last_stale_notified_on（CCR 非対称解消・4-1a）

SPEC §4.9 記載だが schema 欠落（CCR §4.11 のみ）を解消（ROADMAP #113）。
消費は 4-2 滞留アラート — 本スライスは列のみ。

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: スライス仕上げ（全 spec + ROADMAP + tenant レビュー）

**Files:**
- Modify: `docs/ROADMAP.md`（4-1 行の進捗注記）

- [ ] **Step 1: 全スイート緑を確認**

Run: `bundle exec rspec`
Expected: 全 PASS（既存テストの回帰なし）。回帰があれば原因を切り分けて修正（本スライスはデータ層追加ゆえ既存への影響は最小のはず）。

- [ ] **Step 2: rubocop 全体 + brakeman**

Run: `bundle exec rubocop --force-exclusion` および `bin/brakeman --no-pager`
Expected: rubocop no offenses・brakeman 新規警告なし。

- [ ] **Step 3: ROADMAP に 4-1a 進捗を注記**

`docs/ROADMAP.md` の Phase 4 `4-1 通知基盤` 行に、サブスライス進行中の注記を追加（行は `[ ]` のまま・4-1c 完了で `[x]` + PR 番号）。例:

```markdown
- [ ] **4-1 通知基盤**: ...（既存文）... ／ **進行中**: 4-1a データ層（Notification/NotificationDelivery/UserNotificationPreference・org_settings 抑制列・User.email_enabled・LeaveRequest 非対称解消）
```

- [ ] **Step 4: db/queue_schema.rb の混入チェック + commit**

```bash
git checkout -- db/queue_schema.rb 2>/dev/null || true
git status --short
git add docs/ROADMAP.md
git commit -m "$(cat <<'EOF'
docs: ROADMAP に 4-1a データ層の進行を注記

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
EOF
)"
```

- [ ] **Step 5: tenant-isolation-reviewer を回す**

models / migrations に触れたため、merge 前に `tenant-isolation-reviewer` サブエージェントで複合 FK・同一組織検証・acts_as_tenant 付与漏れを検証。指摘があれば修正コミットを足す。

- [ ] **Step 6: PR 作成（`/preflight` 後）**

`/preflight` で CI 等価チェックを通してから `gh pr create`（`gh auth switch -u kei1110` 確認）。PR 本文末尾に `🤖 Generated with [Claude Code](https://claude.com/claude-code)`。

---

## Self-Review（plan ↔ spec 突合）

**1. Spec coverage（設計 §3 データモデル）:**
- users.email_enabled → Task 1 ✅ / org_settings 5 列 → Task 2 ✅ / UserNotificationPreference → Task 3 ✅ / Notification → Task 4 ✅ / NotificationDelivery → Task 5 ✅ / leave_requests.last_stale_notified_on → Task 6 ✅
- §9④ 同一組織検証 → Task 3/4/5 の `*_must_belong_to_same_organization` ✅
- §9⑬ テスト負例（同一組織 FK 拒否・uniqueness・enum・unread・lazy 既定）→ 各 Task の spec ✅
- SPEC §4.17 不整合解消 → Task 1 ✅
- enum 値（priority/source_type/channel/status）→ Task 4/5 ✅

**範囲外（4-1b/4-1c ゆえ本 plan に無くて正）:** Notifier・SuppressionWindow・jobs・mailer（4-1b）/ ベル・controller・policy・通知設定・producer 接続・§1.4 行（4-1c）/ `Organization.active` scope（4-1b のディスパッチャが要求・§9⑩）。

**2. Placeholder scan:** "TBD"/"後で" なし。Task 6 Step 3 の factory 注記は「既存パターンに合わせる」具体指示で placeholder ではない。

**3. Type consistency:** enum 名（`action_required`/`informational`/`reference`/`request_approved`/`request_rejected`/`in_app`/`email`/`pending`/`sent`/`error`）は Task 4/5 のモデルと factory・spec で一致。複合 FK の column 順 `%i[organization_id xxx_id]` と primary_key `%i[organization_id id]` は全 migration で一致。`User#notification_preference`（Task 3）・`User#notifications`（Task 4）・`Notification#notification_deliveries`（Task 4）の関連名は Task 5 factory の `notification` 参照と整合。

> 依存順序: Task 4（notifications）は Task 5（notification_deliveries の複合 FK 参照先）より先。Task 1-2-3-4-5-6 の順で実行する。
