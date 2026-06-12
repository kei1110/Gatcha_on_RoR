# Phase 0b-5 OrganizationSetting + ReasonTemplate 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 組織設定画面（v1 最小 3 項目・fiscal_year_end_month 変更時の CompanyCalendar.fiscal_year 自動再計算）と申請理由テンプレート CRUD を出荷する。

**Architecture:** 設計仕様 [docs/superpowers/specs/2026-06-12-phase0b5-organization-setting-reason-template-design.md](../specs/2026-06-12-phase0b5-organization-setting-reason-template-design.md)。テーブルは消費済みカラムのみ（残りは消費 Phase 後送り）。設定行は `Organization#setting` アクセサに一元化。2 モデル保存 + 再計算は `OrganizationSettings::Updater`（Result 返し・with_tenant 自己完結）。更新対象の組織は **`ActsAsTenant.current_tenant` のインスタンスに固定**（acts_as_tenant のリーダー短絡により再計算が必ず更新後の決算月を見る）。

**Tech Stack:** Rails 8.1 / PostgreSQL 17 / acts_as_tenant / Pundit / RSpec + FactoryBot

**ブランチ:** `feat/0b-5-organization-setting`（作成済み・設計コミット c4c5347 が先頭）

**実行体制（折衷案・ユーザー承認済み 2026-06-12）:** 実装 = サブエージェント（**Task 7 のみ Codex 試験委託**）／スペック準拠レビュー = 主エージェントが `git diff` と本計画を直接突合／品質レビュー = 独立サブエージェント／修正再確認 = 主エージェント。

---

## 前提知識（RAILS_GOTCHAS 注入 — 違反すると過去に踏んだ虫を買い直す）

1. **書き込み redirect は一律 `status: :see_other`**・失敗 render は `:unprocessable_entity`
2. **acts_as_tenant のリーダー短絡（本スライスの肝）**: `organization_id == current_tenant.id` のとき association リーダーは DB を読まず **current_tenant の in-memory インスタンス**を返す。組織の更新は必ず `ActsAsTenant.current_tenant` そのインスタンスに行うこと（別インスタンス経由だと再計算が旧決算月で走る silent failure）
3. **request spec の setup は `ActsAsTenant.with_tenant(org) { ... }` で包む**
4. **enum は `validate: true`**（毒値を 422 に）・permit は allowlist 最小
5. **サブエージェント/Codex はフックをすり抜ける** — 各タスク完了条件: `bundle exec rspec` 全 green + `bundle exec rubocop --force-exclusion <触ったファイル>`、app/ に触れたら `bin/brakeman --no-pager -q -w2`。**ステップ毎に即コミット**・不要編集は revert・コミット identity は kei1110（local 設定済み）
6. **db/schema.rb 手編集禁止**
7. rubocop へファイル明示渡しするときは **`--force-exclusion` 必須**（CLAUDE.md Gotchas）

---

### Task 1: migrations（organization_settings + reason_templates）

**Files:**
- Create: `db/migrate/<ts>_create_organization_settings.rb` / `db/migrate/<ts>_create_reason_templates.rb`（generator 生成 → 差し替え）
- 自動更新: `db/schema.rb`

- [ ] **Step 1: 生成**

Run: `bin/rails generate migration CreateOrganizationSettings && bin/rails generate migration CreateReasonTemplates`

- [ ] **Step 2: organization_settings の中身**

```ruby
class CreateOrganizationSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :organization_settings do |t|
      # テナント毎 1 行（unique index が Organization#setting の create_or_find_by! の前提・0b-5 設計 §1）
      t.references :organization, null: false, foreign_key: true, index: { unique: true }
      t.integer :closing_day, null: false, default: 31          # 締め日（31 = 月末・SPEC §4.15）
      t.integer :submit_deadline_days, null: false, default: 5  # 翌月の提出期限（日数）

      t.timestamps
    end

    # プロジェクト規約（将来の複合 FK 参照先）
    add_index :organization_settings, %i[organization_id id], unique: true
  end
end
```

- [ ] **Step 3: reason_templates の中身**

```ruby
class CreateReasonTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :reason_templates do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :label, null: false          # 管理用識別名（SPEC §4.16）
      t.string :template_text, null: false  # 挿入テキスト
      t.integer :applies_to, null: false    # enum: clock_change(0) / leave(1) / both(2)
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :reason_templates, %i[organization_id label], unique: true # マスタ name 規約と同型
    add_index :reason_templates, %i[organization_id id], unique: true
  end
end
```

- [ ] **Step 4: migrate + 確認 + commit**

Run: `bin/rails db:migrate && git diff db/schema.rb && bundle exec rspec`
Expected: schema に 2 テーブル・unique index 3 本・既存 306 examples green

```bash
git add db/migrate db/schema.rb
git commit -m "feat: organization_settings / reason_templates テーブル（消費済みカラムのみ・0b-5 設計 §1）"
```

---

### Task 2: OrganizationSetting モデル + Organization#setting アクセサ

**Files:**
- Create: `app/models/organization_setting.rb`
- Modify: `app/models/organization.rb`（has_one / has_many / #setting）
- Create: `spec/models/organization_setting_spec.rb`
- Modify: `spec/models/organization_spec.rb`（#setting の describe 追加）

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/organization_setting_spec.rb`（全文）:

```ruby
require "rails_helper"

RSpec.describe OrganizationSetting, type: :model do
  let(:setting) { ActsAsTenant.test_tenant.setting }

  describe "範囲検証" do
    it "closing_day は 1..31（境界）" do
      [ 0, 32 ].each do |v|
        setting.closing_day = v
        expect(setting).not_to be_valid
      end
      [ 1, 31 ].each do |v|
        setting.closing_day = v
        expect(setting).to be_valid
      end
    end

    it "submit_deadline_days は 1..28（境界 — 28 = 2 月の最短月長）" do
      [ 0, 29 ].each do |v|
        setting.submit_deadline_days = v
        expect(setting).not_to be_valid
      end
      [ 1, 28 ].each do |v|
        setting.submit_deadline_days = v
        expect(setting).to be_valid
      end
    end
  end

  describe "1 行制約" do
    it "同一組織の 2 行目はフォームエラー（DB 例外前に検証で止まる）" do
      setting # 1 行目を生成
      dup = OrganizationSetting.new
      expect(dup).not_to be_valid
      expect(dup.errors[:organization_id]).to be_present
    end

    it "バリデーション skip の 2 行目 INSERT は RecordNotUnique（DB 最終防衛）" do
      setting
      dup = OrganizationSetting.new
      expect { dup.save(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end
end
```

`spec/models/organization_spec.rb` の `RSpec.describe Organization` 内に追加:

```ruby
  describe "#setting（0b-5 設計 §0 のアクセサ規約）" do
    let(:org) { create(:organization) }

    it "未生成なら既定値で生成する" do
      expect { org.setting }.to change {
        OrganizationSetting.unscoped.where(organization: org).count
      }.from(0).to(1)
      expect(org.setting.closing_day).to eq(31)
      expect(org.setting.submit_deadline_days).to eq(5)
    end

    it "生成済みなら同一行を返す（重複生成しない）" do
      first = org.setting
      expect { org.setting }.not_to change { OrganizationSetting.unscoped.count }
      expect(org.setting.id).to eq(first.id)
    end

    it "テナント文脈に依らず自組織へアンカーされる（mismatched with_tenant でも安全）" do
      other = create(:organization)
      created = ActsAsTenant.with_tenant(other) { org.setting }
      expect(created.organization_id).to eq(org.id)
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/organization_setting_spec.rb spec/models/organization_spec.rb`
Expected: FAIL（`uninitialized constant OrganizationSetting` / `undefined method 'setting'`）

- [ ] **Step 3: 実装**

`app/models/organization_setting.rb`（全文）:

```ruby
class OrganizationSetting < ApplicationRecord
  # SPEC §4.15 の残カラム（通知系・閾値系・36 協定系・integer[]）は消費する Phase の PR が
  # 検証・既定値・意味論ごと同梱追加する（0b-5 設計 §0 — ROADMAP 4-1 email_enabled 方式）。
  # 法定値は本テーブルに置かない（§4.15 注記 — テナント改変可能になってはならない）
  acts_as_tenant(:organization)

  validates :closing_day, inclusion: { in: 1..31 } # 31 = 月末扱い（SPEC §4.15）
  # 28 = 2 月の最短月長 — どの月でも実在する日に収める
  validates :submit_deadline_days, inclusion: { in: 1..28 }
  # [organization_id] unique index の DB 例外前にフォームエラー化（テナント毎 1 行）
  validates :organization_id, uniqueness: true
end
```

`app/models/organization.rb` — `has_many :users, ...` の直後に追加:

```ruby
  has_many :company_calendars, dependent: :restrict_with_error
  has_one :organization_setting, dependent: :destroy
```

`fiscal_year_for` の上（public メソッド群の先頭付近）に追加:

```ruby
  # 設定行の唯一の取得経路（0b-5 設計 §0 のアクセサ規約 — Phase 2〜4 の読み取りもここを通すこと）。
  # create_or_find_by! は [organization_id] unique index 前提で並行初回アクセスの
  # SELECT→INSERT 競合を吸収する（属性なし呼び出し = DB 既定値で完結）。
  # with_tenant(self) ラップで呼び出し側のテナント文脈に依らず自組織へアンカー
  # （mismatched with_tenant でも他社行を掴まない・テナント分離レビュー Critical 反映）
  def setting
    organization_setting || ActsAsTenant.with_tenant(self) do
      OrganizationSetting.create_or_find_by!(organization: self)
    end
  end
```

- [ ] **Step 4: green 確認 + 全 suite + rubocop + commit**

Run: `bundle exec rspec spec/models/organization_setting_spec.rb spec/models/organization_spec.rb && bundle exec rspec && bundle exec rubocop --force-exclusion app/models/organization_setting.rb app/models/organization.rb spec/models/organization_setting_spec.rb spec/models/organization_spec.rb`

```bash
git add app/models/organization_setting.rb app/models/organization.rb spec/models/organization_setting_spec.rb spec/models/organization_spec.rb
git commit -m "feat: OrganizationSetting + Organization#setting アクセサ（1 行制約・テナント明示アンカー）"
```

---

### Task 3: ReasonTemplate モデル + factory + model spec

**Files:**
- Create: `app/models/reason_template.rb`
- Create: `spec/factories/reason_templates.rb`
- Create: `spec/models/reason_template_spec.rb`

- [ ] **Step 1: factory**

`spec/factories/reason_templates.rb`:

```ruby
FactoryBot.define do
  factory :reason_template do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    sequence(:label) { |n| "テンプレート#{n}" } # テナント内 unique ゆえ sequence
    template_text { "テンプレート本文" }
    applies_to { :both }
  end
end
```

- [ ] **Step 2: 失敗するテストを書く**

`spec/models/reason_template_spec.rb`（全文）:

```ruby
require "rails_helper"

RSpec.describe ReasonTemplate, type: :model do
  describe "検証" do
    it "label / template_text 必須" do
      record = build(:reason_template, label: nil, template_text: nil)
      expect(record).not_to be_valid
      expect(record.errors[:label]).to be_present
      expect(record.errors[:template_text]).to be_present
    end

    it "enum 毒値は ArgumentError でなくバリデーションエラー（validate: true）" do
      record = build(:reason_template)
      record.applies_to = "superuser"
      expect(record).not_to be_valid
      expect(record.errors[:applies_to]).to be_present
    end

    it "label はテナント内 unique・他テナント同名は許可（鏡像）" do
      create(:reason_template, label: "電車遅延")
      expect(build(:reason_template, label: "電車遅延")).not_to be_valid

      ActsAsTenant.with_tenant(create(:organization)) do
        expect(build(:reason_template, label: "電車遅延")).to be_valid
      end
    end
  end

  describe "Deactivatable 契約（0b-5 設計 §0）" do
    it "name エイリアスが label を返す（concern の record.name が 500 にならない）" do
      record = build(:reason_template, label: "電車遅延")
      expect(record.name).to eq("電車遅延")
    end
  end
end
```

- [ ] **Step 3: 失敗確認**

Run: `bundle exec rspec spec/models/reason_template_spec.rb`
Expected: FAIL（`uninitialized constant ReasonTemplate`）

- [ ] **Step 4: 実装**

`app/models/reason_template.rb`（全文）:

```ruby
class ReasonTemplate < ApplicationRecord
  acts_as_tenant(:organization)

  # Admin::Deactivatable の flash 文言は record.name 契約（concern 参照）。
  # 本マスタの表示名カラムは label（SPEC §4.16）のためエイリアスで適合させる（0b-5 設計 §0）
  alias_attribute :name, :label

  enum :applies_to, { clock_change: 0, leave: 1, both: 2 }, validate: true

  validates :label, presence: true
  validates_uniqueness_to_tenant :label
  validates :template_text, presence: true
end
```

- [ ] **Step 5: green + 全 suite + rubocop + commit**

Run: `bundle exec rspec spec/models/reason_template_spec.rb && bundle exec rspec && bundle exec rubocop --force-exclusion app/models/reason_template.rb spec/models/reason_template_spec.rb spec/factories/reason_templates.rb`

```bash
git add app/models/reason_template.rb spec/models/reason_template_spec.rb spec/factories/reason_templates.rb
git commit -m "feat: ReasonTemplate モデル（enum validate・label テナント内 unique・name エイリアス）"
```

---

### Task 4: Policy ×2 + policy spec

**Files:**
- Create: `app/policies/admin/organization_setting_policy.rb` / `app/policies/admin/reason_template_policy.rb`
- Create: `spec/policies/admin/organization_setting_policy_spec.rb` / `spec/policies/admin/reason_template_policy_spec.rb`

- [ ] **Step 1: 失敗する policy spec ×2**

`spec/policies/admin/organization_setting_policy_spec.rb`（全文）:

```ruby
require "rails_helper"

RSpec.describe Admin::OrganizationSettingPolicy, type: :policy do
  subject { described_class.new(actor, setting) }

  let(:setting) { ActsAsTenant.test_tenant.setting }

  context "hr_admin" do
    let(:actor) { create(:user, :hr_admin) }
    it { is_expected.to permit_actions(%i[edit update]) }
    it "index?/show?/destroy? は既定 deny のまま（singleton — 開けない）" do
      expect(subject.index?).to be(false)
      expect(subject.show?).to be(false)
      expect(subject.destroy?).to be(false)
    end
  end

  context "manager" do
    let(:actor) { create(:user, :manager_role) }
    it { is_expected.to forbid_actions(%i[edit update]) }
  end

  context "employee" do
    let(:actor) { create(:user) }
    it { is_expected.to forbid_actions(%i[edit update]) }
  end
end
```

`spec/policies/admin/reason_template_policy_spec.rb`（全文）:

```ruby
require "rails_helper"

RSpec.describe Admin::ReasonTemplatePolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let(:record) { create(:reason_template) }

  context "hr_admin" do
    let(:actor) { create(:user, :hr_admin) }
    it { is_expected.to permit_actions(%i[index show new create edit update deactivate activate]) }
    it "destroy は不可（無効化のみ方針の固定）" do
      expect(subject.destroy?).to be(false)
    end
  end

  context "manager" do
    let(:actor) { create(:user, :manager_role) }
    it { is_expected.to forbid_actions(%i[index show new create edit update deactivate activate]) }
  end

  context "employee" do
    let(:actor) { create(:user) }
    it { is_expected.to forbid_actions(%i[index show new create edit update deactivate activate]) }
  end

  describe "Scope" do
    it "組織全件（inactive 含む）・他テナント漏れなし" do
      actor    = create(:user, :hr_admin)
      inactive = create(:reason_template, active: false)
      ActsAsTenant.with_tenant(create(:organization)) { create(:reason_template) }

      resolved = described_class::Scope.new(actor, ReasonTemplate.all).resolve
      expect(resolved).to contain_exactly(record, inactive)
    end

    it "without_tenant 文脈でも自組織のみ（organization_id 明示の fail-open 検出）" do
      actor = create(:user, :hr_admin)
      record # 生成
      ActsAsTenant.with_tenant(create(:organization)) { create(:reason_template) }

      resolved = ActsAsTenant.without_tenant do
        described_class::Scope.new(actor, ReasonTemplate.all).resolve.to_a
      end
      expect(resolved).to contain_exactly(record)
    end
  end
end
```

- [ ] **Step 2: 失敗確認**

Run: `bundle exec rspec spec/policies/admin/organization_setting_policy_spec.rb spec/policies/admin/reason_template_policy_spec.rb`
Expected: FAIL（uninitialized constant ×2）

- [ ] **Step 3: 実装**

`app/policies/admin/organization_setting_policy.rb`（全文）:

```ruby
module Admin
  # singleton 設定画面（0b-2 設計 §0 が予告した「異型」— MasterPolicy 非継承の個別判断）。
  # 本ポリシーは設定画面アグリゲート（OrganizationSetting + Organization.fiscal_year_end_month）の
  # 認可を所掌する — Organization 側の更新も update? が宣言的に代理（0b-5 設計 §4）。
  # Scope は定義しない: index 不在・verify_policy_scoped は index のみ強制・誤って policy_scope を
  # 呼べば Pundit::NotDefinedError で fail-closed。テナント安全の補償統制は controller の
  # current_tenant 固定取得に在る。将来 show/一覧系を足すなら Scope 追加が必須
  class OrganizationSettingPolicy < ApplicationPolicy
    def edit? = update?
    def update? = user.hr_admin?
  end
end
```

`app/policies/admin/reason_template_policy.rb`（全文）:

```ruby
module Admin
  class ReasonTemplatePolicy < MasterPolicy
  end
end
```

- [ ] **Step 4: green + rubocop + commit**

Run: `bundle exec rspec spec/policies/admin/organization_setting_policy_spec.rb spec/policies/admin/reason_template_policy_spec.rb && bundle exec rubocop --force-exclusion app/policies/admin/organization_setting_policy.rb app/policies/admin/reason_template_policy.rb spec/policies/admin/organization_setting_policy_spec.rb spec/policies/admin/reason_template_policy_spec.rb`

```bash
git add app/policies/admin/ spec/policies/admin/
git commit -m "feat: OrganizationSettingPolicy（singleton 異型）+ ReasonTemplatePolicy（MasterPolicy 継承）"
```

---

### Task 5: OrganizationSettings::Updater サービス + service spec

**Files:**
- Create: `app/services/organization_settings/updater.rb`
- Create: `spec/services/organization_settings/updater_spec.rb`

- [ ] **Step 1: 失敗する service spec**

`spec/services/organization_settings/updater_spec.rb`（全文）:

```ruby
require "rails_helper"

RSpec.describe OrganizationSettings::Updater do
  let(:org) { ActsAsTenant.test_tenant } # fiscal_year_end_month 既定 3

  def call(org_params: {}, setting_params: {})
    described_class.call(organization: org,
                         organization_params: org_params, setting_params: setting_params)
  end

  describe "成功経路" do
    it "決算月変更で既存カレンダーの fiscal_year を再計算し実変更数を返す" do
      calendar = create(:company_calendar, date: Date.new(2026, 1, 15)) # 3 月決算 → "2025"
      expect(calendar.fiscal_year).to eq("2025")

      result = call(org_params: { fiscal_year_end_month: 12 }) # 1 月始まり → "2026"
      expect(result.success?).to be(true)
      expect(result.recalculated_count).to eq(1)
      expect(calendar.reload.fiscal_year).to eq("2026")
    end

    it "決算月が変わらない保存では再計算しない（カウント 0・カレンダー不変）" do
      calendar = create(:company_calendar, date: Date.new(2026, 1, 15))

      result = call(setting_params: { closing_day: 25 })
      expect(result.success?).to be(true)
      expect(result.recalculated_count).to eq(0)
      expect(calendar.reload.fiscal_year).to eq("2025")
      expect(org.setting.reload.closing_day).to eq(25)
    end

    it "再計算しても fiscal_year が同値の行は実変更数に数えない" do
      create(:company_calendar, date: Date.new(2026, 1, 15))  # 3 月決算 "2025" → 6 月決算でも "2025"
      create(:company_calendar, date: Date.new(2026, 10, 1))  # "2026" → 6 月決算 "2026"（不変）

      result = call(org_params: { fiscal_year_end_month: 6 })
      expect(result.success?).to be(true)
      expect(result.recalculated_count).to eq(0) # 月は変わったが年度ラベルは両行とも同値
    end
  end

  describe "失敗経路" do
    it "両モデルの検証エラーを同時に集める（& の非短絡）" do
      result = call(org_params: { fiscal_year_end_month: 13 }, setting_params: { closing_day: 0 })
      expect(result.success?).to be(false)
      expect(result.organization.errors[:fiscal_year_end_month]).to be_present
      expect(result.setting.errors[:closing_day]).to be_present
      expect(org.reload.fiscal_year_end_month).to eq(3) # 保存されていない
    end

    it "再計算中の RecordInvalid は全体を巻き戻し failure（500 にしない 422 合流）" do
      create(:company_calendar, date: Date.new(2026, 1, 15))
      allow_any_instance_of(CompanyCalendar).to receive(:save!)
        .and_raise(ActiveRecord::RecordInvalid.new(CompanyCalendar.new))

      result = call(org_params: { fiscal_year_end_month: 12 })
      expect(result.success?).to be(false)
      expect(result.organization.errors[:base].join).to include("取り消しました")
      expect(org.reload.fiscal_year_end_month).to eq(3) # tx rollback 済み
    end
  end

  describe "テナント自己完結（SPEC §3.6）" do
    it "他テナントのカレンダーは再計算しない" do
      other_org = create(:organization)
      other_cal = ActsAsTenant.with_tenant(other_org) do
        create(:company_calendar, date: Date.new(2026, 1, 15))
      end

      call(org_params: { fiscal_year_end_month: 12 })
      expect(other_cal.reload.fiscal_year).to eq("2025") # 不変
    end
  end
end
```

- [ ] **Step 2: 失敗確認**

Run: `bundle exec rspec spec/services/organization_settings/updater_spec.rb`
Expected: FAIL（`uninitialized constant OrganizationSettings`）

- [ ] **Step 3: 実装**

`app/services/organization_settings/updater.rb`（全文）:

```ruby
module OrganizationSettings
  # 設定画面アグリゲートの更新（0b-5 設計 §3）: Organization.fiscal_year_end_month +
  # OrganizationSetting を単一 tx で保存し、決算月が変わったときだけ CompanyCalendar の
  # fiscal_year を再計算する。
  #
  # 前提（Pragma レビュー Critical の回避）: organization には ActsAsTenant.current_tenant の
  # インスタンスを渡すこと（controller が固定）。acts_as_tenant は organization_id 一致時に
  # DB を読まず current_tenant を返すため、再計算中の cal.organization も本インスタンス
  # （更新後の月）を見る — 旧値混入と N+1 SELECT が同時に消える。
  # with_tenant で自己完結: console/将来ジョブから呼ばれても自社の行しか触れない（SPEC §3.6）
  class Updater
    Result = Data.define(:success, :recalculated_count, :organization, :setting) do
      def success? = success
    end

    def self.call(organization:, organization_params:, setting_params:)
      new(organization, organization_params, setting_params).call
    end

    def initialize(organization, organization_params, setting_params)
      @organization = organization
      @setting = organization.setting
      @organization_params = organization_params
      @setting_params = setting_params
    end

    def call
      @organization.assign_attributes(@organization_params)
      @setting.assign_attributes(@setting_params)
      # & で両方の valid? を必ず評価する（&& は短絡して 2 モデル目のエラーが集まらない）
      return failure unless @organization.valid? & @setting.valid?

      count = 0
      ActsAsTenant.with_tenant(@organization) do
        ApplicationRecord.transaction do
          @organization.save!
          @setting.save!
          count = recalculate_fiscal_years if @organization.saved_change_to_fiscal_year_end_month?
        end
      end
      Result.new(success: true, recalculated_count: count,
                 organization: @organization, setting: @setting)
    rescue ActiveRecord::RecordInvalid => e
      # 既存カレンダーの再検証失敗で設定更新ごと巻き戻す（500 にしない 422 合流・設計 §3-4）
      @organization.errors.add(
        :base,
        "会社カレンダーの再検証に失敗したため変更を取り消しました: #{e.record.errors.full_messages.join('。')}"
      )
      failure
    end

    private

    # save! を通す（update_all/update_column はバリデーション・コールバックバイパス規約で不採用。
    # CompanyCalendar#set_fiscal_year（before_validation/before_save）が date から再導出する）。
    # 実変更数 = fiscal_year が実際に変わった行のみ（no-op save は UPDATE を発行しない）
    def recalculate_fiscal_years
      count = 0
      @organization.company_calendars.find_each do |calendar|
        calendar.save!
        count += 1 if calendar.saved_changes.key?("fiscal_year")
      end
      count
    end

    def failure
      Result.new(success: false, recalculated_count: 0,
                 organization: @organization, setting: @setting)
    end
  end
end
```

- [ ] **Step 4: green + 全 suite + rubocop + commit**

Run: `bundle exec rspec spec/services/organization_settings/updater_spec.rb && bundle exec rspec && bundle exec rubocop --force-exclusion app/services/organization_settings/updater.rb spec/services/organization_settings/updater_spec.rb`

```bash
git add app/services/organization_settings/ spec/services/organization_settings/
git commit -m "feat: OrganizationSettings::Updater（単一 tx・fiscal_year 再計算・Result）"
```

---

### Task 6: OrganizationSettingsController + ルート + edit ビュー + ja.yml + request spec

**Files:**
- Modify: `config/routes.rb` / `config/locales/ja.yml`
- Create: `app/controllers/admin/organization_settings_controller.rb`
- Create: `app/views/admin/organization_settings/edit.html.erb`
- Create: `spec/requests/admin_organization_settings_spec.rb`

- [ ] **Step 1: ルート追加**

`config/routes.rb` の `namespace :admin do` 内・`resources :company_calendars` ブロックの後に追加:

```ruby
    resource :organization_setting, only: %i[edit update] # singular（0b-5 設計 §4）
```

- [ ] **Step 2: ja.yml 追加**

`models:` に追加:

```yaml
      organization_setting: 組織設定
```

`attributes:` に追加（既存ブロックの末尾）:

```yaml
      organization:
        fiscal_year_end_month: 年度終了月
      organization_setting:
        closing_day: 締め日
        submit_deadline_days: 提出期限（翌月の日数）
```

- [ ] **Step 3: 失敗する request spec**

`spec/requests/admin_organization_settings_spec.rb`（全文）:

```ruby
require "rails_helper"

RSpec.describe "Admin::OrganizationSettings", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") } # fiscal_year_end_month 既定 3
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }

  describe "認可" do
    it "未認証はサインインへ・employee は 403・hr_admin は 200（対照）" do
      get edit_admin_organization_setting_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get edit_admin_organization_setting_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get edit_admin_organization_setting_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end
  end

  describe "lazy 生成（Organization#setting 経由）" do
    before { sign_in admin }

    it "初回 edit で設定行が生成され、2 回目は増えない（対照）" do
      expect {
        get edit_admin_organization_setting_url(host: tenant_host(org))
      }.to change { OrganizationSetting.unscoped.where(organization: org).count }.from(0).to(1)

      expect {
        get edit_admin_organization_setting_url(host: tenant_host(org))
      }.not_to change { OrganizationSetting.unscoped.count }
    end
  end

  describe "更新（hr_admin）" do
    before { sign_in admin }

    it "決算月変更で既存カレンダーの fiscal_year の値が実際に変わる + 実変更数 flash（Pragma Critical の唯一の網）" do
      calendar = ActsAsTenant.with_tenant(org) { create(:company_calendar, date: Date.new(2026, 1, 15)) }
      expect(calendar.fiscal_year).to eq("2025")

      patch admin_organization_setting_url(host: tenant_host(org)), params: {
        organization: { fiscal_year_end_month: 12 },
        organization_setting: { closing_day: 31, submit_deadline_days: 5 }
      }
      expect(response).to redirect_to(edit_admin_organization_setting_url(host: tenant_host(org)))
      expect(response).to have_http_status(:see_other)
      expect(calendar.reload.fiscal_year).to eq("2026")
      follow_redirect!
      expect(response.body).to include("会社カレンダー 1 件の年度を再計算しました")
    end

    it "決算月が変わらない保存は再計算文言を出さない（対照）" do
      calendar = ActsAsTenant.with_tenant(org) { create(:company_calendar, date: Date.new(2026, 1, 15)) }

      patch admin_organization_setting_url(host: tenant_host(org)), params: {
        organization: { fiscal_year_end_month: 3 },
        organization_setting: { closing_day: 25, submit_deadline_days: 5 }
      }
      expect(calendar.reload.fiscal_year).to eq("2025")
      follow_redirect!
      expect(response.body).to include("設定を保存しました")
      expect(response.body).not_to include("再計算しました")
    end

    it "失敗 422: 両モデルのエラーが表示され入力保持" do
      patch admin_organization_setting_url(host: tenant_host(org)), params: {
        organization: { fiscal_year_end_month: 13 },
        organization_setting: { closing_day: 0, submit_deadline_days: 5 }
      }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("年度終了月").and include("締め日")
      expect(org.reload.fiscal_year_end_month).to eq(3) # 未保存
    end

    it "permit 境界（allowlist）: 編集可 3 項目以外は全て無視される" do
      patch admin_organization_setting_url(host: tenant_host(org)), params: {
        organization: { fiscal_year_end_month: 12, subdomain: "evil", active: false,
                        time_zone: "UTC", name: "乗っ取り" },
        organization_setting: { closing_day: 25, submit_deadline_days: 5, organization_id: 0 }
      }
      expect(response).to have_http_status(:see_other)
      org.reload
      expect(org.subdomain).to eq("acme")
      expect(org.active).to be(true)
      expect(org.time_zone).to eq("Asia/Tokyo")
      expect(org.fiscal_year_end_month).to eq(12) # 許可項目だけ通る
      setting = OrganizationSetting.unscoped.find_by!(organization: org)
      expect(setting.closing_day).to eq(25)
      expect(setting.organization_id).to eq(org.id)
    end
  end
end
```

- [ ] **Step 4: 失敗確認**

Run: `bundle exec rspec spec/requests/admin_organization_settings_spec.rb`
Expected: FAIL（ルート/コントローラ不在）

- [ ] **Step 5: コントローラ実装**

`app/controllers/admin/organization_settings_controller.rb`（全文）:

```ruby
module Admin
  # 設定画面（singular・0b-5 設計 §4）。組織は current_tenant のインスタンスに固定 —
  # params 由来の組織解決経路を持たない（IDOR 不能 + acts_as_tenant のリーダー短絡により
  # Updater の再計算が必ず更新後の決算月を見る・Pragma レビュー Critical の回避）
  class OrganizationSettingsController < BaseController
    before_action :set_models

    def edit
      authorize [ :admin, @organization_setting ]
    end

    def update
      authorize [ :admin, @organization_setting ]
      result = OrganizationSettings::Updater.call(
        organization: @organization,
        organization_params: organization_params,
        setting_params: organization_setting_params
      )
      if result.success?
        redirect_to edit_admin_organization_setting_path, status: :see_other,
                    notice: update_notice(result)
      else
        # failure 時 @organization（= current_tenant）の dirty 値は in-memory に残るが、
        # 本画面の再描画経路で組織属性を計算に使うコードは無い（0b-5 設計 §3 で受容。
        # 将来レイアウトが組織属性を計算へ使うなら再考）
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_models
      @organization = ActsAsTenant.current_tenant
      @organization_setting = @organization.setting
    end

    def update_notice(result)
      if result.recalculated_count.positive?
        "年度終了月を変更し、会社カレンダー #{result.recalculated_count} 件の年度を再計算しました"
      else
        "設定を保存しました"
      end
    end

    # 編集可は 3 項目のみ（allowlist）。subdomain（テナント識別子）・active（自社ロックアウト）・
    # time_zone・organization_id は構造的に不通過（0b-5 設計 §4・テナント分離レビュー High）
    def organization_params
      params.require(:organization).permit(:fiscal_year_end_month)
    end

    def organization_setting_params
      params.require(:organization_setting).permit(:closing_day, :submit_deadline_days)
    end
  end
end
```

- [ ] **Step 6: ビュー実装**

`app/views/admin/organization_settings/edit.html.erb`（全文）:

```erb
<h2 class="mb-4 text-lg font-bold">設定</h2>
<%# singular resource は polymorphic ルーティング解決が壊れるため url: 明示必須（0b-5 設計 §5） %>
<%= form_with model: @organization_setting, url: admin_organization_setting_path, method: :patch,
      class: "max-w-md space-y-6 text-sm" do |f| %>
  <% if @organization.errors.any? || @organization_setting.errors.any? %>
    <div class="rounded border border-red-400 bg-red-50 p-3 text-red-800">
      <ul>
        <% (@organization.errors.full_messages + @organization_setting.errors.full_messages).each do |msg| %>
          <li><%= msg %></li>
        <% end %>
      </ul>
    </div>
  <% end %>

  <fieldset class="space-y-4">
    <legend class="font-bold">組織情報</legend>
    <%# トップレベル fields_for → params[:organization]（別 param キー方式・0b-5 設計 §5） %>
    <%= fields_for :organization, @organization do |of| %>
      <div>
        <%= of.label :fiscal_year_end_month, "年度終了月", class: "block font-bold" %>
        <%= of.select :fiscal_year_end_month, (1..12).map { |m| [ "#{m} 月", m ] }, {},
              class: "w-full rounded border p-2" %>
        <p class="mt-1 text-xs text-gray-600">変更すると、登録済みの会社カレンダー全件の年度を再計算します。</p>
      </div>
    <% end %>
  </fieldset>

  <fieldset class="space-y-4">
    <legend class="font-bold">勤怠設定</legend>
    <div>
      <%= f.label :closing_day, "締め日", class: "block font-bold" %>
      <%= f.number_field :closing_day, min: 1, max: 31, class: "w-full rounded border p-2" %>
      <p class="mt-1 text-xs text-gray-600">31 = 月末締め</p>
    </div>
    <div>
      <%= f.label :submit_deadline_days, "提出期限（翌月の日数）", class: "block font-bold" %>
      <%= f.number_field :submit_deadline_days, min: 1, max: 28, class: "w-full rounded border p-2" %>
    </div>
  </fieldset>

  <%= f.submit "保存する", class: "rounded bg-gray-800 px-4 py-2 text-white" %>
<% end %>
```

- [ ] **Step 7: green + 全 suite + rubocop + brakeman + commit**

Run: `bundle exec rspec spec/requests/admin_organization_settings_spec.rb && bundle exec rspec && bundle exec rubocop --force-exclusion app/controllers/admin/organization_settings_controller.rb config/routes.rb && bin/brakeman --no-pager -q -w2`

```bash
git add config/routes.rb config/locales/ja.yml app/controllers/admin/organization_settings_controller.rb app/views/admin/organization_settings/ spec/requests/admin_organization_settings_spec.rb
git commit -m "feat: 組織設定画面（singular・current_tenant 固定・年度再計算 flash・allowlist permit）"
```

---

### Task 7: ReasonTemplates 一式（ルート・コントローラ・ビュー・ナビ・ja.yml・request spec）

> **実行ノート（折衷案）: 本タスクは Codex への試験委託対象**（0b-2 LeaveType の機械的同型 — 計画コードの転写 + 検証が中心）。Codex が利用不能・失敗した場合は通常のサブエージェントへフォールバック。

**Files:**
- Modify: `config/routes.rb` / `config/locales/ja.yml` / `app/helpers/application_helper.rb` / `app/components/admin/nav_component.rb`
- Create: `app/controllers/admin/reason_templates_controller.rb`
- Create: `app/views/admin/reason_templates/`（index / show / new / edit / _form）
- Create: `spec/requests/admin_reason_templates_spec.rb`

- [ ] **Step 1: ルート + ナビ + ja.yml + ヘルパ**

`config/routes.rb` — `resource :organization_setting` の前に追加:

```ruby
    resources :reason_templates, except: :destroy do
      member do
        patch :deactivate
        patch :activate
      end
    end
```

`app/components/admin/nav_component.rb` の tabs に 2 行追加（「会社カレンダー」の後）:

```ruby
        [ "理由テンプレート", helpers.admin_reason_templates_path ],
        [ "設定", helpers.edit_admin_organization_setting_path ]
```

`config/locales/ja.yml` — `models:` に `reason_template: 申請理由テンプレート`、`attributes:` に:

```yaml
      reason_template:
        label: テンプレート名
        template_text: 挿入テキスト
        applies_to: 適用先
        active: 有効
```

トップレベル（`company_calendars:` ブロックの後）に:

```yaml
  reason_templates:
    applies_to:
      clock_change: 打刻変更
      leave: 休暇
      both: 両方
```

`app/helpers/application_helper.rb` に追加:

```ruby
  def t_applies_to(value) = I18n.t("reason_templates.applies_to.#{value}")
```

- [ ] **Step 2: 失敗する request spec**

`spec/requests/admin_reason_templates_spec.rb`（全文）:

```ruby
require "rails_helper"

RSpec.describe "Admin::ReasonTemplates", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:template) { ActsAsTenant.with_tenant(org) { create(:reason_template, label: "電車遅延", applies_to: :clock_change) } }

  describe "認可" do
    it "未認証はサインインへ・employee は 403・hr_admin は 200（対照）" do
      get admin_reason_templates_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get admin_reason_templates_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get admin_reason_templates_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "一覧は enum を日本語表示し inactive も並ぶ・生値を露出しない" do
      retired = ActsAsTenant.with_tenant(org) { create(:reason_template, label: "旧テンプレ", active: false) }
      get admin_reason_templates_url(host: tenant_host(org))
      expect(response.body).to include("電車遅延").and include("旧テンプレ").and include("打刻変更")
      expect(response.body).not_to include("clock_change")
    end

    it "作成できる（303 → show）" do
      post admin_reason_templates_url(host: tenant_host(org)), params: { reason_template: {
        label: "私用", template_text: "私用のため", applies_to: "both" } }
      created = ActsAsTenant.with_tenant(org) { ReasonTemplate.find_by!(label: "私用") }
      expect(response).to redirect_to(admin_reason_template_url(created, host: tenant_host(org)))
      expect(response).to have_http_status(:see_other)
    end

    it "label 重複は 422 + 件数不変" do
      expect {
        post admin_reason_templates_url(host: tenant_host(org)), params: { reason_template: {
          label: "電車遅延", template_text: "x", applies_to: "leave" } }
      }.not_to change { ActsAsTenant.with_tenant(org) { ReasonTemplate.count } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "enum 毒値は 422（500 にならない）" do
      post admin_reason_templates_url(host: tenant_host(org)), params: { reason_template: {
        label: "毒", template_text: "x", applies_to: "superuser" } }
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "更新できる" do
      patch admin_reason_template_url(template, host: tenant_host(org)), params: { reason_template: {
        label: "電車遅延", template_text: "電車遅延のため出社が遅れました", applies_to: "clock_change" } }
      expect(response).to have_http_status(:see_other)
      expect(template.reload.template_text).to eq("電車遅延のため出社が遅れました")
    end

    it "permit 境界: active / organization_id を送っても無視される" do
      other_org = create(:organization)
      patch admin_reason_template_url(template, host: tenant_host(org)), params: { reason_template: {
        label: "電車遅延", template_text: "x", applies_to: "clock_change",
        active: false, organization_id: other_org.id } }
      template.reload
      expect(template.active).to be(true)
      expect(template.organization_id).to eq(org.id)
    end
  end

  describe "IDOR" do
    before { sign_in admin }

    it "他テナント id は 404" do
      foreign = ActsAsTenant.with_tenant(create(:organization)) { create(:reason_template) }
      get admin_reason_template_url(foreign, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "deactivate / activate（Deactivatable + name エイリアス）" do
    before { sign_in admin }

    it "無効化 → flash に label が表示される（record.name 契約の固定）" do
      patch deactivate_admin_reason_template_url(template, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(template.reload.active).to be(false)
      follow_redirect!
      expect(response.body).to include("電車遅延 を無効化しました")
    end

    it "再有効化できる" do
      template.update!(active: false)
      patch activate_admin_reason_template_url(template, host: tenant_host(org))
      expect(template.reload.active).to be(true)
    end
  end
end
```

注: `template.update!(active: false)` は request spec のテナント未設定文脈で `NoTenantSet` になる場合 `ActsAsTenant.with_tenant(org) { ... }` で包むこと（ReasonTemplate の検証はスコープ依存クエリ — validates_uniqueness_to_tenant — を持つため必要）。

- [ ] **Step 3: 失敗確認**

Run: `bundle exec rspec spec/requests/admin_reason_templates_spec.rb`
Expected: FAIL（ルート不在）

- [ ] **Step 4: コントローラ実装**

`app/controllers/admin/reason_templates_controller.rb`（全文 — LeaveTypesController 同型）:

```ruby
module Admin
  class ReasonTemplatesController < BaseController
    include Admin::Deactivatable

    before_action :set_reason_template, only: %i[show edit update deactivate activate]

    def index
      authorize [ :admin, ReasonTemplate ]
      @reason_templates = policy_scope([ :admin, ReasonTemplate ]).order(:label)
    end

    def show
      authorize [ :admin, @reason_template ]
    end

    def new
      @reason_template = ReasonTemplate.new
      authorize [ :admin, @reason_template ]
    end

    def create
      @reason_template = ReasonTemplate.new(reason_template_params)
      authorize [ :admin, @reason_template ]
      if @reason_template.save
        redirect_to admin_reason_template_path(@reason_template), status: :see_other,
                    notice: "#{@reason_template.label} を登録しました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @reason_template ]
    end

    def update
      authorize [ :admin, @reason_template ]
      if @reason_template.update(reason_template_params)
        redirect_to admin_reason_template_path(@reason_template), status: :see_other, notice: "更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    # 他テナント id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_reason_template
      @reason_template = policy_scope([ :admin, ReasonTemplate ]).find(params[:id])
    end

    def deactivatable_record = @reason_template

    # active / organization_id は permit しない（マスタ規約）
    def reason_template_params
      params.require(:reason_template).permit(:label, :template_text, :applies_to)
    end
  end
end
```

- [ ] **Step 5: ビュー実装（5 ファイル）**

`app/views/admin/reason_templates/index.html.erb`:

```erb
<div class="mb-4 flex justify-between">
  <h2 class="text-lg font-bold">申請理由テンプレート</h2>
  <%= link_to "新規登録", new_admin_reason_template_path, class: "rounded bg-gray-800 px-4 py-2 text-white" %>
</div>

<table class="w-full text-left text-sm">
  <thead>
    <tr class="border-b font-bold">
      <th class="p-2">テンプレート名</th><th class="p-2">適用先</th>
      <th class="p-2">挿入テキスト</th><th class="p-2">状態</th>
    </tr>
  </thead>
  <tbody>
    <% @reason_templates.each do |rt| %>
      <tr class="border-b">
        <td class="p-2"><%= link_to rt.label, admin_reason_template_path(rt), class: "underline" %></td>
        <td class="p-2"><%= t_applies_to(rt.applies_to) %></td>
        <td class="p-2"><%= rt.template_text %></td>
        <td class="p-2"><%= rt.active? ? "有効" : "無効" %></td>
      </tr>
    <% end %>
  </tbody>
</table>
```

`app/views/admin/reason_templates/show.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold"><%= @reason_template.label %></h2>
<dl class="space-y-2 text-sm">
  <div><dt class="inline font-bold">適用先:</dt> <dd class="inline"><%= t_applies_to(@reason_template.applies_to) %></dd></div>
  <div><dt class="inline font-bold">挿入テキスト:</dt> <dd class="inline"><%= @reason_template.template_text %></dd></div>
  <div><dt class="inline font-bold">状態:</dt> <dd class="inline"><%= @reason_template.active? ? "有効" : "無効" %></dd></div>
</dl>
<div class="mt-6 flex gap-2">
  <%= link_to "編集", edit_admin_reason_template_path(@reason_template), class: "rounded border px-4 py-2" %>
  <% if @reason_template.active? %>
    <%= button_to "無効化", deactivate_admin_reason_template_path(@reason_template), method: :patch,
          data: { turbo_confirm: "#{@reason_template.label} を無効化しますか？" },
          class: "rounded bg-red-700 px-4 py-2 text-white" %>
  <% else %>
    <%= button_to "再有効化", activate_admin_reason_template_path(@reason_template), method: :patch,
          class: "rounded bg-gray-800 px-4 py-2 text-white" %>
  <% end %>
</div>
```

`app/views/admin/reason_templates/_form.html.erb`:

```erb
<%= form_with model: [ :admin, reason_template ], class: "max-w-md space-y-4 text-sm" do |f| %>
  <% if reason_template.errors.any? %>
    <div class="rounded border border-red-400 bg-red-50 p-3 text-red-800">
      <ul><% reason_template.errors.full_messages.each do |msg| %><li><%= msg %></li><% end %></ul>
    </div>
  <% end %>

  <div><%= f.label :label, class: "block font-bold" %><%= f.text_field :label, class: "w-full rounded border p-2" %></div>
  <div>
    <%= f.label :applies_to, class: "block font-bold" %>
    <%= f.select :applies_to,
          ReasonTemplate.applies_tos.keys.map { |k| [ t_applies_to(k), k ] }, {},
          class: "w-full rounded border p-2" %>
  </div>
  <div><%= f.label :template_text, class: "block font-bold" %><%= f.text_area :template_text, rows: 3, class: "w-full rounded border p-2" %></div>
  <%= f.submit reason_template.persisted? ? "更新する" : "登録する", class: "rounded bg-gray-800 px-4 py-2 text-white" %>
<% end %>
```

`app/views/admin/reason_templates/new.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold">申請理由テンプレートの新規登録</h2>
<%= render "form", reason_template: @reason_template %>
```

`app/views/admin/reason_templates/edit.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold"><%= @reason_template.label %> の編集</h2>
<%= render "form", reason_template: @reason_template %>
```

- [ ] **Step 6: green + 全 suite + rubocop + brakeman + commit**

Run: `bundle exec rspec spec/requests/admin_reason_templates_spec.rb && bundle exec rspec && bundle exec rubocop --force-exclusion app/controllers/admin/reason_templates_controller.rb app/helpers/application_helper.rb app/components/admin/nav_component.rb config/routes.rb && bin/brakeman --no-pager -q -w2`

```bash
git add config/routes.rb config/locales/ja.yml app/helpers/application_helper.rb app/components/admin/nav_component.rb app/controllers/admin/reason_templates_controller.rb app/views/admin/reason_templates/ spec/requests/admin_reason_templates_spec.rb
git commit -m "feat: 申請理由テンプレート CRUD（0b-2 同型・name エイリアスで Deactivatable 適合）+ ナビ 2 タブ"
```

注: `ReasonTemplate.applies_tos`（enum 複数形）は Rails の自動生成名。`applies_to` の複数形が不自然な場合でも Rails の規約名をそのまま使う（独自メソッドを足さない）。

---

### Task 8: seeds + docs 逆反映

**Files:**
- Modify: `db/seeds.rb` / `spec/seeds_spec.rb`
- Modify: `docs/SPEC.md`（§4.15 注記 + §16.7-2 注記）
- Modify: `docs/LABOR_LAW_REVIEW_NOTES.md`（#13）
- Modify: `docs/ROADMAP.md`（バックログ 2 件）

- [ ] **Step 1: seeds 追加**

`db/seeds.rb` — CompanyCalendar ブロックの後（`puts` の前）に追加:

```ruby
    # 組織設定（0b-5）— アクセサ経由で既定値生成（冪等・§16.7-2）
    org.setting

    # 申請理由テンプレート（0b-5・dev 用。§16.7 本番手順には含めない — Phase 2 チップ UI で見直し）
    ReasonTemplate.find_or_create_by!(label: "電車遅延") do |rt|
      rt.template_text = "電車遅延のため"
      rt.applies_to = :clock_change
    end
    ReasonTemplate.find_or_create_by!(label: "私用") do |rt|
      rt.template_text = "私用のため"
      rt.applies_to = :both
    end
```

`spec/seeds_spec.rb` の counts 配列に `OrganizationSetting.count` と `ReasonTemplate.count` を追加（既存の UserWorkPattern.count 追加と同じ形）。

- [ ] **Step 2: 冪等確認**

Run: `bin/rails db:seed && bin/rails db:seed && bundle exec rspec`
Expected: 2 回連続成功 + 全 green

- [ ] **Step 3: SPEC §4.15 へ実装状況注記を追加**

`docs/SPEC.md` の §4.15 冒頭段落（「テナントごとに 1 行。…管理者が管理画面から編集。」）の直後に追加:

```markdown
> **実装状況（0b-5）:** 実装済みカラムは `closing_day` / `submit_deadline_days` のみ。**残カラムは消費する Phase の PR が検証・既定値・意味論ごと同梱追加する**（ROADMAP 4-1 `email_enabled` 方式）。36 協定系 4 カラムは Phase 4-3 で法定定数モジュールと同一 PR（参考閾値 ≤ 法定の検証 + DB CHECK + `alert_` リネームの要否をそこで判断）。設定行の読み取りは **`Organization#setting` 経由のみ**（未生成なら既定値で lazy 生成 — §16.7-2 の「既定値で生成」はこのアクセサ + seeds が実装）。`fiscal_year_end_month` の変更は保存と同一 tx で既存 CompanyCalendar.fiscal_year を自動再計算する（対象は CompanyCalendar のみ。LeaveBalance / MonthlyAttendanceSummary 出現時は経過措置を再設計 — 社労士確認 #13・Phase 2-2 着手が再判断トリガー）。
```

同 § のテーブル内 `fiscal_year_end_month` 行の「変更時の既存 fiscal_year 再計算は 0b-5 で判断」を「変更時は既存 CompanyCalendar.fiscal_year を同一 tx で自動再計算（0b-5 で確定・上記注記）」へ置換。

- [ ] **Step 4: NOTES #13 追記**

`docs/LABOR_LAW_REVIEW_NOTES.md` の表に #10〜#12 と同形式で追加。内容:

> **#13 年度終了月変更と 36 協定対象期間（§4.15・0b-5）** — (a) 36 協定の年 360h/720h/年 6 回の「1 年」の起算日は協定対象期間か会社年度か。年度終了月を期中変更した場合の短縮年度における年間上限・回数の数え方（按分／旧期間で締め切り）。労基法 36 条 4–6 項は対象期間の起算を協定記載事項に委ねており条文だけでは確定しない（指針・様式第 9 号の記載要領は MCP 対象外） (b) carry_over_limit（Phase 4-4 でカラム追加予定）の適法下限 — 比例付与者・法定超付与分の繰越の扱い。出典: 労基法 36 条 4–6 項（既存照合記録 2026-06-09 依拠・最終確定前に再照合）

- [ ] **Step 5: ROADMAP バックログ 2 件追加**

「横断バックログ」末尾:

```markdown
- [ ] **fiscal_year_end_month の変更禁止への格上げ**: 0b-5 は CompanyCalendar の自動再計算で出荷。**Phase 2-2（LeaveBalance）着手時に「残高が存在したら変更禁止」へ格上げを再判断**（0b-5 設計 §0・社労士確認 #13）
- [ ] **organization_settings 残カラムの追加様式**: 消費する Phase の PR が検証・既定値・意味論ごと同梱（4-1 email_enabled 方式）。36 協定系 4 カラムは Phase 4-3 で法定定数モジュールと同一 PR — 参考閾値 ≤ 法定の検証 + DB CHECK + `alert_` リネーム + 「ComplianceService が本テーブルを読まない」ガード spec の重装備セット（0b-5 労務レビュー High）
```

- [ ] **Step 6: Commit**

```bash
git add db/seeds.rb spec/seeds_spec.rb docs/SPEC.md docs/LABOR_LAW_REVIEW_NOTES.md docs/ROADMAP.md
git commit -m "docs: SPEC §4.15 実装状況注記 + NOTES #13 + ROADMAP バックログ 2 件 + seeds（設定 + テンプレート）"
```

---

### Task 9: 最終ゲート（静的検証・専門レビュアー・PR）

- [ ] **Step 1:** `bundle exec rspec && bundle exec rubocop --force-exclusion && bin/brakeman --no-pager -q -w2 && bundle exec bundle-audit check --update` — 全 PASS
- [ ] **Step 2:** `tenant-isolation-reviewer` + `labor-law-compliance-reviewer` + 全体横断レビューを起動（0b-4 と同形）。Critical/High は修正後に次へ
- [ ] **Step 3:** push + `gh pr create`（kei1110 確認）→ ROADMAP 0b-5 行を `[x]` + PR 番号で更新しコミット・push
- [ ] **Step 4:** `gh pr checks --watch` で CI 緑確認。マージはユーザー指示待ち

---

## Self-Review 済み事項

- 設計 §0〜§7 全項目にタスク対応（§1→Task 1・§2→Task 2/3・§3→Task 5・§4→Task 4/6/7・§5→Task 6/7・§6→各 spec・§7→Task 8）
- 型整合: `Organization#setting`（Task 2 定義・Task 5/6/8 使用）／`Updater.call(organization:, organization_params:, setting_params:)` と Result（Task 5 定義・Task 6 使用）／`t_applies_to`（Task 7 定義・使用）
- 再計算の検証は service spec（境界 3 例）+ request spec（実 subdomain 経由の横断 example = Pragma Critical の唯一の網）の二層
- fiscal_year_for(2026-01-15): end_month 3 → start 4 月 → "2025"。end_month 12 → start 1 月 → "2026"。end_month 6 → start 7 月 → "2025"（1 月）/ "2026"（10 月）— Task 5 の期待値と一致
