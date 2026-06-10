# Phase 0a（基盤）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rails 8 アプリの骨格（マルチテナント・認証・認可・CI）を構築し、seed 組織でログインして最小ホームに到達できる「動く骨格」を、テナント分離の E2E 検証付きで完成させる。

**Architecture:** acts_as_tenant（`require_tenant = true`）＋サブドメイン解決の fail-closed 構造の上に、Devise を validatable 抜きで載せてテナントスコープ化し、テナント整合突合を Warden `after_set_user` の一点に置く。spec は `docs/superpowers/specs/2026-06-10-phase0a-foundation-design.md`（以下「設計」）。

**Tech Stack:** Rails 8 / PostgreSQL 17 / acts_as_tenant / Devise / Pundit / Tailwind / RSpec + FactoryBot + Capybara + pundit-matchers / GitHub Actions

**前提:** Ruby 3.3.11（rbenv・`.ruby-version` 済み）、DB `gatcha_development`/`gatcha_test` 作成済み、main 保護 Ruleset（id 17476200）適用済み。作業ブランチは `feat/app-foundation`（main から作成）。PR は本計画全体で 1 本（CI bootstrap を兼ねるため）。push 前に `/preflight`。

---

## File Structure（最終形の主要部）

```text
app/
├── controllers/
│   ├── application_controller.rb   # テナント解決・Pundit 強制・Devise 連携
│   └── home_controller.rb          # 最小ホーム
├── mailers/
│   └── tenant_devise_mailer.rb     # サブドメイン込み URL のメール
├── models/
│   ├── organization.rb             # テナントルート
│   └── user.rb                     # Devise（validatable 抜き）+ role + manager
├── policies/
│   ├── application_policy.rb       # 既定 deny
│   └── home_policy.rb
└── views/home/show.html.erb
config/initializers/
├── acts_as_tenant.rb               # require_tenant = true
├── devise.rb                       # paranoid・mailer・lockable 設定（生成物を編集）
└── warden_tenant_guard.rb          # 整合突合の一点防御
db/
├── migrate/*_create_organizations.rb
├── migrate/*_devise_create_users.rb # 全カラム・複合 unique・複合 FK
└── seeds.rb                        # env ガード付き
spec/
├── support/{factory_bot,tenant,capybara}.rb
├── factories/{organizations,users}.rb
├── models/{organization,user}_spec.rb
├── requests/{tenant_resolution,authentication,password_reset,pundit_enforcement}_spec.rb
├── controllers/application_controller_spec.rb  # authorize 漏れ検知
└── system/tenant_isolation_spec.rb
.github/workflows/ci.yml            # lint / security / test
```

---

### Task 1: rails new とリポジトリ統合

**Files:**
- Create: Rails 8 標準生成物一式
- Modify: `.gitignore`（生成物に既存エントリを再マージ）

- [ ] **Step 1: 既存ファイルを退避**

```bash
cd /Users/Eoh/workspace/Gatcha_on_RoR
cp .gitignore /tmp/gitignore.orig
```

- [ ] **Step 2: Rails をインストールして rails new**

```bash
gem install rails --no-document
rails new . --name=gatcha --database=postgresql --css=tailwind \
  --skip-test --skip-jbuilder --skip-kamal --skip-thruster --force
```

`--force` は既存 `.gitignore`/`README.md` を上書きする。`--name=gatcha` でモジュール `Gatcha`・DB 名 `gatcha_*` が既存 DB と一致する（設計 §1）。

- [ ] **Step 3: 上書きされたファイルを復元・マージ**

```bash
git status --short | head -30
git restore README.md CLAUDE.md 2>/dev/null || true
diff /tmp/gitignore.orig .gitignore
```

diff で消えた既存エントリ（`.claude/settings.local.json` 等）があれば、生成された `.gitignore` の末尾に追記する。

- [ ] **Step 4: DB 接続と起動を確認**

```bash
bin/rails db:prepare
bin/rails runner 'puts ActiveRecord::Base.connection.database_version'
```

Expected: PostgreSQL のバージョン文字列（17.x）。失敗時は `config/database.yml` の接続先を確認（DB 名は `gatcha_development`/`gatcha_test` になっているはず）。

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: rails new --name=gatcha（Rails 8 / Postgres / Tailwind）"
```

---

### Task 2: テスト基盤（RSpec / FactoryBot / Capybara）

**Files:**
- Modify: `Gemfile`
- Create: `spec/rails_helper.rb`（生成後編集）, `spec/support/factory_bot.rb`, `spec/support/capybara.rb`

- [ ] **Step 1: Gemfile に追記**

```ruby
group :development, :test do
  gem "rspec-rails"
  gem "factory_bot_rails"
end

group :test do
  gem "capybara"
  gem "pundit-matchers"
end
```

（既存の `group :development, :test` ブロックに統合してよい）

- [ ] **Step 2: インストールと rspec:install**

```bash
bundle install
bin/rails generate rspec:install
```

- [ ] **Step 3: rails_helper の support 読み込みを有効化**

`spec/rails_helper.rb` のコメントアウトを外す:

```ruby
Rails.root.glob("spec/support/**/*.rb").sort_by(&:to_s).each { |f| require f }
```

- [ ] **Step 4: support ファイルを作成**

`spec/support/factory_bot.rb`:

```ruby
RSpec.configure do |config|
  config.include FactoryBot::Syntax::Methods
end
```

`spec/support/capybara.rb`:

```ruby
RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :rack_test # 0a の system spec は JS 不要。CI に Chrome も不要になる
  end
end
```

- [ ] **Step 5: 動作確認**

```bash
bundle exec rspec
```

Expected: `0 examples, 0 failures`

- [ ] **Step 6: Commit**

```bash
git add Gemfile Gemfile.lock .rspec spec/
git commit -m "feat: RSpec / FactoryBot / Capybara のテスト基盤を導入"
```

---

### Task 3: CI ワークフロー

**Files:**
- Modify（生成物を全面書換え）: `.github/workflows/ci.yml`

- [ ] **Step 1: ci.yml を書く**

`--skip-test` 生成の ci.yml には test job が無い（設計 §2）。全面的に置き換える:

```yaml
name: CI

on:
  pull_request:
  push:
    branches: [main]

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - run: bin/rubocop -f github

  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - run: bin/brakeman --no-pager

  test:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:17
        env:
          POSTGRES_USER: postgres
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd="pg_isready" --health-interval=10s
          --health-timeout=5s --health-retries=3
    env:
      RAILS_ENV: test
      DATABASE_URL: postgres://postgres:postgres@localhost:5432/gatcha_test
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - run: bin/rails db:test:prepare
      - run: bundle exec rspec
```

job 名 `lint` / `security` / `test` は後で required status checks に登録する context 名になる（Task 14）。

- [ ] **Step 2: ローカルで等価チェック**

```bash
bin/rubocop && bin/brakeman --no-pager && bundle exec rspec
```

Expected: すべて成功（rubocop の自動修正が要る場合は `bin/rubocop -a`）。

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: lint / security / test の 3 job 構成に整備（RSpec + Postgres 17）"
```

---

### Task 4: Organization と acts_as_tenant 基盤

**Files:**
- Modify: `Gemfile`
- Create: `db/migrate/*_create_organizations.rb`, `app/models/organization.rb`, `config/initializers/acts_as_tenant.rb`, `spec/factories/organizations.rb`, `spec/support/tenant.rb`, `spec/models/organization_spec.rb`

- [ ] **Step 1: gem 追加**

```ruby
gem "acts_as_tenant"
```

```bash
bundle install
```

- [ ] **Step 2: failing test を書く**

`spec/models/organization_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Organization, type: :model do
  it "is valid with name and subdomain" do
    expect(build(:organization)).to be_valid
  end

  it "requires globally unique subdomain" do
    create(:organization, subdomain: "acme")
    expect(build(:organization, subdomain: "acme")).not_to be_valid
  end

  it "rejects invalid subdomain format" do
    expect(build(:organization, subdomain: "Bad_Sub!")).not_to be_valid
  end

  it "enforces subdomain uniqueness at DB level" do
    create(:organization, subdomain: "acme")
    dup = build(:organization, subdomain: "acme")
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end
end
```

`spec/factories/organizations.rb`:

```ruby
FactoryBot.define do
  factory :organization do
    sequence(:name) { |n| "Org #{n}" }
    sequence(:subdomain) { |n| "org#{n}" } # グローバル unique ゆえ sequence 必須（設計 §9.1）
  end
end
```

- [ ] **Step 3: 失敗を確認**

```bash
bundle exec rspec spec/models/organization_spec.rb
```

Expected: FAIL（`uninitialized constant Organization`）

- [ ] **Step 4: migration とモデル**

```bash
bin/rails generate migration CreateOrganizations
```

migration:

```ruby
class CreateOrganizations < ActiveRecord::Migration[8.0]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :subdomain, null: false
      t.string :time_zone, null: false, default: "Asia/Tokyo"
      t.integer :fiscal_year_end_month
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :organizations, :subdomain, unique: true
  end
end
```

`app/models/organization.rb`:

```ruby
class Organization < ApplicationRecord
  # テナントルートゆえ acts_as_tenant を付けない（SPEC §3.1）
  has_many :users, dependent: :restrict_with_error

  validates :name, presence: true
  validates :subdomain, presence: true, uniqueness: true,
            format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/,
                      message: "は小文字英数とハイフンのみ使用できます" }
  validates :time_zone, presence: true
end
```

（`has_many :users` は Task 5 で User 作成後に有効になる。先に書いてよい）

- [ ] **Step 5: initializer と test 用 tenant 運用**

`config/initializers/acts_as_tenant.rb`:

```ruby
ActsAsTenant.configure do |config|
  # テナント未設定のクエリを例外化し、ラップ漏れを構造的に検出する（SPEC §2.2-6）
  config.require_tenant = true
end
```

`spec/support/tenant.rb`（設計 §9.1 の type 別運用）:

```ruby
RSpec.configure do |config|
  config.before(:each) do |example|
    if %i[request system].include?(example.metadata[:type])
      # 解決フィルタ自身を検証するため test_tenant を立てない（偽テスト防止）
      ActsAsTenant.test_tenant = nil
    else
      ActsAsTenant.test_tenant = FactoryBot.create(:organization)
    end
  end

  config.after(:each) do
    ActsAsTenant.current_tenant = nil
    ActsAsTenant.test_tenant = nil
  end
end
```

- [ ] **Step 6: テストを通す**

```bash
bin/rails db:migrate
bundle exec rspec spec/models/organization_spec.rb
```

Expected: PASS（4 examples）

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: Organization モデルと acts_as_tenant 基盤（require_tenant・test 運用）"
```

---

### Task 5: User モデルと Devise 基盤

**Files:**
- Modify: `Gemfile`, `config/initializers/devise.rb`（生成物を編集）, `config/routes.rb`, `config/environments/{development,test,production}.rb`
- Create: `db/migrate/*_devise_create_users.rb`, `app/models/user.rb`, `app/mailers/tenant_devise_mailer.rb`, `spec/factories/users.rb`, `spec/models/user_spec.rb`

- [ ] **Step 1: gem 追加とインストール**

```ruby
gem "devise"
```

```bash
bundle install
bin/rails generate devise:install
```

- [ ] **Step 2: failing test を書く**

`spec/models/user_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe User, type: :model do
  describe "email" do
    it "is unique within tenant" do
      create(:user, email: "a@example.com")
      expect(build(:user, email: "a@example.com")).not_to be_valid
    end

    it "allows same email in another tenant (鏡像)" do
      create(:user, email: "a@example.com")
      other_org = create(:organization)
      ActsAsTenant.with_tenant(other_org) do
        expect(build(:user, email: "a@example.com")).to be_valid
      end
    end

    it "is enforced by composite unique index at DB level" do
      user = create(:user, email: "a@example.com")
      dup = build(:user, email: "a@example.com", organization: user.organization)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "is normalized to lowercase" do
      expect(create(:user, email: "Mixed@Example.COM").email).to eq("mixed@example.com")
    end
  end

  describe "employee_code" do
    it "is unique within tenant but free across tenants" do
      create(:user, employee_code: "E001")
      expect(build(:user, employee_code: "E001")).not_to be_valid
      ActsAsTenant.with_tenant(create(:organization)) do
        expect(build(:user, employee_code: "E001")).to be_valid
      end
    end
  end

  describe "#active_for_authentication?" do
    it "rejects retired users (active=false)" do
      expect(build(:user, active: false).active_for_authentication?).to be(false)
    end
  end

  describe "role" do
    it "defaults to employee and is distinct from exempt_from_overtime" do
      user = create(:user)
      expect(user).to be_employee
      expect(user.exempt_from_overtime).to be(false)
    end
  end

  describe "require_tenant canary" do
    it "raises on unscoped query (恒久 regression・設計 §9.1)" do
      ActsAsTenant.test_tenant = nil
      expect { User.count }.to raise_error(ActsAsTenant::Errors::NoTenantSet)
    end
  end
end
```

`spec/factories/users.rb`（設計 §9.1 の organization フォールバック）:

```ruby
FactoryBot.define do
  factory :user do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    sequence(:email) { |n| "user#{n}@example.com" }
    sequence(:employee_code) { |n| "E#{format('%03d', n)}" }
    name { "テスト 太郎" }
    password { "password123!" }
    role { :employee }

    trait :manager_role do
      role { :manager }
    end

    trait :hr_admin do
      role { :hr_admin }
    end
  end
end
```

- [ ] **Step 3: 失敗を確認**

```bash
bundle exec rspec spec/models/user_spec.rb
```

Expected: FAIL（`uninitialized constant User`）

- [ ] **Step 4: migration（設計 §6・§7 の全制約）**

```bash
bin/rails generate migration DeviseCreateUsers
```

```ruby
class DeviseCreateUsers < ActiveRecord::Migration[8.0]
  def change
    create_table :users do |t|
      t.references :organization, null: false, foreign_key: true
      ## Database authenticatable
      t.string :email, null: false
      t.string :encrypted_password, null: false, default: ""
      ## Recoverable
      t.string :reset_password_token
      t.datetime :reset_password_sent_at
      ## Rememberable
      t.datetime :remember_created_at
      ## Trackable
      t.integer :sign_in_count, null: false, default: 0
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.string :current_sign_in_ip
      t.string :last_sign_in_ip
      ## Lockable
      t.integer :failed_attempts, null: false, default: 0
      t.string :unlock_token
      t.datetime :locked_at
      ## Domain（SPEC §4.3 / 設計 §6）
      t.string :name, null: false
      t.string :employee_code, null: false
      t.integer :role, null: false, default: 0
      t.bigint :manager_id
      t.boolean :exempt_from_overtime, null: false, default: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    # テナント内一意（グローバル unique は張らない・SPEC §3.2）
    add_index :users, [:organization_id, :email], unique: true
    add_index :users, [:organization_id, :employee_code], unique: true
    # トークン列はグローバル unique を維持（SPEC §3.2(3)）
    add_index :users, :reset_password_token, unique: true
    add_index :users, :unlock_token, unique: true
    # 複合 FK の前提となる unique index（この順序が必須・設計 §7）
    add_index :users, [:organization_id, :id], unique: true
    add_index :users, :manager_id
    # 上長の同一テナント強制（SPEC §3.6(2) の DB 層）
    add_foreign_key :users, :users,
                    column: [:organization_id, :manager_id],
                    primary_key: [:organization_id, :id]
  end
end
```

- [ ] **Step 5: User モデル（validatable は自前化・設計 §4）**

`app/models/user.rb`:

```ruby
class User < ApplicationRecord
  acts_as_tenant(:organization)

  # :validatable は載せない — 一意性検証だけの差し替えが不可能なため自前検証（devise#4767）
  # :registerable も載せない — 公開サインアップなし（SPEC §3.2）
  # :rememberable と :timeoutable の併用は Devise 既定（remembered ユーザーは timeout 免除）を容認
  devise :database_authenticatable, :recoverable, :rememberable,
         :lockable, :trackable, :timeoutable

  belongs_to :manager, class_name: "User", optional: true
  has_many :subordinates, class_name: "User",
           foreign_key: :manager_id, inverse_of: :manager, dependent: :nullify

  enum :role, { employee: 0, manager: 1, hr_admin: 2 }, prefix: false

  normalizes :email, with: ->(email) { email.strip.downcase }

  # validatable 相当の自前検証
  validates :email, presence: true, format: { with: Devise.email_regexp }
  validates_uniqueness_to_tenant :email
  validates :password, presence: true, confirmation: true,
            length: { within: Devise.password_length }, if: :password_required?
  validates :name, presence: true
  validates :employee_code, presence: true
  validates_uniqueness_to_tenant :employee_code
  validate :manager_must_belong_to_same_organization

  # 在籍フラグを認証に接続（fail-closed・設計 §6）
  def active_for_authentication?
    super && active?
  end

  # 退職者の存在を応答差で漏らさない（paranoid と整合）
  def inactive_message
    active? ? super : :invalid
  end

  class << self
    # acts_as_tenant の default scope に加えた明示防衛（scope が外れた経路への二重化・設計 §4）
    def find_for_database_authentication(warden_conditions)
      tenant = ActsAsTenant.current_tenant
      return nil unless tenant

      find_by(organization_id: tenant.id,
              email: warden_conditions[:email].to_s.strip.downcase)
    end

    # recoverable / lockable の発行系が通る経路も同様にスコープ（設計 §4）
    def find_first_by_auth_conditions(tainted_conditions, opts = {})
      tenant = ActsAsTenant.current_tenant
      return nil unless tenant

      super(tainted_conditions, opts.merge(organization_id: tenant.id))
    end

    # トークン消費の再検証 — トークンが属するテナントが正・URL のサブドメインを信頼しない（設計 §4）
    def with_reset_password_token(token)
      super&.tap do |user|
        tenant = ActsAsTenant.current_tenant
        raise ActiveRecord::RecordNotFound if tenant && user.persisted? && user.organization_id != tenant.id
      end
    end
  end

  private

  def password_required?
    !persisted? || password.present? || password_confirmation.present?
  end

  def manager_must_belong_to_same_organization
    return if manager_id.nil?
    # acts_as_tenant のスコープ下では他テナントの manager は解決されず nil になる。
    # nil（=スコープ外）も明示エラーにすることで §3.6(2) のバリデーション層を担う
    return if manager&.organization_id == organization_id

    errors.add(:manager_id, "は同一組織のユーザーである必要があります")
  end
end
```

- [ ] **Step 6: Devise initializer の編集と routes**

`config/initializers/devise.rb` の該当行を変更:

```ruby
config.mailer = "TenantDeviseMailer"
config.paranoid = true                     # 列挙耐性（設計 §4）
config.lock_strategy = :failed_attempts
config.unlock_strategy = :email
config.maximum_attempts = 10
# remember cookie はホスト限定（domain を親ドメインへ広げない・設計 §5）
config.rememberable_options = { secure: Rails.env.production?, same_site: :lax }
```

`config/routes.rb`:

```ruby
Rails.application.routes.draw do
  devise_for :users, skip: [:registrations]
  root "home#show" # HomeController は Task 11 で作成。それまで root 到達は 500 でよい
end
```

- [ ] **Step 7: テナント別メール host（設計 §4）**

`app/mailers/tenant_devise_mailer.rb`:

```ruby
class TenantDeviseMailer < Devise::Mailer
  protected

  # deliver_later はリクエストコンテキストを持たないため、
  # 宛先ユーザーの organization からサブドメイン込み host を組み立てる（設計 §4）
  def devise_mail(record, action, opts = {}, &block)
    @tenant_url_options = {
      host: "#{record.organization.subdomain}.#{Rails.application.config.x.tenant_base_host}",
      port: Rails.application.config.x.tenant_base_port
    }.compact
    super
  end

  def default_url_options
    @tenant_url_options || super
  end
end
```

各 environment に追記:

```ruby
# config/environments/development.rb
config.x.tenant_base_host = "localhost"
config.x.tenant_base_port = 3000
# *.localhost のサブドメイン解決（acme.localhost → subdomain "acme"）
config.action_dispatch.tld_length = 0

# config/environments/test.rb
config.x.tenant_base_host = "example.com"
config.x.tenant_base_port = nil

# config/environments/production.rb
config.x.tenant_base_host = ENV.fetch("TENANT_BASE_HOST", "gatcha.example.com")
config.x.tenant_base_port = nil
```

- [ ] **Step 8: テストを通す**

```bash
bin/rails db:migrate
bundle exec rspec spec/models/user_spec.rb
```

Expected: PASS（10 examples）。`schema.rb` に複合 FK（`organization_id, manager_id`）が dump されていることも目視確認（設計 §7）。

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "feat: User モデルと Devise テナントスコープ基盤（validatable 自前化・複合 unique/FK・paranoid）"
```

---

### Task 6: manager 同一テナント強制の検証

**Files:**
- Modify: `spec/models/user_spec.rb`（describe を追加）

- [ ] **Step 1: failing test を書く**

`spec/models/user_spec.rb` に追加:

```ruby
  describe "manager 同一テナント強制（SPEC §3.6(2)）" do
    it "accepts a manager in the same organization" do
      boss = create(:user, :manager_role)
      expect(build(:user, manager: boss)).to be_valid
    end

    it "rejects a manager from another tenant with errors[:manager_id]" do
      other_org = create(:organization)
      foreign_boss = ActsAsTenant.with_tenant(other_org) { create(:user, :manager_role) }
      user = build(:user, manager_id: foreign_boss.id)
      expect(user).not_to be_valid
      # 属性まで assert — 偶然の別エラーで赤くなる「素通り」を防ぐ（設計 §9.2）
      expect(user.errors[:manager_id]).to be_present
    end

    it "is enforced by composite FK even when validation is bypassed" do
      other_org = create(:organization)
      foreign_boss = ActsAsTenant.with_tenant(other_org) { create(:user, :manager_role) }
      victim = create(:user)
      expect {
        victim.update_column(:manager_id, foreign_boss.id)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
```

- [ ] **Step 2: 実行して通ることを確認**

```bash
bundle exec rspec spec/models/user_spec.rb
```

Expected: PASS（Task 5 の実装で既に満たされているはず。FAIL したらバリデーション/FK の実装を直す——これは「実装済みの防御が本物か」を実証する regression テスト）

- [ ] **Step 3: Commit**

```bash
git add spec/models/user_spec.rb
git commit -m "test: manager 同一テナント強制の検証（属性 assert・FK バイパス拒否）"
```

---

### Task 7: テナント解決（ApplicationController）

**Files:**
- Modify: `app/controllers/application_controller.rb`, `config/environments/test.rb`
- Create: `spec/requests/tenant_resolution_spec.rb`, `spec/support/tenant_request_helpers.rb`

- [ ] **Step 1: failing test を書く**

`spec/support/tenant_request_helpers.rb`:

```ruby
module TenantRequestHelpers
  def tenant_host(org) = "#{org.subdomain}.example.com"
end

RSpec.configure do |config|
  config.include TenantRequestHelpers, type: :request
  config.include TenantRequestHelpers, type: :system
  config.include Devise::Test::IntegrationHelpers, type: :request
end
```

`spec/requests/tenant_resolution_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "テナント解決（fail-closed・SPEC §3.1）", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  it "正常: 既知サブドメイン＋ログイン済みでホーム到達" do
    sign_in user
    get root_url(host: tenant_host(org))
    expect(response).to have_http_status(:ok)
  end

  it "未知サブドメインは未ログインでも 404（①解決→②認証の順序固定）" do
    get root_url(host: "unknown.example.com")
    expect(response).to have_http_status(:not_found)
  end

  it "inactive 組織は 404" do
    org.update!(active: false)
    get root_url(host: tenant_host(org))
    expect(response).to have_http_status(:not_found)
  end

  it "apex（サブドメインなし）は 404" do
    get root_url(host: "example.com")
    expect(response).to have_http_status(:not_found)
  end

  it "www は 404（テナントではない）" do
    get root_url(host: "www.example.com")
    expect(response).to have_http_status(:not_found)
  end

  it "大文字サブドメインは downcase されて解決" do
    sign_in user
    get root_url(host: "ACME.example.com")
    expect(response).to have_http_status(:ok)
  end

  it "正常サブドメイン＋未ログインはサインインへ redirect" do
    get root_url(host: tenant_host(org))
    expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))
  end

  it "inactive 化後は既存セッションも遮断される（設計 §3）" do
    sign_in user
    get root_url(host: tenant_host(org))
    expect(response).to have_http_status(:ok)
    org.update!(active: false)
    get root_url(host: tenant_host(org))
    expect(response).to have_http_status(:not_found)
  end
end
```

- [ ] **Step 2: 失敗を確認**

```bash
bundle exec rspec spec/requests/tenant_resolution_spec.rb
```

Expected: FAIL（テナント解決が未実装。root も未実装なので大半がエラー）

- [ ] **Step 3: ApplicationController を実装**

```ruby
class ApplicationController < ActionController::Base
  set_current_tenant_through_filter
  before_action :resolve_tenant_from_subdomain
  before_action :authenticate_user!, unless: :devise_controller?

  private

  # fail-closed: 解決失敗・inactive は 404 で打ち切り、current_tenant nil のまま進まない（SPEC §3.1）
  def resolve_tenant_from_subdomain
    subdomain = request.subdomain.to_s.downcase
    organization = subdomain.presence &&
                   Organization.find_by(subdomain: subdomain, active: true)
    unless organization
      reset_session # inactive 化後の既存セッションも遮断（設計 §3）
      raise ActiveRecord::RecordNotFound, "tenant not found"
    end
    set_current_tenant(organization)
  end
end
```

`config/environments/test.rb` に追記（404 をレスポンスとして検証するため）:

```ruby
config.action_dispatch.show_exceptions = :rescuable
```

暫定の root（Task 11 で本実装）。`app/controllers/home_controller.rb`:

```ruby
class HomeController < ApplicationController
  def show
    render plain: "ok"
  end
end
```

- [ ] **Step 4: テストを通す**

```bash
bundle exec rspec spec/requests/tenant_resolution_spec.rb
```

Expected: PASS（8 examples）

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: サブドメインによる fail-closed テナント解決（態様 8 ケースの request spec 付き）"
```

---

### Task 8: 認証のテナントスコープ検証（クロステナント・メール経路）

**Files:**
- Create: `spec/requests/authentication_spec.rb`, `spec/requests/password_reset_spec.rb`

- [ ] **Step 1: failing test を書く（認証経路）**

`spec/requests/authentication_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "認証のテナントスコープ（SPEC §3.2）", type: :request do
  let!(:acme)   { create(:organization, subdomain: "acme") }
  let!(:globex) { create(:organization, subdomain: "globex") }
  let!(:acme_user) do
    ActsAsTenant.with_tenant(acme) { create(:user, email: "shared@example.com", password: "password123!") }
  end
  let!(:globex_user) do
    ActsAsTenant.with_tenant(globex) { create(:user, email: "shared@example.com", password: "different456!") }
  end

  def sign_in_via_form(host:, email:, password:)
    post user_session_url(host: host),
         params: { user: { email: email, password: password } }
  end

  it "globex のフォームに acme の資格情報では認証できない" do
    sign_in_via_form(host: tenant_host(globex), email: "shared@example.com", password: "password123!")
    expect(response).to have_http_status(:unprocessable_entity).or have_http_status(:ok)
    follow_redirect! if response.redirect?
    expect(controller.current_user).to be_nil
  end

  it "同一 email でも各テナントで正しい本人として認証される" do
    sign_in_via_form(host: tenant_host(globex), email: "shared@example.com", password: "different456!")
    expect(response).to redirect_to(root_url(host: tenant_host(globex)))
  end

  it "lockable の failed_attempts はテナント間で独立" do
    3.times do
      sign_in_via_form(host: tenant_host(acme), email: "shared@example.com", password: "wrong!")
    end
    expect(acme_user.reload.failed_attempts).to eq(3)
    expect(globex_user.reload.failed_attempts).to eq(0)
  end

  it "退職者（active=false）はログインできない" do
    acme_user.update!(active: false)
    sign_in_via_form(host: tenant_host(acme), email: "shared@example.com", password: "password123!")
    follow_redirect! if response.redirect?
    expect(controller.current_user).to be_nil
  end

  it "paranoid: 失敗メッセージがユーザー存在に依存しない（列挙耐性）" do
    sign_in_via_form(host: tenant_host(acme), email: "nobody@example.com", password: "x")
    message_for_unknown = response.body
    sign_in_via_form(host: tenant_host(acme), email: "shared@example.com", password: "wrong!")
    expect(response.body).to eq(message_for_unknown)
  end
end
```

- [ ] **Step 2: failing test を書く（メール経路・設計 §9.2）**

`spec/requests/password_reset_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "パスワードリセットのテナント分離（SPEC §3.2(3)）", type: :request do
  include ActiveJob::TestHelper

  let!(:acme)   { create(:organization, subdomain: "acme") }
  let!(:globex) { create(:organization, subdomain: "globex") }
  let!(:acme_user) do
    ActsAsTenant.with_tenant(acme) { create(:user, email: "shared@example.com") }
  end
  let!(:globex_user) do
    ActsAsTenant.with_tenant(globex) { create(:user, email: "shared@example.com") }
  end

  it "acme での要求は acme ユーザーのみトークン更新・メール 1 通・URL は acme サブドメイン" do
    expect {
      perform_enqueued_jobs do
        post user_password_url(host: tenant_host(acme)),
             params: { user: { email: "shared@example.com" } }
      end
    }.to change { ActionMailer::Base.deliveries.count }.by(1)

    expect(acme_user.reload.reset_password_token).to be_present
    expect(globex_user.reload.reset_password_token).to be_nil

    mail_body = ActionMailer::Base.deliveries.last.body.encoded
    expect(mail_body).to include("acme.example.com")
    expect(mail_body).not_to include("globex.example.com")
  end

  it "acme で発行したトークンは globex サブドメインで消費できない" do
    raw_token = ActsAsTenant.with_tenant(acme) { acme_user.send_reset_password_instructions }

    put user_password_url(host: tenant_host(globex)),
        params: { user: { reset_password_token: raw_token,
                          password: "newpassword1!", password_confirmation: "newpassword1!" } }

    expect(response).not_to have_http_status(:see_other) # 成功 redirect しない
    expect(acme_user.reload.valid_password?("newpassword1!")).to be(false)
  end

  it "正規テナントではトークン消費が成功する" do
    raw_token = ActsAsTenant.with_tenant(acme) { acme_user.send_reset_password_instructions }

    put user_password_url(host: tenant_host(acme)),
        params: { user: { reset_password_token: raw_token,
                          password: "newpassword1!", password_confirmation: "newpassword1!" } }

    expect(acme_user.reload.valid_password?("newpassword1!")).to be(true)
  end
end
```

- [ ] **Step 3: 実行して結果を確認**

```bash
bundle exec rspec spec/requests/authentication_spec.rb spec/requests/password_reset_spec.rb
```

Expected: Task 5 の実装で大半 PASS。FAIL があれば `find_for_database_authentication` / `find_first_by_auth_conditions` / `with_reset_password_token` / mailer の実装を修正（このタスクは検証が主目的）。
注意: request spec で `controller.current_user` が使えない場合は `session` の有無や `response.body` での判定に置き換える。

- [ ] **Step 4: Commit**

```bash
git add spec/requests/
git commit -m "test: 認証・パスワードリセットのテナント分離検証（クロステナント・同一 email・列挙耐性）"
```

---

### Task 9: Warden 一点防御（整合突合）

**Files:**
- Create: `config/initializers/warden_tenant_guard.rb`, `spec/requests/tenant_integrity_spec.rb`

- [ ] **Step 1: failing test を書く**

`spec/requests/tenant_integrity_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "テナント整合突合（Warden 一点防御・設計 §5）", type: :request do
  let!(:acme)   { create(:organization, subdomain: "acme") }
  let!(:globex) { create(:organization, subdomain: "globex") }
  let!(:acme_user) { ActsAsTenant.with_tenant(acme) { create(:user) } }

  it "acme のユーザーで globex にアクセスするとサインインへ戻される" do
    sign_in acme_user
    get root_url(host: tenant_host(globex))
    expect(response).to redirect_to(new_user_session_url(host: tenant_host(globex)))
  end

  it "不一致検出時はセッションが破棄される（401 偽装でなく実破棄・設計 §9.2）" do
    sign_in acme_user
    get root_url(host: tenant_host(globex)) # ここで突合 → logout
    get root_url(host: tenant_host(acme))   # 正規テナントでも再ログイン要求
    expect(response).to redirect_to(new_user_session_url(host: tenant_host(acme)))
  end

  it "remember cookie はホスト限定で発行される（親ドメインに広がらない・設計 §5）" do
    post user_session_url(host: tenant_host(acme)),
         params: { user: { email: acme_user.email, password: "password123!", remember_me: "1" } }
    set_cookie = response.headers["Set-Cookie"].to_s
    expect(set_cookie).to include("remember_user_token")
    expect(set_cookie.downcase).not_to include("domain=")
  end
end
```

- [ ] **Step 2: 失敗を確認**

```bash
bundle exec rspec spec/requests/tenant_integrity_spec.rb
```

Expected: 1〜2 例 FAIL（突合が未実装のため globex でもホームに到達してしまう）

- [ ] **Step 3: Warden hook を実装**

`config/initializers/warden_tenant_guard.rb`:

```ruby
# テナント整合突合（SPEC §3.1③）の一点防御。
# before_action ではなく Warden hook に置く理由: Devise のトークン経路・
# remember cookie 復元は ApplicationController の before_action を通らずに
# 認証が成立し得るため、認証確立の単一点で塞ぐ（設計 §5）。
Warden::Manager.after_set_user do |user, warden, opts|
  next unless user.is_a?(User)

  tenant = ActsAsTenant.current_tenant
  next if tenant && user.organization_id == tenant.id

  scope = opts[:scope] || :user
  warden.logout(scope)
  warden.reset_session!                                    # セッション固定対策を兼ねる
  warden.request.cookie_jar.delete(:remember_user_token)   # remember 失効
  throw(:warden, scope: scope, message: :unauthenticated)
end
```

- [ ] **Step 4: テストを通す**

```bash
bundle exec rspec spec/requests/tenant_integrity_spec.rb spec/requests/
```

Expected: 全 request spec PASS（hook 追加で既存テストが壊れていないことも確認）

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: Warden after_set_user でテナント整合突合の一点防御（セッション破棄・remember 失効）"
```

---

### Task 10: Pundit（既定 deny と強制フック）

**Files:**
- Modify: `Gemfile`, `app/controllers/application_controller.rb`
- Create: `app/policies/application_policy.rb`, `spec/policies/application_policy_spec.rb`, `spec/controllers/application_controller_spec.rb`

- [ ] **Step 1: gem 追加**

```ruby
gem "pundit"
```

```bash
bundle install
```

- [ ] **Step 2: failing test を書く**

`spec/policies/application_policy_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe ApplicationPolicy, type: :policy do
  subject { described_class.new(user, record) }

  let(:user) { create(:user) }
  let(:record) { :anything }

  it { is_expected.to forbid_all_actions } # 既定 deny（設計 §7）

  describe "Scope" do
    it "resolves to none by default（policy_scope 経由の漏洩防止・設計 §9.2）" do
      scope = ApplicationPolicy::Scope.new(user, User.all).resolve
      expect(scope).to be_empty
    end
  end
end
```

`spec/controllers/application_controller_spec.rb`（authorize 漏れ検知・設計 §9.2）:

```ruby
require "rails_helper"

RSpec.describe ApplicationController, type: :controller do
  controller do
    def index
      render plain: "authorize を呼ばない action"
    end
  end

  let(:org)  { create(:organization, subdomain: "acme") }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  before do
    @request.host = "acme.example.com"
    sign_in user
  end

  it "authorize を呼ばない action は AuthorizationNotPerformedError を起こす" do
    expect { get :index }.to raise_error(Pundit::AuthorizationNotPerformedError)
  end
end
```

`spec/support/devise_controller.rb` を作成:

```ruby
RSpec.configure do |config|
  config.include Devise::Test::ControllerHelpers, type: :controller
end
```

- [ ] **Step 3: 失敗を確認**

```bash
bundle exec rspec spec/policies spec/controllers
```

Expected: FAIL（`uninitialized constant ApplicationPolicy` / 強制フック未実装）

- [ ] **Step 4: 実装**

`app/policies/application_policy.rb`:

```ruby
class ApplicationPolicy
  attr_reader :user, :record

  def initialize(user, record)
    @user = user
    @record = record
  end

  # 既定 deny — 許可は各ポリシーで明示的に開ける（設計 §7）
  def index? = false
  def show? = false
  def create? = false
  def new? = create?
  def update? = false
  def edit? = update?
  def destroy? = false

  class Scope
    def initialize(user, scope)
      @user = user
      @scope = scope
    end

    # 既定 deny — 一覧も明示的に開けるまで空（設計 §7）
    def resolve
      scope.none
    end

    private

    attr_reader :user, :scope
  end
end
```

`app/controllers/application_controller.rb` に追記:

```ruby
  include Pundit::Authorization

  # Devise コントローラを除外しないとログイン画面で発火する（定番穴・設計 §7）
  after_action :verify_authorized, unless: :devise_controller?
  # 全アクション強制は skip 列挙の増殖を招くため index のみ（Pundit README 準拠・設計 §7）
  after_action :verify_policy_scoped, only: :index, unless: :devise_controller?

  rescue_from Pundit::NotAuthorizedError, with: :render_forbidden
```

private 節に追加:

```ruby
  def render_forbidden
    render plain: "アクセス権がありません", status: :forbidden
  end
```

- [ ] **Step 5: テストを通す**

```bash
bundle exec rspec spec/policies spec/controllers
```

Expected: PASS。ただし Task 7 の暫定 HomeController（authorize 未実装）が `verify_authorized` で壊れるため、`spec/requests/` が FAIL するはず——次タスクで本実装して解消する。一時的に HomeController へ `def show; skip_authorization; render plain: "ok"; end` を入れて全体を緑に保つ。

```bash
bundle exec rspec
```

Expected: 全 PASS

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: Pundit 既定 deny と verify_authorized/policy_scoped の強制（authorize 漏れ検知テスト付き）"
```

---

### Task 11: 最小ホームと system spec（テナント分離 E2E）

**Files:**
- Modify: `app/controllers/home_controller.rb`
- Create: `app/policies/home_policy.rb`, `app/views/home/show.html.erb`, `spec/policies/home_policy_spec.rb`, `spec/system/tenant_isolation_spec.rb`, `spec/support/capybara_tenant.rb`

- [ ] **Step 1: failing test を書く**

`spec/policies/home_policy_spec.rb`（許可・非許可の両方向・設計 §9.2）:

```ruby
require "rails_helper"

RSpec.describe HomePolicy, type: :policy do
  subject { described_class.new(user, :home) }

  context "ログイン済みユーザー" do
    let(:user) { create(:user) }
    it { is_expected.to permit_action(:show) }
  end

  context "未認証（user が nil）" do
    let(:user) { nil }
    it { is_expected.to forbid_action(:show) }
  end
end
```

`spec/support/capybara_tenant.rb`:

```ruby
module CapybaraTenantHelpers
  # サブドメイン切替（設計 §9.1）。rack_test ゆえ DNS 不要
  def switch_tenant(org)
    Capybara.app_host = "http://#{org.subdomain}.example.com"
  end
end

RSpec.configure do |config|
  config.include CapybaraTenantHelpers, type: :system
  config.after(:each, type: :system) { Capybara.app_host = nil }
end
```

`spec/system/tenant_isolation_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "テナント分離 E2E", type: :system do
  let!(:acme)   { create(:organization, name: "Acme", subdomain: "acme") }
  let!(:globex) { create(:organization, name: "Globex", subdomain: "globex") }
  let!(:acme_user) do
    ActsAsTenant.with_tenant(acme) do
      create(:user, name: "急須 茶太郎", email: "cha@example.com", password: "password123!")
    end
  end
  let!(:globex_user) do
    ActsAsTenant.with_tenant(globex) do
      create(:user, name: "轟 雷蔵", email: "rai@example.com", password: "different456!")
    end
  end

  def login(email:, password:)
    visit new_user_session_path
    fill_in "Email", with: email
    fill_in "Password", with: password
    click_button "Log in"
  end

  it "acme のユーザーは acme でログインでき、自分の名前と組織が見える" do
    switch_tenant(acme)
    login(email: "cha@example.com", password: "password123!")
    # 正のアンカー assert（設計 §9.2: エラーページでも緑になる偽テスト防止）
    expect(page).to have_content("急須 茶太郎")
    expect(page).to have_content("Acme")
    expect(page).not_to have_content("Globex")
  end

  it "globex のフォームに acme の資格情報ではログインできない" do
    switch_tenant(globex)
    login(email: "cha@example.com", password: "password123!")
    expect(page).to have_current_path(new_user_session_path)
    expect(page).not_to have_content("急須 茶太郎")
  end
end
```

- [ ] **Step 2: 失敗を確認**

```bash
bundle exec rspec spec/policies/home_policy_spec.rb spec/system
```

Expected: FAIL（HomePolicy 不在・ホーム画面が plain テキスト）

- [ ] **Step 3: 実装**

`app/policies/home_policy.rb`:

```ruby
class HomePolicy < ApplicationPolicy
  def show? = user.present?
end
```

`app/controllers/home_controller.rb`（暫定実装を置換）:

```ruby
class HomeController < ApplicationController
  def show
    authorize :home, :show?
  end
end
```

`app/views/home/show.html.erb`:

```erb
<main class="mx-auto max-w-xl p-8">
  <h1 class="text-2xl font-bold">Gatcha 勤怠</h1>
  <p class="mt-4">
    <%= current_user.name %> としてログイン中
    （<%= current_user.role %> / <%= ActsAsTenant.current_tenant.name %>）
  </p>
  <%= button_to "ログアウト", destroy_user_session_path, method: :delete,
        class: "mt-6 rounded bg-gray-800 px-4 py-2 text-white" %>
</main>
```

- [ ] **Step 4: テストを通す**

```bash
bundle exec rspec
```

Expected: 全 PASS（Task 10 で入れた `skip_authorization` の暫定は削除されている）

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: 最小ホーム（HomePolicy 両方向検証・テナント分離の system spec）"
```

---

### Task 12: seeds

**Files:**
- Modify: `db/seeds.rb`

- [ ] **Step 1: seeds を書く（設計 §8）**

```ruby
# 本番実行を拒否 — 既知パスワードの管理者が本番に残る事故の遮断（設計 §8）
abort("seeds は development/test 専用です") unless Rails.env.development? || Rails.env.test?

password = ENV.fetch("SEED_PASSWORD") { SecureRandom.alphanumeric(20) }
puts "==> seed ユーザーの共通パスワード: #{password}"

[
  { name: "Acme", subdomain: "acme" },
  { name: "Globex", subdomain: "globex" }
].each do |attrs|
  org = Organization.find_or_create_by!(subdomain: attrs[:subdomain]) do |o|
    o.name = attrs[:name]
  end

  # リクエスト文脈を持たない経路ゆえ明示ラップ（SPEC §3.6）
  ActsAsTenant.with_tenant(org) do
    admin = User.find_or_create_by!(email: "admin@#{org.subdomain}.example.com") do |u|
      u.name = "#{org.name} 管理者"
      u.employee_code = "#{org.subdomain.upcase}-001"
      u.role = :hr_admin
      u.password = password
    end

    boss = User.find_or_create_by!(email: "manager@#{org.subdomain}.example.com") do |u|
      u.name = "#{org.name} 上長"
      u.employee_code = "#{org.subdomain.upcase}-002"
      u.role = :manager
      u.password = password
    end

    User.find_or_create_by!(email: "employee@#{org.subdomain}.example.com") do |u|
      u.name = "#{org.name} 社員"
      u.employee_code = "#{org.subdomain.upcase}-003"
      u.role = :employee
      u.manager = boss
      u.password = password
    end

    puts "==> #{org.name}: #{User.count} users (admin: #{admin.email})"
  end
end
```

- [ ] **Step 2: 実行確認**

```bash
SEED_PASSWORD=devpass123! bin/rails db:seed
```

Expected: 2 組織 × 3 ユーザーの作成ログ。再実行しても冪等（`find_or_create_by!`）。

- [ ] **Step 3: ブラウザで骨格を確認（手動・任意）**

```bash
bin/dev
```

`http://acme.localhost:3000` → ログイン画面 → `admin@acme.example.com` / `devpass123!` でホーム到達。`http://globex.localhost:3000` で acme の資格情報が弾かれることも一見しておく。

- [ ] **Step 4: Commit**

```bash
git add db/seeds.rb
git commit -m "feat: seeds（2 組織×3 ロール・env ガード・with_tenant ラップ・固定パスワード排除）"
```

---

### Task 13: 仕上げ（ドキュメント整合・全通し・PR）

**Files:**
- Modify: `docs/SPEC.md`（§2.1 スタック表）, `CLAUDE.md`

- [ ] **Step 1: SPEC §2.1 に Tailwind を追記**

`docs/SPEC.md` のスタック表「フロントエンド」行を更新:

```markdown
| フロントエンド | Hotwire（Turbo + Stimulus）+ ViewComponent + Tailwind CSS | サーバーレンダリング・レスポンシブ / PWA |
```

- [ ] **Step 2: CLAUDE.md に console 作法を追記（設計 §11）**

CLAUDE.md の Gotchas 節に追加:

```markdown
- **rails console / rake:** `require_tenant = true` ゆえ、最初に `ActsAsTenant.current_tenant = Organization.find_by!(subdomain: "acme")` を実行しないとスコープ付きモデルのクエリが `NoTenantSet` で失敗する
```

- [ ] **Step 3: 全体通し**

```bash
bin/rubocop && bin/brakeman --no-pager && bundle exec rspec
```

Expected: すべて成功。rubocop 違反は `-a` で自動修正し、残りは手で直す。

- [ ] **Step 4: Commit・push・PR**

```bash
git add -A
git commit -m "docs: SPEC に Tailwind 追記・CLAUDE.md に console のテナント作法を追加"
```

push 前に `/preflight` を実行。問題なければ:

```bash
git push -u origin feat/app-foundation
```

PR 作成は gh アカウント切り替えが必要（`gh auth switch --hostname github.com --user kei1110` → `gh pr create` → `gh auth switch --hostname github.com --user sub-account`）。PR タイトルは Squash 後の commit になるため Conventional Commits 形式:
`feat: Rails 8 基盤（マルチテナント・認証・認可・CI）— Phase 0a`

- [ ] **Step 5: CI 緑化を確認して Squash マージ**

PR 上で `lint` / `security` / `test` の 3 チェックと CodeRabbit レビューを確認。CodeRabbit の指摘は採否判断のうえ対応。緑になったら Squash マージ。

---

### Task 14: required status checks 登録（マージ後）

**Files:** なし（GitHub Ruleset 操作）

ブランチ戦略 plan の Deferred Task を実行する。**required は自前 CI のみ・CodeRabbit は含めない**（2026-06-10 改訂）。

- [ ] **Step 1: チェック context 名を実測で確認**

```bash
gh auth switch --hostname github.com --user kei1110
gh api repos/kei1110/Gatcha_on_RoR/commits/$(git rev-parse origin/main)/check-runs \
  --jq '.check_runs[].name'
```

Expected: `lint` / `security` / `test`（＋CodeRabbit）。以下の JSON の context は**この実測値**に合わせる。

- [ ] **Step 2: Ruleset を更新**

```bash
cat > /tmp/main-ruleset-with-checks.json <<'JSON'
{
  "name": "main",
  "target": "branch",
  "enforcement": "active",
  "bypass_actors": [],
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "required_status_checks": [
          { "context": "lint" },
          { "context": "security" },
          { "context": "test" }
        ]
      }
    }
  ]
}
JSON
gh api --method PUT repos/kei1110/Gatcha_on_RoR/rulesets/17476200 \
  --input /tmp/main-ruleset-with-checks.json \
  --jq '{id, rules: [.rules[].type]}'
```

Expected: rules に `required_status_checks` が含まれる。

- [ ] **Step 3: アカウント復元と掃除**

```bash
gh auth switch --hostname github.com --user sub-account
gh api user --jq '.login'
rm -f /tmp/main-ruleset-with-checks.json
```

Expected: `sub-account`

これで Phase 0a 完了。次は 0b（マスタ CRUD）の brainstorm へ。

---

## Self-Review

- **Spec coverage（設計 §1〜§11 → Task 対応）:** §1 rails new/gem → Task 1,2,4,5,10 ✅ / §2 CI・required → Task 3,14 ✅ / §3 テナント解決・信頼境界・inactive 即時遮断 → Task 7 ✅ / §4 Devise（validatable 自前化・複合 unique・スコープ・トークン再検証・mailer・paranoid）→ Task 5,8 ✅ / §5 Warden 一点防御・remember 失効・cookie ホスト限定 → Task 9 ✅ / §6 User スキーマ（name/active/active_for_authentication?）→ Task 5 ✅ / §7 manager 強制・Pundit・mass-assignment（0a は受け口なし。0b の CRUD 実装時に permit 除外を適用）→ Task 5,6,10 ✅ / §8 seeds → Task 12 ✅ / §9 テスト戦略（type 別運用・canary・鏡像・FK 直叩き・メール経路・アンカー assert・authorize 漏れ検知）→ Task 4〜11 ✅ / §10 エラーハンドリング → Task 7,9,10 ✅ / §11 console 作法 → Task 13 ✅
- **Placeholder scan:** 「暫定 HomeController」（Task 7→10→11 で段階置換と明記）以外に TBD/TODO なし ✅
- **Type consistency:** factory トレイト `:manager_role`（enum `manager` との衝突回避）を Task 5/6 で一貫使用。`tenant_host`（request）と `switch_tenant`（system）の使い分け一貫。Ruleset id 17476200・job 名 lint/security/test 一貫 ✅
- **既知の不確実点（実装時に現物合わせ）:** Devise の paranoid 応答比較（Task 8 Step 1 最終例）は flash の実装次第で `response.body` 比較が脆い可能性 → その場合は flash メッセージ同士の比較に置換。`controller.current_user` が request spec で取れない場合の代替も Task 8 に明記済み。
