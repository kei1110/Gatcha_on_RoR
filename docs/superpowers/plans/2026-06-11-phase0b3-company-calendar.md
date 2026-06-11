# Phase 0b-3 CompanyCalendar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** hr_admin が会社カレンダー（祝日・会社休業日・法定休日）を CRUD / CSV 一括インポート / 法定休日一括生成で整備でき、`CompanyCalendarResolver` が未登録日フォールバック付きで日種別を解決できる。

**Architecture:** 設計仕様 [docs/superpowers/specs/2026-06-11-phase0b3-company-calendar-design.md](../specs/2026-06-11-phase0b3-company-calendar-design.md)（承認済み・5 視点レビュー反映）に従う。共通コア `BulkUpserter`（全件検証 → 1 トランザクション upsert・organization 明示引数で fail-open 遮断）に、CSV パーサーと法定休日行ビルダーの 2 入口が合流する。fiscal_year は `Organization#fiscal_year_for(date)` で自動導出。

**Tech Stack:** Rails 8.1 / acts_as_tenant / Pundit / Ruby 標準 CSV（gem 明示）/ RSpec + FactoryBot

**横断規約（全タスク共通 — RAILS_GOTCHAS 由来）:**
- 書き込み系 redirect は `status: :see_other`・失敗 render は `status: :unprocessable_entity`
- enum は `validate: true` 必須（不正値 ArgumentError 500 防止）
- `upsert_all` / `insert_all` は使用禁止（acts_as_tenant とバリデーションを両方バイパス）
- コミットは各タスク末尾で必ず行う（セッション中断対策）。コミッターは kei1110 <eoh2145@gmail.com>（local 設定済み）
- spec 実行はプロジェクトルートで `bundle exec rspec <path>`。rubocop は Edit/Write フックが自動整形するが、コミット前に `bundle exec rubocop --no-server` で確認

---

### Task 1: csv gem + organizations migration + Organization#fiscal_year_for

**Files:**
- Modify: `Gemfile`（`gem "view_component"` 行の近く・本体依存ブロック）
- Create: `db/migrate/<timestamp>_change_organizations_fiscal_year_end_month_default.rb`
- Modify: `app/models/organization.rb`
- Test: `spec/models/organization_spec.rb`（追記）

- [ ] **Step 1: Gemfile に csv を追加して bundle**

`Gemfile` の `gem "pundit"` の下に追加:

```ruby
# Ruby 3.4 で標準添付から外れる時限への先回り（0b-3 設計 §1）
gem "csv"
```

Run: `bundle install`
Expected: `Bundle complete`

- [ ] **Step 2: organizations の migration を生成・記述**

Run: `bin/rails generate migration ChangeOrganizationsFiscalYearEndMonthDefault`

生成ファイルを以下に置き換え:

```ruby
class ChangeOrganizationsFiscalYearEndMonthDefault < ActiveRecord::Migration[8.1]
  # 三重既定値（§4.2 nullable / §4.15 既定 3 / コード内 nil→3）の解消 — SSOT を DB 制約へ昇格し
  # コード内 nil フォールバックを置かない（サイレント 3 月締め化の構造的排除・0b-3 設計 §0）
  def up
    execute "UPDATE organizations SET fiscal_year_end_month = 3 WHERE fiscal_year_end_month IS NULL"
    change_column_default :organizations, :fiscal_year_end_month, 3
    change_column_null :organizations, :fiscal_year_end_month, false
  end

  def down
    change_column_null :organizations, :fiscal_year_end_month, true
    change_column_default :organizations, :fiscal_year_end_month, nil
  end
end
```

Run: `bin/rails db:migrate`
Expected: マイグレーション成功・`db/schema.rb` に `default: 3, null: false` が反映される（schema.rb は手編集禁止 — migration 経由のみ）

- [ ] **Step 3: fiscal_year_for の failing test を書く**

`spec/models/organization_spec.rb` の最後の `end` の直前に追記:

```ruby
  describe "#fiscal_year_for（年度導出 — 0b-3 設計 §2）" do
    it "3 月決算（既定）: 年度は 4 月開始（3/31 と 4/1 が境界）" do
      org = create(:organization) # migration 後の DB 既定 3
      expect(org.fiscal_year_for(Date.new(2026, 3, 31))).to eq("2025")
      expect(org.fiscal_year_for(Date.new(2026, 4, 1))).to eq("2026")
      expect(org.fiscal_year_for(Date.new(2027, 1, 15))).to eq("2026")
    end

    it "12 月決算: 年度 = 暦年（start_month 計算の % 12 境界）" do
      org = create(:organization, fiscal_year_end_month: 12)
      expect(org.fiscal_year_for(Date.new(2026, 1, 1))).to eq("2026")
      expect(org.fiscal_year_for(Date.new(2026, 12, 31))).to eq("2026")
    end

    it "1 月決算: 2 月開始" do
      org = create(:organization, fiscal_year_end_month: 1)
      expect(org.fiscal_year_for(Date.new(2026, 1, 31))).to eq("2025")
      expect(org.fiscal_year_for(Date.new(2026, 2, 1))).to eq("2026")
    end
  end
```

- [ ] **Step 4: テストが落ちることを確認**

Run: `bundle exec rspec spec/models/organization_spec.rb -e fiscal_year_for`
Expected: FAIL（`undefined method 'fiscal_year_for'`）

- [ ] **Step 5: 実装**

`app/models/organization.rb` の `validates :time_zone, presence: true` の下に追記:

```ruby

  # 「年度の開始年」を文字列で返す（例: 3 月決算で 2027-01-15 → "2026"）。
  # Organization が fiscal_year_end_month の所有者ゆえここに置く（0b-3 設計 §2。
  # CompanyCalendar.fiscal_year / Phase 2 の LeaveBalance.fiscal_year はこの値を使う）
  def fiscal_year_for(date)
    start_month = fiscal_year_end_month % 12 + 1
    (date.month >= start_month ? date.year : date.year - 1).to_s
  end
```

- [ ] **Step 6: テストが通ることを確認**

Run: `bundle exec rspec spec/models/organization_spec.rb`
Expected: PASS（既存 example 含め全 green）

- [ ] **Step 7: Commit**

```bash
git add Gemfile Gemfile.lock db/migrate db/schema.rb app/models/organization.rb spec/models/organization_spec.rb
git commit -m "feat: Organization#fiscal_year_for と fiscal_year_end_month の NOT NULL DEFAULT 3 化"
```

---

### Task 2: CompanyCalendar モデル（migration・factory・ja.yml・表示ヘルパ）

**Files:**
- Create: `db/migrate/<timestamp>_create_company_calendars.rb`
- Create: `app/models/company_calendar.rb`
- Create: `spec/factories/company_calendars.rb`
- Modify: `config/locales/ja.yml`
- Modify: `app/helpers/application_helper.rb`
- Test: `spec/models/company_calendar_spec.rb`

- [ ] **Step 1: migration を生成・記述**

Run: `bin/rails generate migration CreateCompanyCalendars`

生成ファイルを以下に置き換え（work_patterns の先例と同型）:

```ruby
class CreateCompanyCalendars < ActiveRecord::Migration[8.1]
  def change
    create_table :company_calendars do |t|
      t.references :organization, null: false, foreign_key: true
      t.date :date, null: false
      t.integer :day_type, null: false
      t.string :name
      t.string :fiscal_year, null: false
      t.boolean :counts_as_paid_leave, null: false, default: false

      t.timestamps
    end

    # テナント内 1 日 1 レコード（SPEC §4.7）— upsert の衝突キー。レース時も衝突相手は
    # 同一テナント内に限定され、他テナントへの書き込みは DB レベルで不可能
    add_index :company_calendars, [ :organization_id, :date ], unique: true
    # 複合 FK の前提となる unique index（この順序が必須 — プロジェクト規約・既存 3 テーブルと同型）
    add_index :company_calendars, [ :organization_id, :id ], unique: true
  end
end
```

Run: `bin/rails db:migrate`
Expected: 成功

- [ ] **Step 2: factory を作成**

`spec/factories/company_calendars.rb`:

```ruby
FactoryBot.define do
  factory :company_calendar do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    sequence(:date) { |n| Date.new(2026, 1, 1) + n } # テナント内 unique ゆえ sequence 必須
    day_type { :holiday }
    name { "祝日" } # holiday は name 必須
  end
end
```

- [ ] **Step 3: failing model spec を書く**

`spec/models/company_calendar_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe CompanyCalendar, type: :model do
  describe "date（3 点セット・gen-spec 規約）" do
    it "is unique within tenant" do
      create(:company_calendar, date: "2026-01-01")
      expect(build(:company_calendar, date: "2026-01-01")).not_to be_valid
    end

    it "allows same date in another tenant (鏡像)" do
      create(:company_calendar, date: "2026-01-01")
      ActsAsTenant.with_tenant(create(:organization)) do
        expect(build(:company_calendar, date: "2026-01-01")).to be_valid
      end
    end

    it "is enforced by composite unique index at DB level" do
      cal = create(:company_calendar, date: "2026-01-01")
      dup = build(:company_calendar, date: "2026-01-01", organization: cal.organization)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "day_type" do
    it "全 6 値を受け付け、不正値は invalid（enum validate: true — ArgumentError 500 にしない）" do
      %i[weekday saturday sunday holiday company_holiday legal_holiday].each do |t|
        cal = build(:company_calendar, day_type: t)
        cal.name = "名称" # holiday/company_holiday の name 必須を満たす
        expect(cal).to be_valid, "day_type=#{t}: #{cal.errors.full_messages}"
      end
      expect(build(:company_calendar, day_type: "bogus")).not_to be_valid
    end

    it "整数マッピングを固定（DB 値依存のリオーダー事故検知）" do
      expect(CompanyCalendar.day_types).to eq(
        "weekday" => 0, "saturday" => 1, "sunday" => 2,
        "holiday" => 3, "company_holiday" => 4, "legal_holiday" => 5)
    end

    it "全 enum 値に ja.yml の表示名がある（訳語欠落の検知）" do
      CompanyCalendar.day_types.keys.each do |key|
        expect(I18n.exists?("company_calendars.day_types.#{key}")).to be(true), "missing: #{key}"
      end
    end
  end

  describe "name の条件付き必須" do
    it "holiday / company_holiday は name 必須・weekday / legal_holiday は不要（対照）" do
      expect(build(:company_calendar, day_type: :holiday, name: nil)).not_to be_valid
      expect(build(:company_calendar, day_type: :company_holiday, name: nil)).not_to be_valid
      expect(build(:company_calendar, day_type: :weekday, name: nil)).to be_valid
      expect(build(:company_calendar, day_type: :legal_holiday, name: nil)).to be_valid
    end
  end

  describe "counts_as_paid_leave の相関（§4.7 — 会社休業日専用）" do
    it "company_holiday なら true 可・それ以外は invalid（対照）" do
      expect(build(:company_calendar, day_type: :company_holiday, name: "夏季休業",
                   counts_as_paid_leave: true)).to be_valid
      cal = build(:company_calendar, day_type: :holiday, counts_as_paid_leave: true)
      expect(cal).not_to be_valid
      expect(cal.errors[:counts_as_paid_leave]).to be_present
    end
  end

  describe "fiscal_year 自動導出（0b-3 設計 §2）" do
    it "レコードの organization の決算月から導出される（3 月決算既定: 3/31 と 4/1 が境界）" do
      expect(create(:company_calendar, date: "2026-03-31").fiscal_year).to eq("2025")
      expect(create(:company_calendar, date: "2026-04-01").fiscal_year).to eq("2026")
    end

    it "current_tenant でなくレコードの organization から導出（取り違え検知）" do
      dec_org = create(:organization, fiscal_year_end_month: 12)
      cal = ActsAsTenant.with_tenant(dec_org) do
        create(:company_calendar, date: "2026-01-15")
      end
      expect(cal.fiscal_year).to eq("2026") # 12 月決算 = 暦年。3 月決算なら "2025" になる
    end

    it "date 変更時に再導出される" do
      cal = create(:company_calendar, date: "2026-03-31")
      cal.update!(date: "2026-04-02")
      expect(cal.fiscal_year).to eq("2026")
    end
  end
end
```

- [ ] **Step 4: テストが落ちることを確認**

Run: `bundle exec rspec spec/models/company_calendar_spec.rb`
Expected: FAIL（`uninitialized constant CompanyCalendar`）

- [ ] **Step 5: モデル・ja.yml・ヘルパを実装**

`app/models/company_calendar.rb`:

```ruby
class CompanyCalendar < ApplicationRecord
  # 宣言順が重要: acts_as_tenant の organization_id 代入（before_validation, on: :create）が
  # 先に登録されるため、後続の set_fiscal_year から organization を参照できる（0b-3 設計 §2）
  acts_as_tenant(:organization)

  # validate: true — CSV 入力が直結するため必須（RAILS_GOTCHAS）。
  # legal_holiday と sunday の排他（SPEC §4.7）は単一 enum カラムにより構造的に保証
  enum :day_type, {
    weekday: 0, saturday: 1, sunday: 2,
    holiday: 3, company_holiday: 4, legal_holiday: 5
  }, validate: true

  before_validation :set_fiscal_year

  validates :date, presence: true
  validates_uniqueness_to_tenant :date
  validates :day_type, presence: true
  validates :fiscal_year, presence: true
  validates :name, presence: true, if: -> { holiday? || company_holiday? }
  validate :counts_as_paid_leave_only_for_company_holiday

  private

  # current_tenant でなく**レコードの organization** から導出 — without_tenant 文脈・
  # with_tenant ミスマッチ時に他社の決算月で算出する取り違えを構造的に排除（0b-3 設計 §2）
  def set_fiscal_year
    self.fiscal_year = organization&.fiscal_year_for(date) if date
  end

  # §4.7 の列定義どおり会社休業日専用。true 運用には計画的付与の労使協定等の根拠が必要
  # （労基法 39 条 6 項 — 社労士確認 #10）。暗黙で握りつぶさず明示エラー
  def counts_as_paid_leave_only_for_company_holiday
    return unless counts_as_paid_leave? && !company_holiday?

    errors.add(:counts_as_paid_leave, "は会社休業日でのみ設定できます")
  end
end
```

`config/locales/ja.yml` — `leave_type:` ブロック（`active: 有効` の行）の後・`leave_types:` の前に attributes を、`leave_types:` ブロックの後に `company_calendars:` を追加。models には `company_calendar: 会社カレンダー` を追加:

```yaml
# activerecord.models に追加（leave_type: 休暇種別 の下）
      company_calendar: 会社カレンダー
# activerecord.attributes に追加（leave_type ブロックの下・同インデント）
      company_calendar:
        date: 日付
        day_type: 日種別
        name: 名称
        fiscal_year: 年度
        counts_as_paid_leave: 有給算入
# トップレベル（leave_types: ブロックの後・同インデント）
  company_calendars:
    day_types:
      weekday: 平日
      saturday: 土曜
      sunday: 日曜
      holiday: 祝日
      company_holiday: 会社休業日
      legal_holiday: 法定休日
```

`app/helpers/application_helper.rb` の `t_system_type` の下に追記:

```ruby
  def t_day_type(value) = I18n.t("company_calendars.day_types.#{value}")
```

- [ ] **Step 6: テストが通ることを確認**

Run: `bundle exec rspec spec/models/company_calendar_spec.rb`
Expected: PASS（全 example green）

- [ ] **Step 7: Commit**

```bash
git add db/migrate db/schema.rb app/models/company_calendar.rb spec/factories/company_calendars.rb \
        spec/models/company_calendar_spec.rb config/locales/ja.yml app/helpers/application_helper.rb
git commit -m "feat: CompanyCalendar モデル（enum validate・fiscal_year 自動導出・テナント内 date unique）"
```

---

### Task 3: Admin::CompanyCalendarPolicy

**Files:**
- Create: `app/policies/admin/company_calendar_policy.rb`
- Test: `spec/policies/admin/company_calendar_policy_spec.rb`

- [ ] **Step 1: failing policy spec を書く**

`spec/policies/admin/company_calendar_policy_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Admin::CompanyCalendarPolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let(:record) { create(:company_calendar) }

  context "hr_admin" do
    let(:actor) { create(:user, :hr_admin) }
    # destroy/import/generate は基底 MasterPolicy に無い異型 3 アクション（0b-3 設計 §4）
    it { is_expected.to permit_actions(%i[index new create edit update destroy import generate]) }
  end

  context "manager" do
    let(:actor) { create(:user, :manager_role) }
    it { is_expected.to forbid_actions(%i[index new create edit update destroy import generate]) }
  end

  context "employee" do
    let(:actor) { create(:user) }
    it { is_expected.to forbid_actions(%i[index new create edit update destroy import generate]) }
  end

  describe "Scope" do
    it "組織全件・他テナント漏れなし" do
      actor = create(:user, :hr_admin)
      ActsAsTenant.with_tenant(create(:organization)) { create(:company_calendar) }

      resolved = described_class::Scope.new(actor, CompanyCalendar.all).resolve
      expect(resolved).to contain_exactly(record)
    end

    it "without_tenant 文脈でも自組織のみ（organization_id 明示の fail-open 検出 — test_tenant 下では検知不能）" do
      actor = create(:user, :hr_admin)
      record # 生成
      ActsAsTenant.with_tenant(create(:organization)) { create(:company_calendar) }

      resolved = ActsAsTenant.without_tenant do
        described_class::Scope.new(actor, CompanyCalendar.all).resolve.to_a
      end
      expect(resolved).to contain_exactly(record)
    end
  end
end
```

- [ ] **Step 2: テストが落ちることを確認**

Run: `bundle exec rspec spec/policies/admin/company_calendar_policy_spec.rb`
Expected: FAIL（`uninitialized constant Admin::CompanyCalendarPolicy`）

- [ ] **Step 3: 実装**

`app/policies/admin/company_calendar_policy.rb`:

```ruby
module Admin
  # MasterPolicy 継承 + 異型 3 アクション（基底コメントの「0b-3 は個別判断」の実行 — 0b-3 設計 §4）。
  # Scope は基底の organization_id 明示（without_tenant fail-open 遮断の二重防衛）をそのまま継承
  class CompanyCalendarPolicy < MasterPolicy
    def destroy? = hr_admin? # 物理削除 — イベント参照を持たない日付事実テーブル（§12.3 の例外・設計 §0）
    def import? = hr_admin?
    def generate? = hr_admin?
  end
end
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/policies/admin/company_calendar_policy_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/policies/admin/company_calendar_policy.rb spec/policies/admin/company_calendar_policy_spec.rb
git commit -m "feat: Admin::CompanyCalendarPolicy（MasterPolicy 継承 + destroy/import/generate）"
```

---

### Task 4: routes・CRUD コントローラ・views・Nav タブ

**Files:**
- Modify: `config/routes.rb`
- Create: `app/controllers/admin/company_calendars_controller.rb`
- Create: `app/views/admin/company_calendars/index.html.erb` / `new.html.erb` / `edit.html.erb` / `_form.html.erb`
- Modify: `app/components/admin/nav_component.rb`
- Test: `spec/requests/admin_company_calendars_spec.rb`

- [ ] **Step 1: failing request spec を書く**

`spec/requests/admin_company_calendars_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Admin::CompanyCalendars", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:calendar) do
    ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-05-04", name: "みどりの日") }
  end

  describe "認可" do
    it "未認証はサインインへ・employee は 403・hr_admin は 200（対照）" do
      get admin_company_calendars_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get admin_company_calendars_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get admin_company_calendars_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end
  end

  describe "index（hr_admin）" do
    before { sign_in admin }

    it "年度フィルタ: 既定は今年度・指定年度のみ表示し enum 生値を露出しない" do
      old = ActsAsTenant.with_tenant(org) do
        create(:company_calendar, date: "2020-01-01", name: "過去の元日")
      end
      get admin_company_calendars_url(host: tenant_host(org)), params: { fiscal_year: "2026" }
      expect(response.body).to include("みどりの日")
      expect(response.body).not_to include("過去の元日")
      expect(response.body).not_to include(">holiday<") # i18n 表示ヘルパ経由

      get admin_company_calendars_url(host: tenant_host(org)), params: { fiscal_year: "2019" }
      expect(response.body).to include("過去の元日")
      expect(old.fiscal_year).to eq("2019")
    end

    it "legal_holiday 0 件で警告バナー・1 件以上で非表示（35% 保護・対照ペア）" do
      get admin_company_calendars_url(host: tenant_host(org)), params: { fiscal_year: "2026" }
      expect(response.body).to include("法定休日（legal_holiday）が 1 件も登録されていません")

      ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-05-10", day_type: :legal_holiday) }
      get admin_company_calendars_url(host: tenant_host(org)), params: { fiscal_year: "2026" }
      expect(response.body).not_to include("1 件も登録されていません")
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "作成できる（fiscal_year は自動導出）" do
      post admin_company_calendars_url(host: tenant_host(org)), params: { company_calendar: {
        date: "2026-08-13", day_type: "company_holiday", name: "夏季休業", counts_as_paid_leave: "1" } }
      created = ActsAsTenant.with_tenant(org) { CompanyCalendar.find_by!(date: "2026-08-13") }
      expect(response).to redirect_to(admin_company_calendars_url(host: tenant_host(org)))
      expect(response).to have_http_status(:see_other)
      expect(created.fiscal_year).to eq("2026")
    end

    it "enum 不正値・相関違反は 422 + 状態不変" do
      patch admin_company_calendar_url(calendar, host: tenant_host(org)),
            params: { company_calendar: { day_type: "bogus" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(calendar.reload.day_type).to eq("holiday")

      patch admin_company_calendar_url(calendar, host: tenant_host(org)),
            params: { company_calendar: { counts_as_paid_leave: "1" } } # holiday のままでは不可
      expect(response).to have_http_status(:unprocessable_entity)
      expect(calendar.reload.counts_as_paid_leave).to be(false)
    end

    it "permit 境界: fiscal_year と organization_id は無視される" do
      other_org = create(:organization)
      patch admin_company_calendar_url(calendar, host: tenant_host(org)),
            params: { company_calendar: { name: "改名", fiscal_year: "1999", organization_id: other_org.id } }
      calendar.reload
      expect(calendar.name).to eq("改名")
      expect(calendar.fiscal_year).to eq("2026") # date 由来の自動導出のまま
      expect(calendar.organization_id).to eq(org.id)
    end

    it "削除できる（303・一覧へ）" do
      delete admin_company_calendar_url(calendar, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_company_calendars_url(host: tenant_host(org)))
      expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.exists?(calendar.id) }).to be(false)
    end

    it "show ルートは存在しない（一覧 → edit 直行・設計 §1）" do
      expect {
        get admin_company_calendar_url(calendar, host: tenant_host(org))
      }.to raise_error(ActionController::RoutingError)
    end
  end

  describe "IDOR（全 member アクション 404）" do
    let!(:other) { ActsAsTenant.with_tenant(create(:organization, subdomain: "globex")) { create(:company_calendar) } }

    before { sign_in admin }

    it "edit / update / destroy すべて 404・副作用なし" do
      get edit_admin_company_calendar_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      patch admin_company_calendar_url(other, host: tenant_host(org)),
            params: { company_calendar: { name: "x" } }
      expect(response).to have_http_status(:not_found)
      delete admin_company_calendar_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(ActsAsTenant.without_tenant { CompanyCalendar.exists?(other.id) }).to be(true)
    end
  end
end
```

- [ ] **Step 2: テストが落ちることを確認**

Run: `bundle exec rspec spec/requests/admin_company_calendars_spec.rb`
Expected: FAIL（`undefined method 'admin_company_calendars_url'`）

- [ ] **Step 3: routes・controller・views・Nav を実装**

`config/routes.rb` の `resources :leave_types ... end` ブロックの後（`namespace :admin` 内）に追記:

```ruby
    resources :company_calendars, except: :show
    namespace :company_calendars do
      resource :import, only: %i[new create]
      resource :legal_holiday_generation, only: %i[new create]
    end
```

`app/controllers/admin/company_calendars_controller.rb`:

```ruby
module Admin
  class CompanyCalendarsController < BaseController
    before_action :set_company_calendar, only: %i[edit update destroy]

    def index
      authorize [ :admin, CompanyCalendar ]
      scope = policy_scope([ :admin, CompanyCalendar ])
      @fiscal_year = params[:fiscal_year].presence || current_fiscal_year
      @fiscal_years = (scope.distinct.pluck(:fiscal_year) | [ current_fiscal_year ]).sort.reverse
      @company_calendars = scope.where(fiscal_year: @fiscal_year).order(:date)
      # 35% 保護: §4.7「legal_holiday の登録を必須運用とする」の画面側の網（0b-3 設計 §4）
      @legal_holiday_missing = scope.where(fiscal_year: @fiscal_year, day_type: :legal_holiday).none?
    end

    def new
      @company_calendar = CompanyCalendar.new
      authorize [ :admin, @company_calendar ]
    end

    def create
      @company_calendar = CompanyCalendar.new(company_calendar_params)
      authorize [ :admin, @company_calendar ]
      if @company_calendar.save
        redirect_to admin_company_calendars_path, status: :see_other,
                    notice: "#{@company_calendar.date} を登録しました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @company_calendar ]
    end

    def update
      authorize [ :admin, @company_calendar ]
      if @company_calendar.update(company_calendar_params)
        redirect_to admin_company_calendars_path, status: :see_other, notice: "更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # 物理削除 — イベント参照を持たない日付事実テーブル（§12.3 の無効化統一の例外・0b-3 設計 §0。
    # 締め済み月に属する日付の削除制限は Phase 1 の締めフロー導入時に課す）
    def destroy
      authorize [ :admin, @company_calendar ]
      @company_calendar.destroy!
      redirect_to admin_company_calendars_path, status: :see_other,
                  notice: "#{@company_calendar.date} を削除しました"
    end

    private

    # 他テナント id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_company_calendar
      @company_calendar = policy_scope([ :admin, CompanyCalendar ]).find(params[:id])
    end

    def current_fiscal_year
      ActsAsTenant.current_tenant.fiscal_year_for(Date.current)
    end

    # fiscal_year / organization_id は permit しない（fiscal_year は date から自動導出 — 0b-3 設計 §2）
    def company_calendar_params
      params.require(:company_calendar).permit(:date, :day_type, :name, :counts_as_paid_leave)
    end
  end
end
```

`app/views/admin/company_calendars/index.html.erb`:

```erb
<div class="mb-4 flex justify-between">
  <h2 class="text-lg font-bold">会社カレンダー</h2>
  <div class="flex gap-2">
    <%= link_to "CSV インポート", new_admin_company_calendars_import_path, class: "rounded border border-gray-800 px-4 py-2" %>
    <%= link_to "法定休日の一括登録", new_admin_company_calendars_legal_holiday_generation_path, class: "rounded border border-gray-800 px-4 py-2" %>
    <%= link_to "新規登録", new_admin_company_calendar_path, class: "rounded bg-gray-800 px-4 py-2 text-white" %>
  </div>
</div>

<%= form_with url: admin_company_calendars_path, method: :get, class: "mb-4" do |f| %>
  <%= f.label :fiscal_year, "年度", class: "font-bold" %>
  <%= f.select :fiscal_year, @fiscal_years, { selected: @fiscal_year },
        onchange: "this.form.requestSubmit()", class: "rounded border p-2" %>
<% end %>

<% if @legal_holiday_missing %>
  <div class="mb-4 rounded border border-yellow-400 bg-yellow-50 p-3 text-yellow-800">
    <%= @fiscal_year %> 年度に法定休日（legal_holiday）が 1 件も登録されていません。
    法定休日の登録は必須運用です（未登録の休日労働は割増の付け漏れリスク）—
    <%= link_to "一括登録へ", new_admin_company_calendars_legal_holiday_generation_path, class: "underline" %>
  </div>
<% end %>

<table class="w-full text-left text-sm">
  <thead>
    <tr class="border-b font-bold">
      <th class="p-2">日付</th><th class="p-2">曜日</th><th class="p-2">種別</th>
      <th class="p-2">名称</th><th class="p-2">有給算入</th><th class="p-2"></th>
    </tr>
  </thead>
  <tbody>
    <% @company_calendars.each do |cal| %>
      <tr class="border-b">
        <td class="p-2"><%= cal.date %></td>
        <td class="p-2"><%= %w[月 火 水 木 金 土 日][cal.date.cwday - 1] %></td>
        <td class="p-2"><%= t_day_type(cal.day_type) %></td>
        <td class="p-2"><%= cal.name %></td>
        <td class="p-2"><%= "算入" if cal.counts_as_paid_leave? %></td>
        <td class="p-2">
          <%= link_to "編集", edit_admin_company_calendar_path(cal), class: "underline" %>
          <%= button_to "削除", admin_company_calendar_path(cal), method: :delete,
                form: { class: "inline", data: { turbo_confirm: "#{cal.date} を削除しますか？" } },
                class: "underline text-red-700" %>
        </td>
      </tr>
    <% end %>
  </tbody>
</table>
```

`app/views/admin/company_calendars/_form.html.erb`:

```erb
<%= form_with model: [ :admin, company_calendar ], class: "max-w-md space-y-4 text-sm" do |f| %>
  <% if company_calendar.errors.any? %>
    <div class="rounded border border-red-400 bg-red-50 p-3 text-red-800">
      <ul><% company_calendar.errors.full_messages.each do |msg| %><li><%= msg %></li><% end %></ul>
    </div>
  <% end %>

  <div><%= f.label :date, class: "block font-bold" %><%= f.date_field :date, class: "rounded border p-2" %></div>
  <div>
    <%= f.label :day_type, class: "block font-bold" %>
    <%= f.select :day_type, CompanyCalendar.day_types.keys.map { |k| [ t_day_type(k), k ] }, {},
          class: "w-full rounded border p-2" %>
  </div>
  <div><%= f.label :name, class: "block font-bold" %><%= f.text_field :name, placeholder: "祝日・会社休業日は必須", class: "w-full rounded border p-2" %></div>
  <div>
    <%= f.label :counts_as_paid_leave, class: "font-bold" do %>
      <%= f.check_box :counts_as_paid_leave %> 有給消化日として扱う（会社休業日のみ）
    <% end %>
    <p class="text-gray-500">有効にする運用には計画的付与の労使協定等の根拠が必要です（労基法 39 条 6 項）</p>
  </div>
  <%= f.submit company_calendar.persisted? ? "更新する" : "登録する", class: "rounded bg-gray-800 px-4 py-2 text-white" %>
<% end %>
```

`app/views/admin/company_calendars/new.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold">カレンダー登録</h2>
<%= render "form", company_calendar: @company_calendar %>
```

`app/views/admin/company_calendars/edit.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold">カレンダー編集</h2>
<%= render "form", company_calendar: @company_calendar %>
```

`app/components/admin/nav_component.rb` の tabs に 1 行追加:

```ruby
        [ "会社カレンダー", helpers.admin_company_calendars_path ]
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/requests/admin_company_calendars_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add config/routes.rb app/controllers/admin/company_calendars_controller.rb \
        app/views/admin/company_calendars app/components/admin/nav_component.rb \
        spec/requests/admin_company_calendars_spec.rb
git commit -m "feat: 会社カレンダー CRUD（年度フィルタ・legal_holiday 0 件バナー・物理削除）"
```

---

### Task 5: RowError + CompanyCalendars::BulkUpserter（共通コア）

**Files:**
- Create: `app/services/company_calendars/row_error.rb`
- Create: `app/services/company_calendars/bulk_upserter.rb`
- Test: `spec/services/company_calendars/bulk_upserter_spec.rb`

- [ ] **Step 1: failing service spec を書く**

`spec/services/company_calendars/bulk_upserter_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe CompanyCalendars::BulkUpserter do
  let(:org) { create(:organization) }

  def row(date, day_type: "holiday", name: "祝日", counts: false, line: 2)
    { line:, date: Date.parse(date), day_type:, name:, counts_as_paid_leave: counts }
  end

  def upsert(rows, allow_demotion: false, organization: org)
    described_class.new(organization:, allow_demotion:).call(rows)
  end

  it "作成・更新の混在を 1 トランザクションで取り込み件数を返す" do
    ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-01-01", name: "旧名") }
    result = upsert([ row("2026-01-01", name: "元日"), row("2026-02-11", name: "建国記念の日", line: 3) ])

    expect(result).to be_success
    expect(result.created_count).to eq(1)
    expect(result.updated_count).to eq(1)
    expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.find_by!(date: "2026-01-01").name }).to eq("元日")
  end

  it "1 行でも不正なら全件不採用（DB 不変・行番号付きエラー）" do
    result = upsert([ row("2026-01-01"), row("2026-02-11", name: nil, line: 5) ]) # holiday の name 欠落

    expect(result).not_to be_success
    expect(result.errors.map(&:line)).to eq([ 5 ])
    expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.count }).to eq(0)
  end

  it "他テナントの同一日付には影響しない（cross-tenant 鏡像）" do
    other_org = create(:organization)
    other = ActsAsTenant.with_tenant(other_org) { create(:company_calendar, date: "2026-01-01", name: "他社") }

    result = upsert([ row("2026-01-01", name: "元日") ])
    expect(result.created_count).to eq(1) # 他社行の update でなく自社行の create
    expect(other.reload.name).to eq("他社")
  end

  it "without_tenant 文脈でも自テナントにのみ書く（fail-open 遮断・設計 §3）" do
    result = ActsAsTenant.without_tenant { upsert([ row("2026-01-01") ]) }
    expect(result).to be_success
    expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.find_by!(date: "2026-01-01") }).to be_present
  end

  it "organization: nil は ArgumentError" do
    expect { described_class.new(organization: nil) }.to raise_error(ArgumentError)
  end

  describe "降格検出（35% 保護 — 非対称ガード・設計 §3）" do
    before do
      ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-05-10", day_type: :legal_holiday) }
    end

    it "legal_holiday → 他種別は allow_demotion なしでエラー・ありで成功" do
      result = upsert([ row("2026-05-10", day_type: "holiday", name: "祝日") ])
      expect(result).not_to be_success
      expect(result.errors.first.message).to include("法定休日")

      result = upsert([ row("2026-05-10", day_type: "holiday", name: "祝日") ], allow_demotion: true)
      expect(result).to be_success
    end

    it "労働者有利方向（holiday → legal_holiday・legal_holiday 同値再取込）はフラグ不要（対照）" do
      ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-01-01") } # holiday
      result = upsert([ row("2026-01-01", day_type: "legal_holiday", name: nil),
                        row("2026-05-10", day_type: "legal_holiday", name: nil, line: 3) ])
      expect(result).to be_success
    end
  end

  it "行数上限 2,000 を超えるとファイルエラー" do
    rows = (1..2_001).map { |n| row("2026-01-01", line: n) } # 中身は検証前に弾かれる
    result = upsert(rows)
    expect(result).not_to be_success
    expect(result.errors.first.message).to include("2000")
    expect(result.errors.first.line).to be_nil
  end
end
```

- [ ] **Step 2: テストが落ちることを確認**

Run: `bundle exec rspec spec/services/company_calendars/bulk_upserter_spec.rb`
Expected: FAIL（`uninitialized constant CompanyCalendars`）

- [ ] **Step 3: 実装**

`app/services/company_calendars/row_error.rb`:

```ruby
module CompanyCalendars
  # 行番号付きエラー（line nil = ファイル全体のエラー）。パーサ・アップサータ・ビルダー共通
  RowError = Data.define(:line, :message)
end
```

`app/services/company_calendars/bulk_upserter.rb`:

```ruby
module CompanyCalendars
  # 全件検証 → 1 トランザクション upsert の共通コア（CSV インポートと法定休日一括生成が合流 — 0b-3 設計 §3）。
  # upsert_all / insert_all は使用禁止 — acts_as_tenant とモデルバリデーションを両方バイパスする。
  # 性能最適化で移行する場合は organization_id 明示付与 + unique_by: [:organization_id, :date] +
  # 値検証の自前実装が条件（設計 §0 の制約）
  class BulkUpserter
    MAX_ROWS = 2_000 # 同期処理の妥当性ガード（実需は 1 年 366 行・5 年分 1,830 行）
    ATTRIBUTE_KEYS = %i[day_type name counts_as_paid_leave].freeze # 4 列ホワイトリストの書き込み側

    Result = Data.define(:errors, :created_count, :updated_count) do
      def success? = errors.empty?
    end

    # organization 明示必須 — without_tenant 文脈（seed・rake・console）で他テナントの
    # 同日行を掴む fail-open をサービス側で遮断（RAILS_GOTCHAS・0b-3 設計 §3）
    def initialize(organization:, allow_demotion: false)
      raise ArgumentError, "organization は必須です" if organization.nil?

      @organization = organization
      @allow_demotion = allow_demotion
    end

    # rows: [{ line:, date:, day_type:, name:, counts_as_paid_leave: }, ...]（date は Date 型）
    def call(rows)
      return failure("行数が上限 #{MAX_ROWS} を超えています（#{rows.size} 行）") if rows.size > MAX_ROWS

      errors = []
      created = updated = 0
      ActsAsTenant.with_tenant(@organization) do
        ActiveRecord::Base.transaction do
          # 既存行を 1 クエリでプリロード（作成/更新の振り分け + 行単位 find の削減）
          existing = CompanyCalendar.where(date: rows.map { |r| r[:date] }).index_by(&:date)
          rows.each do |row|
            record = existing[row[:date]] || CompanyCalendar.new(date: row[:date])
            if (error = demotion_error(record, row))
              errors << error
              next
            end
            record.assign_attributes(row.slice(*ATTRIBUTE_KEYS))
            if record.save
              record.previously_new_record? ? created += 1 : updated += 1
            else
              errors << RowError.new(line: row[:line], message: record.errors.full_messages.join("。"))
            end
          end
          raise ActiveRecord::Rollback if errors.any?
        end
      end
      return Result.new(errors:, created_count: 0, updated_count: 0) if errors.any?

      Result.new(errors: [], created_count: created, updated_count: updated)
    rescue ActiveRecord::RecordNotUnique
      # 並行インポートの TOCTOU — 500 にせずエラー表示へ（0b-3 設計 §3）
      failure("別のインポートが同時に実行されました。最新の一覧を確認してから再度お試しください")
    end

    private

    # 35% 付け漏れ方向（legal_holiday → 他種別）だけ非対称に守る（SPEC §4.7・0b-3 設計 §3）
    def demotion_error(record, row)
      return if @allow_demotion
      return unless record.persisted? && record.legal_holiday? && row[:day_type].to_s != "legal_holiday"

      RowError.new(line: row[:line],
                   message: "#{record.date} は登録済みの法定休日です。" \
                            "変更するには「法定休日の変更を許可」を有効にしてください")
    end

    def failure(message)
      Result.new(errors: [ RowError.new(line: nil, message:) ], created_count: 0, updated_count: 0)
    end
  end
end
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/services/company_calendars/bulk_upserter_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/services/company_calendars spec/services
git commit -m "feat: CompanyCalendars::BulkUpserter（全件検証 tx upsert・降格ガード・fail-open 遮断）"
```

---

### Task 6: CompanyCalendars::CsvParser

**Files:**
- Create: `app/services/company_calendars/csv_parser.rb`
- Test: `spec/services/company_calendars/csv_parser_spec.rb`

- [ ] **Step 1: failing spec を書く**

`spec/services/company_calendars/csv_parser_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe CompanyCalendars::CsvParser do
  def upload(content)
    file = Tempfile.new([ "calendar", ".csv" ])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv")
  end

  it "正常系: 4 列を行 hash に変換（name 空は nil・counts 空は false・行番号はヘッダ込み）" do
    result = described_class.parse(upload(<<~CSV))
      date,day_type,name,counts_as_paid_leave
      2026-01-01,holiday,元日,
      2026-08-13,company_holiday,夏季休業,true
      2026-04-06,weekday,,0
    CSV

    expect(result).to be_success
    expect(result.rows).to eq([
      { line: 2, date: Date.new(2026, 1, 1), day_type: "holiday", name: "元日", counts_as_paid_leave: false },
      { line: 3, date: Date.new(2026, 8, 13), day_type: "company_holiday", name: "夏季休業", counts_as_paid_leave: true },
      { line: 4, date: Date.new(2026, 4, 6), day_type: "weekday", name: nil, counts_as_paid_leave: false }
    ])
  end

  it "BOM 付き UTF-8 を受理し、未知列（organization_id 等）は無視する（ホワイトリスト・設計 §3）" do
    result = described_class.parse(upload(
      "\xEF\xBB\xBFdate,day_type,name,counts_as_paid_leave,organization_id,fiscal_year\n" \
      "2026-01-01,holiday,元日,,999,1999\n"))
    expect(result).to be_success
    expect(result.rows.first.keys).to contain_exactly(:line, :date, :day_type, :name, :counts_as_paid_leave)
  end

  it "date 不正・day_type 不正・counts 不正は行番号付きエラー（正常行も全件不採用の材料として返す）" do
    result = described_class.parse(upload(<<~CSV))
      date,day_type,name,counts_as_paid_leave
      2026/01/01,holiday,元日,
      2026-02-11,祝日,建国記念の日,
      2026-03-20,holiday,春分の日,yes
    CSV

    expect(result).not_to be_success
    expect(result.errors.map(&:line)).to eq([ 2, 3, 4 ])
    expect(result.errors[0].message).to include("YYYY-MM-DD")
    expect(result.errors[1].message).to include("day_type") # 日本語ラベルは受理しない（設計 §0）
    expect(result.errors[2].message).to include("counts_as_paid_leave")
  end

  it "CSV 内の日付重複は後行をエラーにする" do
    result = described_class.parse(upload(<<~CSV))
      date,day_type,name,counts_as_paid_leave
      2026-01-01,holiday,元日,
      2026-01-01,weekday,,
    CSV
    expect(result.errors.map(&:line)).to eq([ 3 ])
    expect(result.errors.first.message).to include("重複")
  end

  it "ファイル欠落・必須ヘッダ欠落・非 UTF-8・壊れた CSV はファイルエラー（line nil）" do
    expect(described_class.parse(nil).errors.first.message).to include("ファイルを選択")
    expect(described_class.parse(upload("day_type,name\nholiday,x\n")).errors.first.message).to include("date")
    expect(described_class.parse(upload("date,day_type\n2026-01-01,祝日\n".encode("Shift_JIS")))
      .errors.first.message).to include("UTF-8")
    expect(described_class.parse(upload(%(date,day_type\n"2026-01-01,holiday\n)))
      .errors.first.message).to include("CSV")
  end

  it "行数 2,001 行は上限エラー" do
    body = (0...2_001).map { |n| "#{Date.new(2026, 1, 1) + n},weekday,," }.join("\n")
    result = described_class.parse(upload("date,day_type,name,counts_as_paid_leave\n#{body}\n"))
    expect(result.errors.first.message).to include("2000")
  end

  it "1MB 超はパース前に拒否（DoS ガード — 検証順序・設計 §3）" do
    big = "date,day_type\n" + "x" * 1.megabyte
    expect(described_class.parse(upload(big)).errors.first.message).to include("1MB")
  end
end
```

- [ ] **Step 2: テストが落ちることを確認**

Run: `bundle exec rspec spec/services/company_calendars/csv_parser_spec.rb`
Expected: FAIL（`uninitialized constant CompanyCalendars::CsvParser`）

- [ ] **Step 3: 実装**

`app/services/company_calendars/csv_parser.rb`:

```ruby
require "csv"

module CompanyCalendars
  # CSV → 行 hash（行番号付きエラー）。読み取りは 4 列のみ — organization_id / fiscal_year 等の
  # 混入列は受理しない（CSV は strong params を通らないため、ここが mass-assignment 防壁の代替 — 0b-3 設計 §3）
  class CsvParser
    MAX_BYTES = 1.megabyte # パース前のメモリガード（行数上限は BulkUpserter::MAX_ROWS が妥当性ガード）
    REQUIRED_HEADERS = %w[date day_type].freeze
    TRUE_VALUES = %w[true 1].freeze
    FALSE_VALUES = [ "false", "0", "", nil ].freeze

    Result = Data.define(:rows, :errors) do
      def success? = errors.empty?
    end

    def self.parse(file) = new(file).parse

    def initialize(file)
      @file = file
    end

    # 検証順序が DoS 緩和の要: 型 → バイト上限 → エンコーディング → CSV パース（0b-3 設計 §3）
    def parse
      fatal = precheck
      return failure(fatal) if fatal

      table = CSV.parse(@content, headers: true)
      missing = REQUIRED_HEADERS - (table.headers || []).compact
      return failure("ヘッダ行に必須列（#{missing.join(', ')}）がありません") if missing.any?
      if table.size > BulkUpserter::MAX_ROWS
        return failure("行数が上限 #{BulkUpserter::MAX_ROWS} を超えています（#{table.size} 行）")
      end

      build_rows(table)
    rescue CSV::MalformedCSVError => e
      failure("CSV の形式が不正です: #{e.message}")
    end

    private

    def precheck
      return "ファイルを選択してください" unless @file.respond_to?(:read)
      return "ファイルサイズが上限 1MB を超えています" if @file.respond_to?(:size) && @file.size > MAX_BYTES

      @content = @file.read.dup.force_encoding(Encoding::UTF_8)
      @content.delete_prefix!("\xEF\xBB\xBF") # BOM 許容
      return "文字コードが UTF-8 ではありません。UTF-8 で保存し直してください" unless @content.valid_encoding?

      nil
    end

    def build_rows(table)
      rows = []
      errors = []
      seen = {}
      table.each.with_index(2) do |csv_row, line| # ヘッダが 1 行目
        row, error = convert(csv_row, line)
        next errors << error if error

        if (dup_line = seen[row[:date]])
          errors << RowError.new(line:, message: "#{row[:date]} が #{dup_line} 行目と重複しています")
          next
        end
        seen[row[:date]] = line
        rows << row
      end
      Result.new(rows:, errors:)
    end

    def convert(csv_row, line)
      date = Date.iso8601(csv_row["date"].to_s)
      day_type = csv_row["day_type"].to_s
      unless CompanyCalendar.day_types.key?(day_type)
        return [ nil, RowError.new(line:, message:
          "day_type「#{day_type}」は不正です（#{CompanyCalendar.day_types.keys.join(' / ')} のいずれか）") ]
      end
      counts, counts_error = parse_boolean(csv_row["counts_as_paid_leave"], line)
      return [ nil, counts_error ] if counts_error

      [ { line:, date:, day_type:, name: csv_row["name"].presence, counts_as_paid_leave: counts }, nil ]
    rescue Date::Error
      [ nil, RowError.new(line:, message: "date「#{csv_row['date']}」は YYYY-MM-DD 形式で指定してください") ]
    end

    def parse_boolean(value, line)
      normalized = value&.strip
      return [ true, nil ] if TRUE_VALUES.include?(normalized)
      return [ false, nil ] if FALSE_VALUES.include?(normalized)

      [ nil, RowError.new(line:, message:
        "counts_as_paid_leave「#{value}」は true / 1 / false / 0 / 空 のいずれかで指定してください") ]
    end

    def failure(message)
      Result.new(rows: [], errors: [ RowError.new(line: nil, message:) ])
    end
  end
end
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/services/company_calendars/csv_parser_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/services/company_calendars/csv_parser.rb spec/services/company_calendars/csv_parser_spec.rb
git commit -m "feat: CompanyCalendars::CsvParser（4 列ホワイトリスト・検証順序による DoS ガード）"
```

---

### Task 7: ImportsController + ビュー + サンプル CSV

**Files:**
- Create: `app/controllers/admin/company_calendars/imports_controller.rb`
- Create: `app/views/admin/company_calendars/imports/new.html.erb`
- Create: `app/views/admin/company_calendars/_bulk_errors.html.erb`
- Create: `public/samples/company_calendar_sample.csv`
- Test: `spec/requests/admin_company_calendar_imports_spec.rb`

- [ ] **Step 1: failing request spec を書く**

`spec/requests/admin_company_calendar_imports_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Admin::CompanyCalendars::Imports", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }

  def upload(content)
    file = Tempfile.new([ "calendar", ".csv" ])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv")
  end

  let(:valid_csv) { "date,day_type,name,counts_as_paid_leave\n2026-01-01,holiday,元日,\n" }

  it "未認証はサインインへ・employee は 403（フォーム・実行とも）" do
    get new_admin_company_calendars_import_url(host: tenant_host(org))
    expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

    employee = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in employee
    get new_admin_company_calendars_import_url(host: tenant_host(org))
    expect(response).to have_http_status(:forbidden)
    post admin_company_calendars_import_url(host: tenant_host(org)), params: { file: upload(valid_csv) }
    expect(response).to have_http_status(:forbidden)
    expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.count }).to eq(0)
  end

  describe "hr_admin" do
    before { sign_in admin }

    it "取り込み成功で一覧へ（303・作成/更新件数の notice）" do
      post admin_company_calendars_import_url(host: tenant_host(org)), params: { file: upload(valid_csv) }
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_company_calendars_url(host: tenant_host(org)))
      follow_redirect!
      expect(response.body).to include("作成 1 件").and include("更新 0 件")
    end

    it "エラー CSV は 422 + 行番号表示 + DB 不変（全件不採用）" do
      bad = "date,day_type,name,counts_as_paid_leave\n2026-01-01,holiday,元日,\nbogus,holiday,x,\n"
      post admin_company_calendars_import_url(host: tenant_host(org)), params: { file: upload(bad) }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("3 行目")
      expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.count }).to eq(0)
    end

    it "降格 checkbox: 未チェックで 422・チェックで成功（35% 保護）" do
      ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-05-10", day_type: :legal_holiday) }
      demote = "date,day_type,name,counts_as_paid_leave\n2026-05-10,holiday,祝日,\n"

      post admin_company_calendars_import_url(host: tenant_host(org)), params: { file: upload(demote) }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("法定休日")

      post admin_company_calendars_import_url(host: tenant_host(org)),
           params: { file: upload(demote), allow_demotion: "1" }
      expect(response).to have_http_status(:see_other)
      expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.find_by!(date: "2026-05-10").day_type }).to eq("holiday")
    end

    it "file 無しは 422（500 にしない）" do
      post admin_company_calendars_import_url(host: tenant_host(org))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("ファイルを選択")
    end
  end
end
```

- [ ] **Step 2: テストが落ちることを確認**

Run: `bundle exec rspec spec/requests/admin_company_calendar_imports_spec.rb`
Expected: FAIL（`uninitialized constant Admin::CompanyCalendars::ImportsController`。route は Task 4 で定義済み）

- [ ] **Step 3: 実装**

`app/controllers/admin/company_calendars/imports_controller.rb`:

```ruby
module Admin
  module CompanyCalendars
    class ImportsController < BaseController
      def new
        authorize [ :admin, CompanyCalendar ], :import? # レコード不在 → クラス authorize（0b-3 設計 §4）
      end

      def create
        authorize [ :admin, CompanyCalendar ], :import?
        parsed = ::CompanyCalendars::CsvParser.parse(params[:file])
        if parsed.success?
          result = ::CompanyCalendars::BulkUpserter.new(
            organization: ActsAsTenant.current_tenant,
            allow_demotion: params[:allow_demotion] == "1").call(parsed.rows)
          if result.success?
            redirect_to admin_company_calendars_path, status: :see_other,
                        notice: "取り込みました（作成 #{result.created_count} 件・更新 #{result.updated_count} 件）"
            return
          end
          @errors = result.errors
        else
          @errors = parsed.errors
        end
        render :new, status: :unprocessable_entity
      end
    end
  end
end
```

`app/views/admin/company_calendars/_bulk_errors.html.erb`（インポート・一括生成で共用）:

```erb
<% if errors.present? %>
  <div class="mb-4 rounded border border-red-400 bg-red-50 p-3 text-red-800">
    <p class="font-bold">取り込めませんでした（全件不採用）:</p>
    <ul class="list-disc pl-5">
      <% errors.each do |e| %>
        <li><%= "#{e.line} 行目: " if e.line %><%= e.message %></li>
      <% end %>
    </ul>
  </div>
<% end %>
```

`app/views/admin/company_calendars/imports/new.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold">会社カレンダー CSV インポート</h2>

<%= render "admin/company_calendars/bulk_errors", errors: @errors %>

<%= form_with url: admin_company_calendars_import_path, method: :post,
      multipart: true, class: "max-w-xl space-y-4 text-sm" do |f| %>
  <div><%= f.file_field :file, accept: ".csv", class: "rounded border p-2" %></div>
  <div>
    <%= f.label :allow_demotion, class: "font-bold" do %>
      <%= f.check_box :allow_demotion %> 既存の法定休日（legal_holiday）の変更を許可する
    <% end %>
    <p class="text-gray-500">法定休日を他の種別へ変更すると 35% 割増の対象から外れます（賃金未払リスク）。意図した変更の場合のみ有効にしてください。</p>
  </div>
  <%= f.submit "インポート", class: "rounded bg-gray-800 px-4 py-2 text-white" %>
<% end %>

<section class="mt-8 max-w-xl space-y-2 text-sm text-gray-700">
  <h3 class="font-bold">フォーマット</h3>
  <ul class="list-disc pl-5">
    <li>UTF-8（BOM 可）・ヘッダ必須・上限 2,000 行 / 1MB。<%= link_to "サンプル CSV", "/samples/company_calendar_sample.csv", class: "underline" %></li>
    <li>列: date（YYYY-MM-DD・必須）/ day_type（必須）/ name（祝日・会社休業日は必須）/ counts_as_paid_leave（true/1/false/0/空=false・会社休業日のみ）</li>
    <li>day_type の値: weekday / saturday / sunday / holiday / company_holiday / legal_holiday</li>
    <li>年度は日付から自動算出されるため列に含めません。既存日付の行は上書きされます</li>
    <li>counts_as_paid_leave を true にする運用には計画的付与の労使協定等の根拠が必要です（労基法 39 条 6 項）</li>
  </ul>
  <h3 class="font-bold">内閣府の祝日 CSV を使う場合</h3>
  <ol class="list-decimal pl-5">
    <li>内閣府サイトの「国民の祝日」CSV（Shift_JIS）をダウンロード</li>
    <li>表計算ソフトで開き、ヘッダを date / day_type / name に変更し day_type 列へ holiday を入力</li>
    <li>UTF-8 の CSV として保存してインポート</li>
  </ol>
</section>
```

`public/samples/company_calendar_sample.csv`:

```csv
date,day_type,name,counts_as_paid_leave
2026-01-01,holiday,元日,
2026-02-11,holiday,建国記念の日,
2026-08-13,company_holiday,夏季休業,true
2026-04-05,legal_holiday,法定休日,
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/requests/admin_company_calendar_imports_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/controllers/admin/company_calendars app/views/admin/company_calendars \
        public/samples spec/requests/admin_company_calendar_imports_spec.rb
git commit -m "feat: 会社カレンダー CSV インポート（全件検証・降格チェックボックス・サンプル CSV）"
```

---

### Task 8: CompanyCalendars::LegalHolidayRowsBuilder

**Files:**
- Create: `app/services/company_calendars/legal_holiday_rows_builder.rb`
- Test: `spec/services/company_calendars/legal_holiday_rows_builder_spec.rb`

- [ ] **Step 1: failing spec を書く**

`spec/services/company_calendars/legal_holiday_rows_builder_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe CompanyCalendars::LegalHolidayRowsBuilder do
  it "期間内の該当曜日（ISO cwday）だけを legal_holiday 行にする" do
    # 2026-06-01 は月曜。日曜（cwday 7）は 6/7・6/14 の 2 件
    result = described_class.build(start_date: "2026-06-01", end_date: "2026-06-14", cwday: "7")

    expect(result).to be_success
    expect(result.rows).to eq([
      { line: 1, date: Date.new(2026, 6, 7), day_type: "legal_holiday", name: "法定休日", counts_as_paid_leave: false },
      { line: 2, date: Date.new(2026, 6, 14), day_type: "legal_holiday", name: "法定休日", counts_as_paid_leave: false }
    ])
  end

  it "日付不正・曜日未選択・期間逆転・2 年超は行 nil のエラー" do
    expect(described_class.build(start_date: "bogus", end_date: "2026-06-14", cwday: "7")
      .errors.first.message).to include("YYYY-MM-DD")
    expect(described_class.build(start_date: "2026-06-01", end_date: "2026-06-14", cwday: "")
      .errors.first.message).to include("曜日")
    expect(described_class.build(start_date: "2026-06-14", end_date: "2026-06-01", cwday: "7")
      .errors.first.message).to include("終了日")
    expect(described_class.build(start_date: "2026-01-01", end_date: "2028-01-03", cwday: "7")
      .errors.first.message).to include("2 年")
  end

  it "2 年ちょうど（閏年込み 731 日差）は許容（境界）" do
    result = described_class.build(start_date: "2026-01-01", end_date: "2028-01-01", cwday: "7")
    expect(result).to be_success
  end
end
```

- [ ] **Step 2: テストが落ちることを確認**

Run: `bundle exec rspec spec/services/company_calendars/legal_holiday_rows_builder_spec.rb`
Expected: FAIL（`uninitialized constant`）

- [ ] **Step 3: 実装**

`app/services/company_calendars/legal_holiday_rows_builder.rb`:

```ruby
module CompanyCalendars
  # 期間 × 曜日 → legal_holiday 行の生成（週休制専用 — 4 週 4 日制は CSV 個別登録・0b-3 設計 §3）。
  # 生成は labor 有利方向（→ legal_holiday）のみなので BulkUpserter の降格ガードに掛からない
  class LegalHolidayRowsBuilder
    MAX_PERIOD_DAYS = 731 # 2 年（閏年込み）— 行数爆発と「長期登録による失効先送り」の抑止

    Result = Data.define(:rows, :errors) do
      def success? = errors.empty?
    end

    def self.build(start_date:, end_date:, cwday:)
      errors = []
      from = parse_date(start_date)
      to = parse_date(end_date)
      wday = cwday.to_s.match?(/\A[1-7]\z/) ? cwday.to_i : nil # ISO 曜日番号（月=1〜日=7）
      errors << RowError.new(line: nil, message: "開始日・終了日は YYYY-MM-DD 形式で指定してください") if from.nil? || to.nil?
      errors << RowError.new(line: nil, message: "曜日を選択してください") if wday.nil?
      if from && to
        errors << RowError.new(line: nil, message: "終了日は開始日以降にしてください") if to < from
        errors << RowError.new(line: nil, message: "期間は 2 年以内にしてください") if (to - from).to_i > MAX_PERIOD_DAYS
      end
      return Result.new(rows: [], errors:) if errors.any?

      rows = (from..to).select { |d| d.cwday == wday }.map.with_index(1) do |date, line|
        { line:, date:, day_type: "legal_holiday", name: "法定休日", counts_as_paid_leave: false }
      end
      Result.new(rows:, errors: [])
    end

    def self.parse_date(value)
      Date.iso8601(value.to_s)
    rescue Date::Error
      nil
    end
    private_class_method :parse_date
  end
end
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/services/company_calendars/legal_holiday_rows_builder_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/services/company_calendars/legal_holiday_rows_builder.rb \
        spec/services/company_calendars/legal_holiday_rows_builder_spec.rb
git commit -m "feat: CompanyCalendars::LegalHolidayRowsBuilder（期間×曜日・2 年上限）"
```

---

### Task 9: LegalHolidayGenerationsController + ビュー

**Files:**
- Create: `app/controllers/admin/company_calendars/legal_holiday_generations_controller.rb`
- Create: `app/views/admin/company_calendars/legal_holiday_generations/new.html.erb`
- Test: `spec/requests/admin_company_calendar_legal_holiday_generations_spec.rb`

- [ ] **Step 1: failing request spec を書く**

`spec/requests/admin_company_calendar_legal_holiday_generations_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Admin::CompanyCalendars::LegalHolidayGenerations", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }

  it "未認証はサインインへ・employee は 403 + DB 不変" do
    get new_admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org))
    expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

    employee = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in employee
    post admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org)),
         params: { start_date: "2026-06-01", end_date: "2026-06-14", cwday: "7" }
    expect(response).to have_http_status(:forbidden)
    expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.count }).to eq(0)
  end

  describe "hr_admin" do
    before { sign_in admin }

    it "フォーム表示（注意文 — 就業規則整合・週休制専用）" do
      get new_admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org))
      expect(response.body).to include("就業規則").and include("4 週 4 日")
    end

    it "一括登録成功（既存の祝日も legal_holiday で上書き — 労働者有利方向）" do
      ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-06-07", name: "何かの祝日") }
      post admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org)),
           params: { start_date: "2026-06-01", end_date: "2026-06-14", cwday: "7" }

      expect(response).to have_http_status(:see_other)
      ActsAsTenant.with_tenant(org) do
        expect(CompanyCalendar.legal_holiday.pluck(:date)).to contain_exactly(
          Date.new(2026, 6, 7), Date.new(2026, 6, 14))
      end
    end

    it "期間超過・曜日未選択は 422 + DB 不変" do
      post admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org)),
           params: { start_date: "2026-01-01", end_date: "2030-01-01", cwday: "7" }
      expect(response).to have_http_status(:unprocessable_entity)

      post admin_company_calendars_legal_holiday_generation_url(host: tenant_host(org)),
           params: { start_date: "2026-06-01", end_date: "2026-06-14", cwday: "" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.count }).to eq(0)
    end
  end
end
```

- [ ] **Step 2: テストが落ちることを確認**

Run: `bundle exec rspec spec/requests/admin_company_calendar_legal_holiday_generations_spec.rb`
Expected: FAIL（`uninitialized constant ... LegalHolidayGenerationsController`）

- [ ] **Step 3: 実装**

`app/controllers/admin/company_calendars/legal_holiday_generations_controller.rb`:

```ruby
module Admin
  module CompanyCalendars
    class LegalHolidayGenerationsController < BaseController
      def new
        authorize [ :admin, CompanyCalendar ], :generate?
      end

      def create
        authorize [ :admin, CompanyCalendar ], :generate?
        built = ::CompanyCalendars::LegalHolidayRowsBuilder.build(
          start_date: params[:start_date], end_date: params[:end_date], cwday: params[:cwday])
        if built.success?
          # 生成は legal_holiday への上書きのみ（労働者有利方向）— allow_demotion 不要
          result = ::CompanyCalendars::BulkUpserter.new(
            organization: ActsAsTenant.current_tenant).call(built.rows)
          if result.success?
            redirect_to admin_company_calendars_path, status: :see_other,
                        notice: "法定休日を登録しました（作成 #{result.created_count} 件・更新 #{result.updated_count} 件）"
            return
          end
          @errors = result.errors
        else
          @errors = built.errors
        end
        render :new, status: :unprocessable_entity
      end
    end
  end
end
```

`app/views/admin/company_calendars/legal_holiday_generations/new.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold">法定休日の一括登録</h2>

<%= render "admin/company_calendars/bulk_errors", errors: @errors %>

<%= form_with url: admin_company_calendars_legal_holiday_generation_path, method: :post,
      class: "max-w-xl space-y-4 text-sm" do |f| %>
  <div class="rounded border border-yellow-400 bg-yellow-50 p-3 text-yellow-800">
    <ul class="list-disc pl-5">
      <li>就業規則上の法定休日の定めと一致させてください（35% 割増賃金の計算根拠になります）</li>
      <li>本フォームは週休制（毎週特定曜日が法定休日）専用です。4 週 4 日制（労基法 35 条 2 項）の組織は CSV で個別登録してください</li>
      <li>期間内の該当曜日に既存の登録（祝日等）がある場合は法定休日で上書きされます</li>
    </ul>
  </div>
  <div><%= f.label :start_date, "開始日", class: "block font-bold" %><%= f.date_field :start_date, class: "rounded border p-2" %></div>
  <div><%= f.label :end_date, "終了日（開始日から 2 年以内）", class: "block font-bold" %><%= f.date_field :end_date, class: "rounded border p-2" %></div>
  <div>
    <%= f.label :cwday, "曜日", class: "block font-bold" %>
    <%# 既定なしの必須選択 — 日曜既定は就業規則と不一致のままの誤クリック確定を誘発（0b-3 設計 §3） %>
    <%= f.select :cwday,
          [ [ "月曜", 1 ], [ "火曜", 2 ], [ "水曜", 3 ], [ "木曜", 4 ], [ "金曜", 5 ], [ "土曜", 6 ], [ "日曜", 7 ] ],
          { include_blank: "選択してください" }, class: "rounded border p-2" %>
  </div>
  <%= f.submit "一括登録", class: "rounded bg-gray-800 px-4 py-2 text-white" %>
<% end %>
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/requests/admin_company_calendar_legal_holiday_generations_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/controllers/admin/company_calendars/legal_holiday_generations_controller.rb \
        app/views/admin/company_calendars/legal_holiday_generations \
        spec/requests/admin_company_calendar_legal_holiday_generations_spec.rb
git commit -m "feat: 法定休日の一括登録（期間×曜日・曜日必須選択・運用注意文）"
```

---

### Task 10: CompanyCalendarResolver

**Files:**
- Create: `app/services/company_calendar_resolver.rb`
- Test: `spec/services/company_calendar_resolver_spec.rb`

- [ ] **Step 1: failing spec を書く**

`spec/services/company_calendar_resolver_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe CompanyCalendarResolver do
  let(:org) { create(:organization) }
  let(:resolver) { described_class.new(organization: org) }

  before do
    ActsAsTenant.with_tenant(org) do
      create(:company_calendar, date: "2026-01-01", day_type: :holiday, name: "元日")
      create(:company_calendar, date: "2026-01-04", day_type: :legal_holiday) # 日曜
    end
  end

  describe "#day_type" do
    it "登録日はレコードの値・未登録日は ISO 曜日フォールバック（§4.7）" do
      expect(resolver.day_type(Date.new(2026, 1, 1))).to eq(:holiday)
      expect(resolver.day_type(Date.new(2026, 1, 4))).to eq(:legal_holiday)
      # 未登録: 2026-01-05 月 / 2026-01-10 土 / 2026-01-11 日
      expect(resolver.day_type(Date.new(2026, 1, 5))).to eq(:weekday)
      expect(resolver.day_type(Date.new(2026, 1, 10))).to eq(:saturday)
      expect(resolver.day_type(Date.new(2026, 1, 11))).to eq(:sunday)
    end

    it "他テナントの登録日は拾わない（without_tenant 文脈でも自テナント解決）" do
      ActsAsTenant.with_tenant(create(:organization)) do
        create(:company_calendar, date: "2026-01-05", day_type: :company_holiday, name: "他社休業")
      end
      result = ActsAsTenant.without_tenant { resolver.day_type(Date.new(2026, 1, 5)) }
      expect(result).to eq(:weekday)
    end
  end

  describe "#registered?" do
    it "登録由来かフォールバック由来かを判別（Phase 1 の 35% 警告の手がかり — 設計 §3）" do
      expect(resolver.registered?(Date.new(2026, 1, 4))).to be(true)
      expect(resolver.registered?(Date.new(2026, 1, 11))).to be(false)
    end
  end

  describe "#day_types（範囲一括）" do
    it "範囲内の全日付を解決した Hash を返す（未登録日はフォールバック済み）" do
      result = resolver.day_types(Date.new(2026, 1, 1), Date.new(2026, 1, 5))
      expect(result).to eq(
        Date.new(2026, 1, 1) => :holiday,
        Date.new(2026, 1, 2) => :weekday,
        Date.new(2026, 1, 3) => :saturday,
        Date.new(2026, 1, 4) => :legal_holiday,
        Date.new(2026, 1, 5) => :weekday)
    end
  end

  it "organization: nil は ArgumentError" do
    expect { described_class.new(organization: nil) }.to raise_error(ArgumentError)
  end
end
```

- [ ] **Step 2: テストが落ちることを確認**

Run: `bundle exec rspec spec/services/company_calendar_resolver_spec.rb`
Expected: FAIL（`uninitialized constant CompanyCalendarResolver`）

- [ ] **Step 3: 実装**

`app/services/company_calendar_resolver.rb`:

```ruby
# 日付 → day_type の解決（SPEC §4.7 指定名のため CompanyCalendars:: 名前空間外 — 0b-3 設計 §1）。
# AR 依存ゆえ calculators（値→値・DB なし）には置けない。Phase 1 では入力合成層（service/job）が
# 本クラスを呼び、calculator へは day_type を**値として**渡すこと（SPEC §2.2-1 の境界）
class CompanyCalendarResolver
  # 未登録日の ISO 曜日フォールバック（ロケール非依存・SPEC §4.7）: 1〜5=weekday / 6=saturday / 7=sunday
  FALLBACK_DAY_TYPES = { 6 => :saturday, 7 => :sunday }.freeze

  # organization 明示必須 — without_tenant 文脈の fail-open 遮断（0b-3 設計 §3）
  def initialize(organization:)
    raise ArgumentError, "organization は必須です" if organization.nil?

    @organization = organization
  end

  def day_type(date)
    with_tenant { CompanyCalendar.find_by(date: date)&.day_type&.to_sym } || fallback(date)
  end

  # 登録由来かフォールバック由来かの判別 — Phase 1 の「未特定の休日労働は 35% 側 or 警告」の手がかり。
  # フォールバックの :sunday を「所定休日」と断定させない（労務レビュー反映・0b-3 設計 §3）
  def registered?(date)
    with_tenant { CompanyCalendar.exists?(date: date) }
  end

  # 範囲一括（1 クエリ）— 月次処理の N+1 を防ぎ、生 SQL へ逃げる誘因を残さない
  def day_types(from, to)
    registered = with_tenant { CompanyCalendar.where(date: from..to).pluck(:date, :day_type).to_h }
    (from..to).index_with { |d| registered[d]&.to_sym || fallback(d) }
  end

  private

  def fallback(date)
    FALLBACK_DAY_TYPES.fetch(date.cwday, :weekday)
  end

  def with_tenant(&) = ActsAsTenant.with_tenant(@organization, &)
end
```

- [ ] **Step 4: テストが通ることを確認**

Run: `bundle exec rspec spec/services/company_calendar_resolver_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/services/company_calendar_resolver.rb spec/services/company_calendar_resolver_spec.rb
git commit -m "feat: CompanyCalendarResolver（ISO 曜日フォールバック・registered? 判別・範囲一括 API）"
```

---

### Task 11: dev seed

**Files:**
- Modify: `db/seeds.rb`
- Test: `spec/seeds_spec.rb`（既存 — 冪等性検証が新 seed を自動的にカバー）

- [ ] **Step 1: seeds に会社カレンダーを追加**

`db/seeds.rb` の `LeaveType.find_or_create_by!(name: "代休") ...` の行の後に追記:

```ruby
    # 会社カレンダー（0b-3）— §16.7-4 のオンボーディング動作確認用（祝日数件 + 日曜の法定休日 4 週分）
    [
      { date: "2026-01-01", day_type: :holiday, name: "元日" },
      { date: "2026-02-11", day_type: :holiday, name: "建国記念の日" },
      { date: "2026-08-13", day_type: :company_holiday, name: "夏季休業", counts_as_paid_leave: true }
    ].each do |attrs|
      CompanyCalendar.find_or_create_by!(date: attrs[:date]) do |cal|
        cal.day_type = attrs[:day_type]
        cal.name = attrs[:name]
        cal.counts_as_paid_leave = attrs.fetch(:counts_as_paid_leave, false)
      end
    end
    (Date.new(2026, 6, 7)..Date.new(2026, 6, 28)).select { |d| d.cwday == 7 }.each do |sunday|
      CompanyCalendar.find_or_create_by!(date: sunday) do |cal|
        cal.day_type = :legal_holiday
        cal.name = "法定休日"
      end
    end
```

- [ ] **Step 2: 冪等性を spec で確認**

Run: `bundle exec rspec spec/seeds_spec.rb`
Expected: PASS（2 回実行で件数不変 — 既存 spec が新 seed の冪等性と新バリデーション通過を兼ねて検証）

- [ ] **Step 3: Commit**

```bash
git add db/seeds.rb
git commit -m "feat: dev seed に会社カレンダー初期データ（祝日・会社休業日・法定休日）"
```

---

### Task 12: SPEC・LABOR_LAW_REVIEW_NOTES・ROADMAP への逆反映

**Files:**
- Modify: `docs/SPEC.md`（§5.5・§4.15・§4.7・§12.3）
- Modify: `docs/LABOR_LAW_REVIEW_NOTES.md`（#10・#11 追記）
- Modify: `docs/ROADMAP.md`（バックログ 2 件 + 0b-5 行注記。0b-3 行のチェックは PR 番号確定時 = Task 13）

- [ ] **Step 1: SPEC §5.5 — 有給除外リストに legal_holiday を追加**

`docs/SPEC.md` §5.5 のコードブロック内、`- day_type = holiday` の行の直後に追加:

```
  - day_type = legal_holiday（法定休日は労働義務がなく年休を充当しない — 0b-3 設計レビュー反映。就業規則で日曜以外を法定休日とする組織で誤消化を防ぐ）
```

- [ ] **Step 2: SPEC §4.15 — fiscal_year_end_month の SSOT 注記**

`| fiscal_year_end_month | integer | 3 | 年度終了月 |` の行を以下に置換:

```
| fiscal_year_end_month | integer | 3 | 年度終了月（**SSOT は §4.2 Organization**（DB 既定 3・NOT NULL）— 本テーブルでは保持しない。変更時の既存 fiscal_year 再計算は 0b-5 で判断） |
```

- [ ] **Step 3: SPEC §4.7 — v1 機能境界の注記**

§4.7 の「**法定休日:** …」段落の直後に追加:

```
**v1 の機能境界（0b-3）:** 本カレンダーは組織単位の単一マスタであり、シフト制・交替制の個人別法定休日は表現できない（v2 候補）。legal_holiday の「期間×曜日」一括登録は週休制（毎週特定曜日を法定休日と特定済み）専用 — 4 週 4 日制（労基法 35 条 2 項）の組織は CSV で個別登録する。
```

- [ ] **Step 4: SPEC §12.3 — 物理削除の例外注記**

§12.3 の本文末尾（`Pundit で hr_admin に限定。` の後）に追加:

```
会社カレンダーのみ物理削除（イベント参照を持たない日付事実テーブルのため・無効化統一の例外 — 0b-3 設計）。
```

- [ ] **Step 5: LABOR_LAW_REVIEW_NOTES に #10・#11 を追記**

確認事項テーブルの #9 行の直後に追加:

```
| 10 | counts_as_paid_leave（§4.7・§5.5） | 会社休業日を有給消化日として扱う（true）運用の適法要件 | 年休は労働義務のある日にのみ成立（行政解釈・原典未照合）。一斉休業日への充当は労基法 39 条 6 項の計画的付与（労使協定・5 日を超える部分に限る・原典照合済み）が根拠。使用者都合の休業は労基法 26 条の休業手当（平均賃金 60% 以上・原典照合済み）の領域 | true を許容する条件（計画的付与協定の有無確認）。true で消化した日を 39 条 7 項の 5 日取得義務にカウントしてよいか |
| 11 | 法定休日の一括生成と失効（§4.7） | 「期間×曜日」一括登録（上限 2 年）の期間満了後、未登録日が Resolver フォールバックで sunday（所定休日扱い）へ降格する設計の許容性 | 平成 6.1.4 基発第 1 号は 35% 対象休日の就業規則等での明確化を求める（原典照合済み）。「特定なき場合は週の最後の休日」とする質疑応答の原典は未照合 | カバレッジ失効時の扱い（35% 側で仮計上 or 警告のみ — Phase 4 アラート設計の前提）。暦週の起算日（日曜起算か就業規則の定めか）。「週の最後の休日」解釈の正確な出典 |
```

- [ ] **Step 6: ROADMAP — バックログ 2 件 + 0b-5 行注記**

横断バックログの末尾（Mutant 行の後）に追加:

```
- [ ] **legal_holiday カバレッジ失効の事前アラート**: 一括生成（上限 2 年）の期間満了後、未登録日曜が Resolver フォールバックで sunday に降格し 35% 側が静かに失われる。index の 0 件バナー（0b-3）が第一歩 — 残り N 日での管理者通知は Phase 4-1 の通知基盤接続後（労務レビュー高・社労士確認 #11）
- [ ] **締め済み月の CompanyCalendar destroy 制限**: 過去日の削除は Phase 1 再集計時の day_type 根拠（legal_holiday の 35%・60h 除外）を遡及的に書き換える。締め状態機械の導入（Phase 3-2）に合わせて制限を課す
```

0b-5 の行末尾に追記:

```
**+ fiscal_year_end_month 変更時の既存 CompanyCalendar.fiscal_year 再計算 or 変更禁止の判断（0b-3 設計 §0・SSOT は Organization）**
```

- [ ] **Step 7: Commit**

```bash
git add docs/SPEC.md docs/LABOR_LAW_REVIEW_NOTES.md docs/ROADMAP.md
git commit -m "docs: 0b-3 の SPEC 逆反映（§5.5 legal_holiday 除外・§4.15 SSOT・§4.7 機能境界）+ 社労士確認 #10/#11"
```

---

### Task 13: 仕上げ — レビュー・preflight・PR

**Files:**
- Modify: `docs/ROADMAP.md`（0b-3 行チェック + PR 番号）
- Modify: `docs/RAILS_GOTCHAS.md`（実装中に新しい罠を踏んだ場合のみ）

- [ ] **Step 1: 全 suite + 静的解析**

Run: `bundle exec rspec`
Expected: 全 green（既存 spec の回帰なし）

Run: `bundle exec rubocop --no-server`
Expected: no offenses

Run: `bin/brakeman --no-pager`
Expected: No warnings（file upload 周りの指摘が出た場合は内容を確認し、誤検知なら設定でなく PR 説明に記載）

- [ ] **Step 2: マージ前レビュー（設計 §8）**

- `tenant-isolation-reviewer` サブエージェントを起動（対象: migration 2 本・CompanyCalendar・services 4 本・controllers 3 本。grep 儀式: `without_tenant` / `upsert_all` / `insert_all`）
- `labor-law-compliance-reviewer` サブエージェントを起動（対象: 35% 保護 3 点セットの実装文言・SPEC 逆反映が設計の原典照合とズレていないか）
- 指摘があれば修正してコミット。新しい罠を踏んでいたら docs/RAILS_GOTCHAS.md に WHAT/WHY/HOW + verified 日付で追記（修正と同じコミット）

- [ ] **Step 3: /preflight 実行**

`/preflight` スキルで push 前 CI 等価チェックを通す。

- [ ] **Step 4: ROADMAP の 0b-3 行を更新して PR**

PR 作成後に番号が確定したら `docs/ROADMAP.md` の 0b-3 行を更新:

```
- [x] **0b-3 CompanyCalendar**（PR #NN）: CRUD・CSV 一括インポート（RFC 4180）・`CompanyCalendarResolver`（PORO・未登録日フォールバック §4.7）・legal_holiday 運用（一括生成 + 35% 保護 3 点セット）
```

```bash
# gh は sub-account アカウントになっている場合があるため kei1110 へ切替（メモリ: gh-cli-account-mismatch）
gh auth switch --user kei1110 2>/dev/null || true
git push -u origin feat/0b-3-company-calendar
gh pr create --title "feat: Phase 0b-3 CompanyCalendar（マスタ CRUD・CSV インポート・法定休日運用）" --body "$(cat <<'EOF'
## 概要
ROADMAP 0b-3。会社カレンダーの CRUD・CSV 一括インポート（RFC 4180）・法定休日一括生成・CompanyCalendarResolver（未登録日 ISO 曜日フォールバック §4.7）。

- 設計: docs/superpowers/specs/2026-06-11-phase0b3-company-calendar-design.md（5 視点並列レビュー反映・労務法令は原典照合済み）
- 計画: docs/superpowers/plans/2026-06-11-phase0b3-company-calendar.md

## 主な判断
- 共通コア BulkUpserter（全件検証 → 1 tx upsert・organization 明示引数で without_tenant fail-open 遮断）
- fiscal_year は date から自動導出（Organization#fiscal_year_for・fiscal_year_end_month を NOT NULL DEFAULT 3 化）
- 35% 保護 3 点セット: legal_holiday 降格チェックボックス・年度 0 件バナー・曜日必須選択 + 週休制専用の注意文
- 物理削除（イベント参照を持たない日付事実テーブル — §12.3 の無効化統一の例外として SPEC 注記）

## SPEC 逆反映
§5.5 有給除外リストに legal_holiday / §4.15 fiscal_year_end_month の SSOT 注記 / §4.7 v1 機能境界 / §12.3 物理削除例外 / LABOR_LAW_REVIEW_NOTES #10・#11

## 検証
- [ ] bundle exec rspec 全 green
- [ ] rubocop / brakeman クリーン
- [ ] tenant-isolation-reviewer / labor-law-compliance-reviewer 通過

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
# PR 番号確定後: ROADMAP 0b-3 行を更新してコミット・push（マージ前に含める — CLAUDE.md ワークフロー）
```

Expected: PR 作成・CI green・squash マージ可能な状態

---

## 検証サマリ（完了条件）

| コマンド | 期待 |
|---|---|
| `bundle exec rspec` | 全 green |
| `bundle exec rubocop --no-server` | no offenses |
| `bin/brakeman --no-pager` | 警告なし |
| 手動確認（任意）: `bin/dev` → acme.localhost:3000 | カレンダータブ・CSV インポート・一括生成・0 件バナーが動く |
