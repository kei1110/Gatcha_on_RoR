# Phase 0b-2 WorkPattern + LeaveType 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 勤務パターン・休暇種別マスタの CRUD（法定休憩バリデーション付き）+ i18n 日本語化を Admin 名前空間に追加する。

**Architecture:** 設計仕様 `docs/superpowers/specs/2026-06-11-phase0b2-work-pattern-leave-type-design.md`（6 視点レビュー反映済み）に従う。i18n を先に入れて新マスタを日本語前提で書き、`Admin::MasterPolicy` 基底 + `Admin::Deactivatable` concern（User 移行込み）の上に 2 リソースの CRUD を同型で並べる。

**Tech Stack:** Rails 8.1 / rails-i18n + devise-i18n（新規）/ acts_as_tenant / Pundit / RSpec。

**前提知識（このリポジトリの掟）:**
- `require_tenant = true`。spec の文脈規約は `.claude/skills/gen-spec/SKILL.md`（3 点セット + 偽テスト防止 4 規約）・罠は `docs/RAILS_GOTCHAS.md`
- 0b-1 の見本: `app/controllers/admin/users_controller.rb`（authorize/policy_scope/303 の型）・`spec/requests/admin_users_spec.rb`・`spec/policies/admin/user_policy_spec.rb`
- サブエージェント 3 か条（CLAUDE.md）: ステップごと即コミット・探索編集は revert・検証コマンド（rspec / rubocop / app 変更時 brakeman）を完了条件に

**File Structure:** 設計 §1 のとおり。タスク分解は「i18n（T1）→ WorkPattern モデル（T2-4）→ LeaveType モデル（T5）→ SPEC 逆反映 + seeds（T6）→ policy（T7）→ concern 移行（T8）→ コントローラ + ビュー（T9-10）→ ナビ（T11）→ 仕上げ（T12）」。

---

### Task 1: i18n 一式（gem・ja.yml・devise ビュー日本語化・既存 spec 修正）

**Files:**
- Modify: `Gemfile`, `config/application.rb`, `spec/system/admin_invitation_spec.rb`, `spec/system/tenant_isolation_spec.rb`, `spec/requests/admin_users_spec.rb`, `spec/mailers/tenant_devise_mailer_spec.rb`
- Create: `config/locales/ja.yml`, `app/views/devise/sessions/new.html.erb`, `app/views/devise/unlocks/new.html.erb`, `app/views/devise/mailer/reset_password_instructions.html.erb`

- [ ] **Step 1: Gemfile に追加して bundle install**

`gem "devise", "~> 5.0"` ブロックの後に:

```ruby
# 標準文言の日本語化（AR エラー・日付等 / devise flash）。手書き ja.yml は attributes 最小（0b-2 設計 §5）
gem "rails-i18n", "~> 8.0"
gem "devise-i18n", "~> 1.15"
```

Run: `bundle install`
Expected: rails-i18n 8.1.0 / devise-i18n 1.16.0（devise >= 5.0.0 対応版）が解決

- [ ] **Step 2: default_locale** — `config/application.rb` の `class Application < Rails::Application` 内に:

```ruby
    # UI は日本語のみ（SPEC §0.2 非ゴール: 多言語対応）
    config.i18n.default_locale = :ja
```

- [ ] **Step 3: config/locales/ja.yml を作成**

```yaml
ja:
  activerecord:
    models:
      organization: 組織
      user: 社員
      work_pattern: 勤務パターン
      leave_type: 休暇種別
    attributes:
      user:
        name: 氏名
        email: メールアドレス
        employee_code: 社員番号
        password: パスワード
        password_confirmation: パスワード（確認）
        role: ロール
        manager: 上長
        manager_id: 上長
        exempt_from_overtime: 管理監督者
        active: 在籍
      work_pattern:
        name: パターン名
        start_time: 始業時刻
        end_time: 終業時刻
        break_minutes: 休憩時間（分）
        standard_work_hours: 所定労働時間
        night_shift: 夜勤（日跨ぎ）
        flextime: フレックスタイム制
        core_time_start: コアタイム開始
        core_time_end: コアタイム終了
        morning_half_break_minutes: 午前半休時の休憩（分）
        afternoon_half_break_minutes: 午後半休時の休憩（分）
        active: 有効
      leave_type:
        name: 種別名
        system_type: 種別区分
        allow_half_day: 半日取得
        paid_leave: 有給消化対象
        description: 説明
        active: 有効
  leave_types:
    system_types:
      annual: 有給休暇
      substitute_holiday: 振替休日
      compensatory_leave: 代休
      child_care: 育児休業
      paternity_leave: 産後パパ育休
      other: その他
  devise:
    mailer:
      invitation_instructions:
        subject: 【Gatcha】アカウント登録のご案内
```

- [ ] **Step 4: devise sessions / unlocks ビューを生成して日本語化**

Run: `bin/rails generate devise:views -v sessions unlocks`

`app/views/devise/sessions/new.html.erb`: 見出し `Log in` → `ログイン`、submit `Log in` → `ログイン`、"Remember me" → `ログインを保持する`（ラベルは ja.yml の属性翻訳で自動日本語化されるが、ハードコード文言を一掃する）。
`app/views/devise/unlocks/new.html.erb`: 見出し → `アカウントロックの解除`、submit → `ロック解除メールを送る`。

- [ ] **Step 5: reset_password_instructions の日本語本文を作成**

`app/views/devise/mailer/reset_password_instructions.html.erb`（招待の自己救済導線で踏むため英語のままにしない — 0b-2 設計 §5）:

```erb
<p><%= @resource.name %> 様</p>

<p>パスワード再設定の依頼を受け付けました。<br>
以下のリンクから新しいパスワードを設定してください。<strong>リンクの有効期限は <%= (Devise.reset_password_within / 1.hour).to_i %> 時間です。</strong></p>

<p><%= link_to "パスワードを再設定する", edit_password_url(@resource, reset_password_token: @token) %></p>

<p>心当たりがない場合はこのメールを無視してください（パスワードは変更されません）。</p>
```

- [ ] **Step 6: 既存 spec の英語前提 6 行 + 規約違反 1 行を修正**

`spec/system/admin_invitation_spec.rb`（14-16 行付近）と `spec/system/tenant_isolation_spec.rb` の `login` ヘルパ（19-21 行付近）:

```ruby
    fill_in "メールアドレス", with: ...
    fill_in "パスワード", with: ...
    click_button "ログイン"
```

`spec/requests/admin_users_spec.rb:89` 付近の `deliveries.last.body.encoded` → `deliveries.last.body.decoded`（RAILS_GOTCHAS 規約・i18n でメール本文の CTE が変わっても壊れない）。

- [ ] **Step 7: i18n 効果の spec を追加**

`spec/mailers/tenant_devise_mailer_spec.rb` の `#invitation_instructions` describe に:

```ruby
    it "件名が ja.yml の定義どおり（humanize フォールバックでない）" do
      mail = TenantDeviseMailer.invitation_instructions(user, "RAWTOKEN123")
      expect(mail.subject).to eq("【Gatcha】アカウント登録のご案内")
    end
```

（新モデル属性由来の full_message example は Task 2 の WorkPattern spec に含める）

- [ ] **Step 8: 全 suite + rubocop で確認**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: 全 PASS（devise flash の文言 assert は spec にゼロ件 — 実測済み。落ちたら该当 assert を日本語文言に追従させ報告）

- [ ] **Step 9: Commit**

```bash
git add -A && git commit -m "feat: i18n 日本語化（rails-i18n/devise-i18n・ja.yml・devise ビュー一掃・既存 spec 追従）"
```

---

### Task 2: WorkPattern — migration・モデル基本・3 点セット

**Files:**
- Create: `db/migrate/xxx_create_work_patterns.rb`, `app/models/work_pattern.rb`, `spec/factories/work_patterns.rb`, `spec/models/work_pattern_spec.rb`

- [ ] **Step 1: migration 生成と記述**

Run: `bin/rails generate migration CreateWorkPatterns`

```ruby
class CreateWorkPatterns < ActiveRecord::Migration[8.1]
  def change
    create_table :work_patterns do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.time :start_time, null: false
      t.time :end_time, null: false
      t.integer :break_minutes, null: false
      t.decimal :standard_work_hours, precision: 4, scale: 2, null: false
      t.boolean :night_shift, null: false, default: false
      t.boolean :flextime, null: false, default: false
      t.time :core_time_start
      t.time :core_time_end
      t.integer :morning_half_break_minutes
      t.integer :afternoon_half_break_minutes
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    # テナント内一意（SPEC §3.1）
    add_index :work_patterns, [ :organization_id, :name ], unique: true
    # 複合 FK の前提となる unique index（この順序が必須 — 0b-4 の UserWorkPattern が参照）
    add_index :work_patterns, [ :organization_id, :id ], unique: true
  end
end
```

Run: `bin/rails db:migrate`（schema.rb はフックで手編集不可 — migration 経由のみ）

- [ ] **Step 2: factory**

`spec/factories/work_patterns.rb`:

```ruby
FactoryBot.define do
  factory :work_pattern do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    sequence(:name) { |n| "日勤#{n}" }
    start_time { "09:00" }
    end_time { "18:00" }
    break_minutes { 60 }
    standard_work_hours { 8 }
  end
end
```

- [ ] **Step 3: 失敗するテスト（3 点セット + presence/numericality）**

`spec/models/work_pattern_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe WorkPattern, type: :model do
  describe "name（3 点セット・gen-spec 規約）" do
    it "is unique within tenant" do
      create(:work_pattern, name: "日勤")
      expect(build(:work_pattern, name: "日勤")).not_to be_valid
    end

    it "allows same name in another tenant (鏡像)" do
      create(:work_pattern, name: "日勤")
      ActsAsTenant.with_tenant(create(:organization)) do
        expect(build(:work_pattern, name: "日勤")).to be_valid
      end
    end

    it "is enforced by composite unique index at DB level" do
      pattern = create(:work_pattern, name: "日勤")
      dup = build(:work_pattern, name: "日勤", organization: pattern.organization)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "presence / numericality" do
    it "requires name/start/end/break/standard hours" do
      wp = WorkPattern.new
      wp.valid?
      expect(wp.errors[:name]).to be_present
      expect(wp.errors[:start_time]).to be_present
      expect(wp.errors[:end_time]).to be_present
      expect(wp.errors[:break_minutes]).to be_present
      expect(wp.errors[:standard_work_hours]).to be_present
    end

    it "full_message が日本語属性名で組まれる（i18n 効果・ja.yml の手書きキーを踏む）" do
      wp = WorkPattern.new
      wp.valid?
      expect(wp.errors.full_messages).to include("パターン名を入力してください")
    end

    it "rejects negative break / zero hours / over 24h / negative half breaks" do
      expect(build(:work_pattern, break_minutes: -1)).not_to be_valid
      expect(build(:work_pattern, standard_work_hours: 0)).not_to be_valid
      expect(build(:work_pattern, standard_work_hours: 24.5)).not_to be_valid
      expect(build(:work_pattern, morning_half_break_minutes: -1)).not_to be_valid
    end
  end
end
```

- [ ] **Step 4: 失敗確認** — Run: `bundle exec rspec spec/models/work_pattern_spec.rb` → FAIL（NameError）

- [ ] **Step 5: モデル実装（基本のみ — 法定休憩は Task 3）**

`app/models/work_pattern.rb`:

```ruby
class WorkPattern < ApplicationRecord
  acts_as_tenant(:organization)

  validates :name, presence: true
  validates_uniqueness_to_tenant :name
  validates :start_time, :end_time, presence: true
  validates :break_minutes, presence: true,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :standard_work_hours, presence: true,
            numericality: { greater_than: 0, less_than_or_equal_to: 24 }
  validates :morning_half_break_minutes, :afternoon_half_break_minutes,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }, allow_nil: true
end
```

- [ ] **Step 6: PASS 確認 → Commit**

Run: `bundle exec rspec spec/models/work_pattern_spec.rb && bundle exec rspec`

```bash
git add -A && git commit -m "feat: WorkPattern モデル（複合 unique・3 点セット・基本バリデーション）"
```

---

### Task 3: WorkPattern — 法定休憩（労基法 34 条 1 項）

**Files:**
- Modify: `app/models/work_pattern.rb`, `spec/models/work_pattern_spec.rb`

- [ ] **Step 1: 失敗するテスト（境界 6 象限 + 半休）**

```ruby
  describe "法定休憩（労基法 34 条 1 項・境界 6 象限）" do
    def pattern(hours:, brk:)
      build(:work_pattern, standard_work_hours: hours, break_minutes: brk)
    end

    it "6h ちょうどは休憩 0 で valid（『超』判定）" do
      expect(pattern(hours: 6, brk: 0)).to be_valid
    end

    it "6h 超 44 分は invalid（SPEC 文言一致まで assert）" do
      wp = pattern(hours: 6.5, brk: 44)
      expect(wp).not_to be_valid
      expect(wp.errors[:base]).to include("6 時間超の勤務には 45 分以上の休憩が必要です（労基法 34 条）")
    end

    it "6h 超 45 分は valid" do
      expect(pattern(hours: 6.5, brk: 45)).to be_valid
    end

    it "8h ちょうど 45 分は valid" do
      expect(pattern(hours: 8, brk: 45)).to be_valid
    end

    it "8h 超 59 分は invalid（SPEC 文言一致）" do
      wp = pattern(hours: 8.5, brk: 59)
      expect(wp).not_to be_valid
      expect(wp.errors[:base]).to include("8 時間超の勤務には 60 分以上の休憩が必要です（労基法 34 条）")
    end

    it "8h 超 60 分は valid" do
      expect(pattern(hours: 8.5, brk: 60)).to be_valid
    end
  end

  describe "法定休憩（半休側 — standard 13h でしか発火しない点に注意・0b-2 設計 §7）" do
    # 半休所定 = 13/2 = 6.5h > 6h → 45 分必要
    let(:base) { { standard_work_hours: 13, break_minutes: 90 } }

    it "明示 44 分は invalid・45 分は valid（午前）" do
      expect(build(:work_pattern, **base, morning_half_break_minutes: 44)).not_to be_valid
      expect(build(:work_pattern, **base, morning_half_break_minutes: 45)).to be_valid
    end

    it "null は break_minutes/2 の実効値で判定（88→実効 44 invalid / 90→実効 45 valid）" do
      expect(build(:work_pattern, standard_work_hours: 13, break_minutes: 88)).not_to be_valid
      expect(build(:work_pattern, standard_work_hours: 13, break_minutes: 90)).to be_valid
    end

    it "午前のみ invalid のとき午後は独立（エラーは午前側のみ）" do
      wp = build(:work_pattern, **base, morning_half_break_minutes: 10, afternoon_half_break_minutes: 50)
      expect(wp).not_to be_valid
      expect(wp.errors[:base].join).to include("午前半休")
      expect(wp.errors[:base].join).not_to include("午後半休")
    end
  end

  describe "#effective_*_break_minutes（null フォールバックの単一ソース）" do
    it "null なら break_minutes/2・指定があればその値" do
      wp = build(:work_pattern, break_minutes: 60)
      expect(wp.effective_morning_half_break_minutes).to eq(30)
      wp.morning_half_break_minutes = 20
      expect(wp.effective_morning_half_break_minutes).to eq(20)
    end
  end
```

- [ ] **Step 2: 失敗確認** — Run: `bundle exec rspec spec/models/work_pattern_spec.rb -e 法定休憩` → FAIL

- [ ] **Step 3: 実装** — work_pattern.rb の `acts_as_tenant` の後に定数、validates 群に 2 本、public/private にメソッド:

```ruby
  # 労基法 34 条 1 項の法定値（テナント設定で改変不可・SPEC §4.4/§4.15）。
  # 検証するのは同項の「量的下限」のみ — 「労働時間の途中に」（位置）・2 項（一斉付与）・
  # 3 項（自由利用）はスキーマ上検証不能で対象外。
  # 出典: https://laws.e-gov.go.jp/law/322AC0000000049（原典照合 2026-06-11）
  # 降順必須（first-match 判定 — 順序を入れ替えると 8h 超が 45 分で valid になる）
  LEGAL_BREAK_REQUIREMENTS = [
    { over_hours: 8, min_break_minutes: 60,
      message: "8 時間超の勤務には 60 分以上の休憩が必要です（労基法 34 条）" }.freeze,
    { over_hours: 6, min_break_minutes: 45,
      message: "6 時間超の勤務には 45 分以上の休憩が必要です（労基法 34 条）" }.freeze,
  ].freeze # deep freeze — 外側だけでは内側 Hash が実行時に改変可能

  validate :break_meets_legal_minimum
  validate :half_day_breaks_meet_legal_minimum

  # null → break_minutes/2 のフォールバックを単一ソース化。
  # Phase 1 の WorkTimeCalculator 入力合成（SPEC §5.1 の同一規則）もこのメソッドを参照すること
  def effective_morning_half_break_minutes = morning_half_break_minutes || break_minutes / 2
  def effective_afternoon_half_break_minutes = afternoon_half_break_minutes || break_minutes / 2

  private

  def legal_break_rule_for(hours)
    LEGAL_BREAK_REQUIREMENTS.find { |r| hours > r[:over_hours] }
  end

  def break_meets_legal_minimum
    return if standard_work_hours.blank? || break_minutes.blank?

    rule = legal_break_rule_for(standard_work_hours)
    return if rule.nil? || break_minutes >= rule[:min_break_minutes]

    errors.add(:base, rule[:message])
  end

  # 半休所定 = standard_work_hours / 2（近似 — 実際の午前/午後は休憩位置により非対称になり得るが
  # SPEC §4.4 の定義に従う。45 分閾値に掛かるのは standard > 12h の場合のみ）
  def half_day_breaks_meet_legal_minimum
    return if standard_work_hours.blank? || break_minutes.blank?

    rule = legal_break_rule_for(standard_work_hours / 2)
    return if rule.nil?

    { "午前半休" => effective_morning_half_break_minutes,
      "午後半休" => effective_afternoon_half_break_minutes }.each do |label, minutes|
      next if minutes >= rule[:min_break_minutes]

      errors.add(:base, "#{label}時の休憩（実効 #{minutes} 分）が不足しています — #{rule[:message]}")
    end
  end
```

注: 半休 spec の「午前半休」を含む assert は上記メッセージの `#{label}` で成立する。

- [ ] **Step 4: PASS → Commit**

Run: `bundle exec rspec spec/models/work_pattern_spec.rb && bundle exec rspec`

```bash
git add -A && git commit -m "feat: 法定休憩バリデーション（労基法 34 条 1 項・境界 6 象限 + 半休実効値）"
```

---

### Task 4: WorkPattern — 補強 2 点 + mode_conflict

**Files:**
- Modify: `app/models/work_pattern.rb`, `spec/models/work_pattern_spec.rb`

- [ ] **Step 1: 失敗するテスト**

```ruby
  describe "フレックスのコアタイム（0b-2 設計 §2 補強 1）" do
    it "flextime なのにコアタイムが無いと invalid" do
      expect(build(:work_pattern, flextime: true)).not_to be_valid
    end

    it "コアタイム逆転（start >= end）は invalid" do
      wp = build(:work_pattern, flextime: true, core_time_start: "15:00", core_time_end: "10:00")
      expect(wp).not_to be_valid
      expect(wp.errors[:core_time_end]).to be_present
    end

    it "揃っていれば valid。flextime: false の core 残存は許容（無視される値）" do
      expect(build(:work_pattern, flextime: true, core_time_start: "10:00", core_time_end: "15:00")).to be_valid
      expect(build(:work_pattern, flextime: false, core_time_start: "10:00", core_time_end: "15:00")).to be_valid
    end
  end

  describe "時刻逆転（0b-2 設計 §2 補強 2）" do
    it "night_shift: false で start >= end は invalid" do
      expect(build(:work_pattern, start_time: "22:00", end_time: "07:00")).not_to be_valid
      expect(build(:work_pattern, start_time: "09:00", end_time: "09:00")).not_to be_valid
    end

    it "night_shift: true なら start > end が valid（夜勤の鏡像 — 条件なし逆転拒否の誤実装検知）" do
      expect(build(:work_pattern, night_shift: true, start_time: "22:00", end_time: "07:00")).to be_valid
    end
  end

  describe "#mode_conflict?" do
    it "night_shift × flextime の同時指定で true（保存は許可）" do
      wp = build(:work_pattern, night_shift: true, flextime: true,
                 start_time: "22:00", end_time: "07:00",
                 core_time_start: "23:00", core_time_end: "03:00")
      expect(wp).to be_valid
      expect(wp.mode_conflict?).to be(true)
      expect(build(:work_pattern).mode_conflict?).to be(false)
    end
  end
```

- [ ] **Step 2: 失敗確認** — Run: `bundle exec rspec spec/models/work_pattern_spec.rb` → 新 example FAIL

- [ ] **Step 3: 実装** — validates 群に 2 本 + public メソッド:

```ruby
  validate :core_time_required_for_flextime
  validate :times_must_not_invert_without_night_shift

  # 同時指定は保存許可・画面で警告バッジ（SPEC §4.4。優先ルールは Phase 1 計算側）
  def mode_conflict? = night_shift? && flextime?
```

private 節に:

```ruby
  # 補強 1（SPEC §4.4 へ逆反映済み）: §5.4 の遅刻早退判定はコアタイム基準 —
  # コアタイム無しの flextime は Phase 1 で判定不能データになるため書き込み時に止める
  def core_time_required_for_flextime
    return unless flextime?

    if core_time_start.blank? || core_time_end.blank?
      errors.add(:base, "フレックスタイム制にはコアタイムの開始・終了の両方が必要です")
    elsif core_time_start >= core_time_end
      errors.add(:core_time_end, "はコアタイム開始より後の時刻にしてください")
    end
  end

  # 補強 2（SPEC §4.4 へ逆反映済み）: §5.1 の翌日換算は night_shift かつ start > end が前提。
  # 非夜勤の時刻逆転は負の労働時間を生むため拒否
  def times_must_not_invert_without_night_shift
    return if night_shift? || start_time.blank? || end_time.blank?
    return if start_time < end_time

    errors.add(:end_time, "は始業時刻より後にしてください（日跨ぎ勤務は夜勤フラグを有効にしてください）")
  end
```

- [ ] **Step 4: PASS → Commit**

```bash
git add -A && git commit -m "feat: フレックスのコアタイム必須・非夜勤の時刻逆転拒否・mode_conflict?"
```

---

### Task 5: LeaveType — migration・モデル・3 点セット

**Files:**
- Create: `db/migrate/xxx_create_leave_types.rb`, `app/models/leave_type.rb`, `spec/factories/leave_types.rb`, `spec/models/leave_type_spec.rb`

- [ ] **Step 1: migration**

Run: `bin/rails generate migration CreateLeaveTypes`

```ruby
class CreateLeaveTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :leave_types do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :system_type, null: false
      t.boolean :allow_half_day, null: false, default: false
      t.boolean :paid_leave, null: false, default: false
      t.text :description
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    # テナント内一意（SPEC §3.1）
    add_index :leave_types, [ :organization_id, :name ], unique: true
    # 複合 FK の前提となる unique index（この順序が必須 — Phase 2 の LeaveRequest 等が参照）
    add_index :leave_types, [ :organization_id, :id ], unique: true
  end
end
```

Run: `bin/rails db:migrate`

- [ ] **Step 2: factory**

`spec/factories/leave_types.rb`:

```ruby
FactoryBot.define do
  factory :leave_type do
    organization { ActsAsTenant.current_tenant || ActsAsTenant.test_tenant || association(:organization) }
    sequence(:name) { |n| "休暇種別#{n}" }
    system_type { :other }
  end
end
```

- [ ] **Step 3: 失敗するテスト**

`spec/models/leave_type_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe LeaveType, type: :model do
  describe "name（3 点セット・gen-spec 規約）" do
    it "is unique within tenant" do
      create(:leave_type, name: "有給休暇")
      expect(build(:leave_type, name: "有給休暇")).not_to be_valid
    end

    it "allows same name in another tenant (鏡像)" do
      create(:leave_type, name: "有給休暇")
      ActsAsTenant.with_tenant(create(:organization)) do
        expect(build(:leave_type, name: "有給休暇")).to be_valid
      end
    end

    it "is enforced by composite unique index at DB level" do
      lt = create(:leave_type, name: "有給休暇")
      dup = build(:leave_type, name: "有給休暇", organization: lt.organization)
      expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "system_type" do
    it "全 6 値を受け付け、不正値は invalid（enum validate: true — ArgumentError 500 にしない）" do
      %i[annual substitute_holiday compensatory_leave child_care paternity_leave other].each do |t|
        expect(build(:leave_type, system_type: t)).to be_valid
      end
      lt = build(:leave_type, system_type: "bogus")
      expect(lt).not_to be_valid
    end

    it "presence（name / system_type）" do
      lt = LeaveType.new
      lt.valid?
      expect(lt.errors[:name]).to be_present
      expect(lt.errors[:system_type]).to be_present
    end
  end
end
```

- [ ] **Step 4: 失敗確認** — Run: `bundle exec rspec spec/models/leave_type_spec.rb` → FAIL

- [ ] **Step 5: 実装**

`app/models/leave_type.rb`:

```ruby
class LeaveType < ApplicationRecord
  acts_as_tenant(:organization)

  # validate: true — 不正値を代入時 ArgumentError でなくバリデーションエラーに（RAILS_GOTCHAS）
  enum :system_type, {
    annual: 0, substitute_holiday: 1, compensatory_leave: 2,
    child_care: 3, paternity_leave: 4, other: 5
  }, validate: true

  validates :name, presence: true
  validates_uniqueness_to_tenant :name
  validates :system_type, presence: true
end
```

- [ ] **Step 6: PASS → Commit**

```bash
git add -A && git commit -m "feat: LeaveType モデル（system_type enum validate・3 点セット）"
```

---

### Task 6: SPEC §4.4 逆反映 + seeds（冪等 spec つき）

**Files:**
- Modify: `docs/SPEC.md`, `db/seeds.rb`
- Create: `spec/seeds_spec.rb`

- [ ] **Step 1: SPEC §4.4 へ補強 2 点を追記**

`docs/SPEC.md` §4.4 の「`night_shift && flextime` の同時指定は…」段落の**前**に追加:

```markdown
**書き込み時の不変条件（0b-2 で追加）:** `flextime=true` は `core_time_start/end` 必須（§5.4 の遅刻早退判定がコアタイム基準のため）。`night_shift=false` は `start_time < end_time` 必須（§5.1 の翌日換算は night_shift かつ start > end が前提）。
```

- [ ] **Step 2: seeds に初期マスタを追加**

`db/seeds.rb` の `ActsAsTenant.with_tenant(org) do` ブロック内・`puts` の前に:

```ruby
    # 初期マスタ（0b-2）。found 経路はバリデーションを通らないため再実行で落ちない（冪等）
    WorkPattern.find_or_create_by!(name: "日勤") do |wp|
      wp.start_time = "09:00"; wp.end_time = "18:00"
      wp.break_minutes = 60; wp.standard_work_hours = 8
    end
    WorkPattern.find_or_create_by!(name: "夜勤") do |wp|
      wp.start_time = "22:00"; wp.end_time = "07:00"
      wp.break_minutes = 60; wp.standard_work_hours = 8; wp.night_shift = true
    end
    WorkPattern.find_or_create_by!(name: "フレックス") do |wp|
      wp.start_time = "09:00"; wp.end_time = "18:00"
      wp.break_minutes = 60; wp.standard_work_hours = 8
      wp.flextime = true; wp.core_time_start = "10:00"; wp.core_time_end = "15:00"
    end

    LeaveType.find_or_create_by!(name: "有給休暇") do |lt|
      lt.system_type = :annual; lt.paid_leave = true; lt.allow_half_day = true
    end
    LeaveType.find_or_create_by!(name: "慶弔休暇") { |lt| lt.system_type = :other }
    LeaveType.find_or_create_by!(name: "振替休日") { |lt| lt.system_type = :substitute_holiday }
    LeaveType.find_or_create_by!(name: "代休") { |lt| lt.system_type = :compensatory_leave }
```

- [ ] **Step 3: 冪等性 spec**

`spec/seeds_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "db/seeds.rb", type: :model do
  it "2 回実行しても件数不変・例外なし（冪等 + seed 値が全バリデーションを通る検証を兼ねる）" do
    ActsAsTenant.test_tenant = nil # seeds は自前で with_tenant を張る
    expect { Rails.application.load_seed }.not_to raise_error

    counts = ActsAsTenant.without_tenant { [ User.count, WorkPattern.count, LeaveType.count ] }
    expect { Rails.application.load_seed }.not_to raise_error
    expect(ActsAsTenant.without_tenant { [ User.count, WorkPattern.count, LeaveType.count ] }).to eq(counts)
  end
end
```

注: seeds は `SEED_PASSWORD` 未指定時にパスワードを puts する — テスト出力が汚れるだけで害はない。気になる場合のみ `ENV["SEED_PASSWORD"] ||= "seedpassword1!"` を spec 内で設定（報告すること）。

- [ ] **Step 4: PASS → Commit**

Run: `bundle exec rspec spec/seeds_spec.rb && bundle exec rspec`

```bash
git add -A && git commit -m "feat: 初期マスタ seed（冪等 spec つき）+ SPEC §4.4 へ補強 2 点を逆反映"
```

---

### Task 7: Admin::MasterPolicy + 個別 policy 2 つ

**Files:**
- Create: `app/policies/admin/master_policy.rb`, `app/policies/admin/work_pattern_policy.rb`, `app/policies/admin/leave_type_policy.rb`, `spec/policies/admin/work_pattern_policy_spec.rb`, `spec/policies/admin/leave_type_policy_spec.rb`

- [ ] **Step 1: 失敗するテスト（個別 policy に張る — 基底変更の波及検知。user_policy_spec と同粒度）**

`spec/policies/admin/work_pattern_policy_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Admin::WorkPatternPolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let(:record) { create(:work_pattern) }

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
      inactive = create(:work_pattern, active: false)
      ActsAsTenant.with_tenant(create(:organization)) { create(:work_pattern) }

      resolved = described_class::Scope.new(actor, WorkPattern.all).resolve
      expect(resolved).to contain_exactly(record, inactive)
    end

    it "without_tenant 文脈でも自組織のみ（organization_id 明示の fail-open 検出 — test_tenant 下では検知不能）" do
      actor = create(:user, :hr_admin)
      record # 生成
      ActsAsTenant.with_tenant(create(:organization)) { create(:work_pattern) }

      resolved = ActsAsTenant.without_tenant do
        described_class::Scope.new(actor, WorkPattern.all).resolve.to_a
      end
      expect(resolved).to contain_exactly(record)
    end
  end
end
```

`spec/policies/admin/leave_type_policy_spec.rb` — 同型（`Admin::LeaveTypePolicy` / `create(:leave_type)` / `LeaveType.all` に置換。コードは上記の机上コピーで作成し、describe 名・factory のみ差し替え）。

- [ ] **Step 2: 失敗確認** — Run: `bundle exec rspec spec/policies` → FAIL（NameError）

- [ ] **Step 3: 実装**

`app/policies/admin/master_policy.rb`:

```ruby
module Admin
  # 素の CRUD マスタ専用基底（0b-2 設計 §0 — UserPolicy は招待条件があるため継承しない。
  # 0b-3 CompanyCalendar=import あり・0b-5 OrganizationSetting=singleton の異型は
  # この基底に押し込めず個別に判断する）
  class MasterPolicy < ApplicationPolicy
    def index? = hr_admin?
    def show? = hr_admin?
    def create? = hr_admin?
    def update? = hr_admin?
    def deactivate? = hr_admin?
    def activate? = hr_admin?

    class Scope < ApplicationPolicy::Scope
      # 組織のマスタ全件（inactive 含む — 再有効化 UI の前提）。
      # organization_id 明示 = without_tenant 文脈の fail-open 遮断（user_policy と同型の二重防衛）
      def resolve = scope.where(organization_id: user.organization_id)
    end

    private

    def hr_admin? = user.hr_admin?
  end
end
```

`app/policies/admin/work_pattern_policy.rb`:

```ruby
module Admin
  class WorkPatternPolicy < MasterPolicy
  end
end
```

`app/policies/admin/leave_type_policy.rb`:

```ruby
module Admin
  class LeaveTypePolicy < MasterPolicy
  end
end
```

- [ ] **Step 4: PASS → Commit**

```bash
git add -A && git commit -m "feat: Admin::MasterPolicy 基底と WorkPattern/LeaveType policy（without_tenant 検出 spec つき）"
```

---

### Task 8: Admin::Deactivatable concern + User 移行 + 追補 3 example

**Files:**
- Create: `app/controllers/concerns/admin/deactivatable.rb`
- Modify: `app/controllers/admin/users_controller.rb`, `spec/requests/admin_users_spec.rb`

- [ ] **Step 1: user 側の追補 3 example を先に書く（既存 spec の検知穴を塞いでから移行 — RED にはならないが移行の検知網になる）**

`spec/requests/admin_users_spec.rb` の「PATCH deactivate / activate」describe に:

```ruby
    it "ガード違反の deactivate は 303 で show へ戻る（concern 移行の検知網: status + location）" do
      patch deactivate_admin_user_url(admin, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_user_url(admin, host: tenant_host(org)))
    end
```

「IDOR」describe の deactivate IDOR の後に:

```ruby
      patch activate_admin_user_url(other_user, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)

      get edit_admin_user_url(other_user, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
```

Run: `bundle exec rspec spec/requests/admin_users_spec.rb` → PASS（現実装で通ることを確認 = 移行前のベースライン）

- [ ] **Step 2: concern を作成**

`app/controllers/concerns/admin/deactivatable.rb`:

```ruby
module Admin
  # deactivate / activate の共通実装（User / WorkPattern / LeaveType — 0b-2 設計 §1）。
  # 契約: include 側は member アクションの before_action でレコードをセットし、
  # deactivatable_record で返すこと。本 concern は finder を一切持たない
  # （fail-closed — policy_scope 経由 find は各コントローラの set_* の責務）
  module Deactivatable
    extend ActiveSupport::Concern

    def deactivate
      record = deactivatable_record
      authorize [ :admin, record ]
      if record.update(active: false)
        redirect_to [ :admin, record ], status: :see_other, notice: "#{record.name} を無効化しました"
      else
        redirect_to [ :admin, record ], status: :see_other,
                    alert: record.errors.full_messages.join("。")
      end
    end

    def activate
      record = deactivatable_record
      authorize [ :admin, record ]
      if record.update(active: true)
        redirect_to [ :admin, record ], status: :see_other, notice: "#{record.name} を再有効化しました"
      else
        redirect_to [ :admin, record ], status: :see_other,
                    alert: record.errors.full_messages.join("。")
      end
    end

    private

    def deactivatable_record = raise NotImplementedError
  end
end
```

- [ ] **Step 3: UsersController を移行** — `deactivate` / `activate` メソッド 2 つを**削除**し、クラス冒頭に `include Admin::Deactivatable`、private 節に:

```ruby
    def deactivatable_record = @user
```

- [ ] **Step 4: 合格条件の確認 → Commit**

Run: `bundle exec rspec`（**既存 user 系 spec 無修正 + 追補 3 example で全 green** が合格条件）

```bash
git add -A && git commit -m "refactor: deactivate/activate を Admin::Deactivatable concern へ抽出（User 移行・検知網 3 example 追補）"
```

---

### Task 9: WorkPatterns コントローラ・ビュー・request spec

**Files:**
- Modify: `config/routes.rb`, `app/helpers/application_helper.rb`
- Create: `app/controllers/admin/work_patterns_controller.rb`, `app/views/admin/work_patterns/{index,show,new,edit,_form}.html.erb`, `spec/requests/admin_work_patterns_spec.rb`

- [ ] **Step 1: 失敗するテスト**

`spec/requests/admin_work_patterns_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Admin::WorkPatterns", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:pattern) { ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "日勤") } }

  describe "認可（403 対照ペア・未認証）" do
    it "未認証はサインインへリダイレクト" do
      get admin_work_patterns_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))
    end

    it "employee は 403・hr_admin は同一リクエストが 200（対照）" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get admin_work_patterns_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get admin_work_patterns_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end

    it "employee は write 系（PATCH update）も 403・状態不変" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      patch admin_work_pattern_url(pattern, host: tenant_host(org)), params: { work_pattern: { name: "x" } }
      expect(response).to have_http_status(:forbidden)
      expect(pattern.reload.name).to eq("日勤")
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "一覧は inactive も並び、conflict パターンに警告文言を出す（対照ペア）" do
      retired  = ActsAsTenant.with_tenant(org) { create(:work_pattern, name: "旧夜勤", active: false) }
      conflict = ActsAsTenant.with_tenant(org) do
        create(:work_pattern, name: "夜勤フレックス", night_shift: true, flextime: true,
               start_time: "22:00", end_time: "07:00", core_time_start: "23:00", core_time_end: "03:00")
      end
      get admin_work_patterns_url(host: tenant_host(org))
      expect(response.body).to include("日勤").and include("旧夜勤")
      expect(response.body).to include("夜勤・フレックス併用")          # conflict 警告
      expect(response.body.scan("夜勤・フレックス併用").size).to eq(1)  # 非 conflict 行には出ない
    end

    it "作成できる（時刻は HH:MM 表示）" do
      post admin_work_patterns_url(host: tenant_host(org)), params: { work_pattern: {
        name: "早番", start_time: "07:00", end_time: "16:00",
        break_minutes: 60, standard_work_hours: 8 } }
      created = ActsAsTenant.with_tenant(org) { WorkPattern.find_by!(name: "早番") }
      expect(response).to redirect_to(admin_work_pattern_url(created, host: tenant_host(org)))
      follow_redirect!
      expect(response.body).to include("07:00").and include("16:00")
    end

    it "法定休憩違反は 422 + :base 文言表示 + 未作成" do
      expect {
        post admin_work_patterns_url(host: tenant_host(org)), params: { work_pattern: {
          name: "違反", start_time: "09:00", end_time: "19:00",
          break_minutes: 30, standard_work_hours: 9 } }
      }.not_to change { ActsAsTenant.with_tenant(org) { WorkPattern.count } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("8 時間超の勤務には 60 分以上の休憩が必要です（労基法 34 条）")
    end

    it "permit 境界: active と organization_id を送っても無視される" do
      other_org = create(:organization)
      patch admin_work_pattern_url(pattern, host: tenant_host(org)),
            params: { work_pattern: { name: "改名", active: "false", organization_id: other_org.id } }
      pattern.reload
      expect(pattern.name).to eq("改名")
      expect(pattern.active).to be(true)
      expect(pattern.organization_id).to eq(org.id)
    end

    it "無効化 → 再有効化（303・location・concern 経由）" do
      patch deactivate_admin_work_pattern_url(pattern, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_work_pattern_url(pattern, host: tenant_host(org)))
      expect(pattern.reload.active).to be(false)

      patch activate_admin_work_pattern_url(pattern, host: tenant_host(org))
      expect(pattern.reload.active).to be(true)
    end
  end

  describe "IDOR（他テナント id は全 member アクションで 404）" do
    let!(:other) { ActsAsTenant.with_tenant(create(:organization, subdomain: "globex")) { create(:work_pattern) } }

    before { sign_in admin }

    it "show / edit / update / deactivate / activate すべて 404・副作用なし" do
      get admin_work_pattern_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      get edit_admin_work_pattern_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      patch admin_work_pattern_url(other, host: tenant_host(org)), params: { work_pattern: { name: "x" } }
      expect(response).to have_http_status(:not_found)
      patch deactivate_admin_work_pattern_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      patch activate_admin_work_pattern_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(other.reload.active).to be(true)
    end
  end

  describe "物理削除なし" do
    it "DELETE はルーティングされない" do
      sign_in admin
      expect {
        delete admin_work_pattern_url(pattern, host: tenant_host(org))
      }.to raise_error(ActionController::RoutingError)
    end
  end
end
```

- [ ] **Step 2: 失敗確認** — Run: `bundle exec rspec spec/requests/admin_work_patterns_spec.rb` → FAIL（NameError: admin_work_patterns_url）

- [ ] **Step 3: ルーティング** — `config/routes.rb` の `namespace :admin` 内 `resources :users` の後に:

```ruby
    resources :work_patterns, except: :destroy do
      member do
        patch :deactivate
        patch :activate
      end
    end
```

- [ ] **Step 4: コントローラ**

`app/controllers/admin/work_patterns_controller.rb`:

```ruby
module Admin
  class WorkPatternsController < BaseController
    include Admin::Deactivatable

    before_action :set_work_pattern, only: %i[show edit update deactivate activate]

    def index
      authorize [ :admin, WorkPattern ]
      @work_patterns = policy_scope([ :admin, WorkPattern ]).order(:name)
    end

    def show
      authorize [ :admin, @work_pattern ]
    end

    def new
      @work_pattern = WorkPattern.new
      authorize [ :admin, @work_pattern ]
    end

    def create
      @work_pattern = WorkPattern.new(work_pattern_params)
      authorize [ :admin, @work_pattern ]
      if @work_pattern.save
        redirect_to admin_work_pattern_path(@work_pattern), status: :see_other,
                    notice: "#{@work_pattern.name} を登録しました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @work_pattern ]
    end

    def update
      authorize [ :admin, @work_pattern ]
      if @work_pattern.update(work_pattern_params)
        redirect_to admin_work_pattern_path(@work_pattern), status: :see_other, notice: "更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    # 他テナント id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_work_pattern
      @work_pattern = policy_scope([ :admin, WorkPattern ]).find(params[:id])
    end

    def deactivatable_record = @work_pattern

    # active / organization_id は permit しない（active は member アクション専用・0b-2 設計 §4）
    def work_pattern_params
      params.require(:work_pattern).permit(
        :name, :start_time, :end_time, :break_minutes, :standard_work_hours,
        :night_shift, :flextime, :core_time_start, :core_time_end,
        :morning_half_break_minutes, :afternoon_half_break_minutes)
    end
  end
end
```

- [ ] **Step 5: ヘルパとビュー**

`app/helpers/application_helper.rb` に追加:

```ruby
  # time 型は 2000-01-01 ダミー日付を持つ — 表示は HH:MM に統一（0b-2 設計 §5）
  def t_time(value) = value&.strftime("%H:%M")
```

`app/views/admin/work_patterns/index.html.erb`:

```erb
<div class="mb-4 flex justify-between">
  <h2 class="text-lg font-bold">勤務パターン</h2>
  <%= link_to "新規登録", new_admin_work_pattern_path, class: "rounded bg-gray-800 px-4 py-2 text-white" %>
</div>

<table class="w-full text-left text-sm">
  <thead>
    <tr class="border-b font-bold">
      <th class="p-2">パターン名</th><th class="p-2">所定時刻</th><th class="p-2">休憩</th>
      <th class="p-2">所定労働</th><th class="p-2">区分</th><th class="p-2">状態</th>
    </tr>
  </thead>
  <tbody>
    <% @work_patterns.each do |wp| %>
      <tr class="border-b">
        <td class="p-2"><%= link_to wp.name, admin_work_pattern_path(wp), class: "underline" %></td>
        <td class="p-2"><%= t_time(wp.start_time) %>–<%= t_time(wp.end_time) %></td>
        <td class="p-2"><%= wp.break_minutes %> 分</td>
        <td class="p-2"><%= wp.standard_work_hours %> h</td>
        <td class="p-2">
          <%= "夜勤" if wp.night_shift? %> <%= "フレックス" if wp.flextime? %>
          <% if wp.mode_conflict? %>
            <span class="rounded bg-yellow-100 px-2 py-0.5 text-yellow-800">夜勤・フレックス併用</span>
          <% end %>
        </td>
        <td class="p-2"><%= wp.active? ? "有効" : "無効" %></td>
      </tr>
    <% end %>
  </tbody>
</table>
```

`app/views/admin/work_patterns/show.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold"><%= @work_pattern.name %></h2>
<% if @work_pattern.mode_conflict? %>
  <p class="mb-4 rounded bg-yellow-100 p-3 text-sm text-yellow-800">
    夜勤・フレックス併用パターンです（時刻計算は夜勤・遅刻早退はコアタイム基準 — SPEC §4.4）
  </p>
<% end %>
<dl class="space-y-2 text-sm">
  <div><dt class="inline font-bold">所定時刻:</dt> <dd class="inline"><%= t_time(@work_pattern.start_time) %>–<%= t_time(@work_pattern.end_time) %></dd></div>
  <div><dt class="inline font-bold">休憩:</dt> <dd class="inline"><%= @work_pattern.break_minutes %> 分</dd></div>
  <div><dt class="inline font-bold">所定労働時間:</dt> <dd class="inline"><%= @work_pattern.standard_work_hours %> h</dd></div>
  <div><dt class="inline font-bold">夜勤:</dt> <dd class="inline"><%= @work_pattern.night_shift? ? "はい" : "いいえ" %></dd></div>
  <div><dt class="inline font-bold">フレックス:</dt> <dd class="inline"><%= @work_pattern.flextime? ? "はい（コア #{t_time(@work_pattern.core_time_start)}–#{t_time(@work_pattern.core_time_end)}）" : "いいえ" %></dd></div>
  <div><dt class="inline font-bold">半休休憩（午前/午後）:</dt> <dd class="inline"><%= @work_pattern.effective_morning_half_break_minutes %> / <%= @work_pattern.effective_afternoon_half_break_minutes %> 分</dd></div>
  <div><dt class="inline font-bold">状態:</dt> <dd class="inline"><%= @work_pattern.active? ? "有効" : "無効" %></dd></div>
</dl>
<div class="mt-6 flex gap-2">
  <%= link_to "編集", edit_admin_work_pattern_path(@work_pattern), class: "rounded border px-4 py-2" %>
  <% if @work_pattern.active? %>
    <%= button_to "無効化", deactivate_admin_work_pattern_path(@work_pattern), method: :patch,
          data: { turbo_confirm: "#{@work_pattern.name} を無効化しますか？" }, class: "rounded bg-red-700 px-4 py-2 text-white" %>
  <% else %>
    <%= button_to "再有効化", activate_admin_work_pattern_path(@work_pattern), method: :patch, class: "rounded bg-gray-800 px-4 py-2 text-white" %>
  <% end %>
</div>
```

`app/views/admin/work_patterns/_form.html.erb`:

```erb
<%= form_with model: [ :admin, work_pattern ], class: "max-w-md space-y-4 text-sm" do |f| %>
  <% if work_pattern.errors.any? %>
    <div class="rounded border border-red-400 bg-red-50 p-3 text-red-800">
      <ul><% work_pattern.errors.full_messages.each do |msg| %><li><%= msg %></li><% end %></ul>
    </div>
  <% end %>

  <div><%= f.label :name, class: "block font-bold" %><%= f.text_field :name, class: "w-full rounded border p-2" %></div>
  <div class="flex gap-4">
    <div><%= f.label :start_time, class: "block font-bold" %><%= f.time_field :start_time, class: "rounded border p-2" %></div>
    <div><%= f.label :end_time, class: "block font-bold" %><%= f.time_field :end_time, class: "rounded border p-2" %></div>
  </div>
  <div><%= f.label :break_minutes, class: "block font-bold" %><%= f.number_field :break_minutes, class: "w-full rounded border p-2" %></div>
  <div><%= f.label :standard_work_hours, class: "block font-bold" %><%= f.number_field :standard_work_hours, step: 0.25, class: "w-full rounded border p-2" %></div>
  <div><%= f.label :night_shift, class: "font-bold" do %><%= f.check_box :night_shift %> 夜勤（日跨ぎ — 終業を翌日として扱う）<% end %></div>
  <div><%= f.label :flextime, class: "font-bold" do %><%= f.check_box :flextime %> フレックスタイム制<% end %></div>
  <div class="flex gap-4">
    <div><%= f.label :core_time_start, class: "block font-bold" %><%= f.time_field :core_time_start, class: "rounded border p-2" %></div>
    <div><%= f.label :core_time_end, class: "block font-bold" %><%= f.time_field :core_time_end, class: "rounded border p-2" %></div>
  </div>
  <div class="flex gap-4">
    <div><%= f.label :morning_half_break_minutes, class: "block font-bold" %><%= f.number_field :morning_half_break_minutes, placeholder: "未指定は休憩の半分", class: "rounded border p-2" %></div>
    <div><%= f.label :afternoon_half_break_minutes, class: "block font-bold" %><%= f.number_field :afternoon_half_break_minutes, placeholder: "未指定は休憩の半分", class: "rounded border p-2" %></div>
  </div>
  <%= f.submit work_pattern.persisted? ? "更新する" : "登録する", class: "rounded bg-gray-800 px-4 py-2 text-white" %>
<% end %>
```

`app/views/admin/work_patterns/new.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold">勤務パターンの新規登録</h2>
<%= render "form", work_pattern: @work_pattern %>
```

`app/views/admin/work_patterns/edit.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold"><%= @work_pattern.name %> の編集</h2>
<%= render "form", work_pattern: @work_pattern %>
```

- [ ] **Step 6: PASS → Commit**

Run: `bundle exec rspec spec/requests/admin_work_patterns_spec.rb && bundle exec rspec`

```bash
git add -A && git commit -m "feat: 勤務パターン CRUD（警告バッジ・IDOR 全 member・permit 境界）"
```

---

### Task 10: LeaveTypes コントローラ・ビュー・request spec

**Files:**
- Modify: `config/routes.rb`, `app/helpers/application_helper.rb`
- Create: `app/controllers/admin/leave_types_controller.rb`, `app/views/admin/leave_types/{index,show,new,edit,_form}.html.erb`, `spec/requests/admin_leave_types_spec.rb`

- [ ] **Step 1: 失敗するテスト**

`spec/requests/admin_leave_types_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "Admin::LeaveTypes", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:leave_type) { ActsAsTenant.with_tenant(org) { create(:leave_type, name: "有給休暇", system_type: :annual) } }

  describe "認可" do
    it "未認証はサインインへ・employee は 403・hr_admin は 200（対照）" do
      get admin_leave_types_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get admin_leave_types_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get admin_leave_types_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "一覧は enum を日本語表示し inactive も並ぶ" do
      retired = ActsAsTenant.with_tenant(org) { create(:leave_type, name: "旧夏季休暇", active: false) }
      get admin_leave_types_url(host: tenant_host(org))
      expect(response.body).to include("有給休暇").and include("旧夏季休暇")
      expect(response.body).not_to include("annual") # enum 生値を露出しない（i18n 表示ヘルパ）
    end

    it "作成できる" do
      post admin_leave_types_url(host: tenant_host(org)), params: { leave_type: {
        name: "夏季休暇", system_type: "other", allow_half_day: "1" } }
      created = ActsAsTenant.with_tenant(org) { LeaveType.find_by!(name: "夏季休暇") }
      expect(response).to redirect_to(admin_leave_type_url(created, host: tenant_host(org)))
    end

    it "enum 不正値は 422（ArgumentError 500 にしない）" do
      patch admin_leave_type_url(leave_type, host: tenant_host(org)),
            params: { leave_type: { system_type: "bogus" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(leave_type.reload.system_type).to eq("annual")
    end

    it "permit 境界: active と organization_id は無視される" do
      other_org = create(:organization)
      patch admin_leave_type_url(leave_type, host: tenant_host(org)),
            params: { leave_type: { name: "改名", active: "false", organization_id: other_org.id } }
      leave_type.reload
      expect(leave_type.name).to eq("改名")
      expect(leave_type.active).to be(true)
      expect(leave_type.organization_id).to eq(org.id)
    end

    it "無効化 → 再有効化（303・location）" do
      patch deactivate_admin_leave_type_url(leave_type, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_leave_type_url(leave_type, host: tenant_host(org)))
      expect(leave_type.reload.active).to be(false)

      patch activate_admin_leave_type_url(leave_type, host: tenant_host(org))
      expect(leave_type.reload.active).to be(true)
    end
  end

  describe "IDOR（全 member アクション 404）" do
    let!(:other) { ActsAsTenant.with_tenant(create(:organization, subdomain: "globex")) { create(:leave_type) } }

    before { sign_in admin }

    it "show / edit / update / deactivate / activate すべて 404・副作用なし" do
      get admin_leave_type_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      get edit_admin_leave_type_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      patch admin_leave_type_url(other, host: tenant_host(org)), params: { leave_type: { name: "x" } }
      expect(response).to have_http_status(:not_found)
      patch deactivate_admin_leave_type_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      patch activate_admin_leave_type_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(other.reload.active).to be(true)
    end
  end

  describe "物理削除なし" do
    it "DELETE はルーティングされない" do
      sign_in admin
      expect {
        delete admin_leave_type_url(leave_type, host: tenant_host(org))
      }.to raise_error(ActionController::RoutingError)
    end
  end
end
```

- [ ] **Step 2: 失敗確認** → FAIL（NameError）

- [ ] **Step 3: ルーティング**（work_patterns の後に）:

```ruby
    resources :leave_types, except: :destroy do
      member do
        patch :deactivate
        patch :activate
      end
    end
```

- [ ] **Step 4: 表示ヘルパ** — `app/helpers/application_helper.rb` に:

```ruby
  # enum 生値（annual 等）を画面に露出しない（0b-2 設計 §5）
  def t_system_type(value) = I18n.t("leave_types.system_types.#{value}")
```

- [ ] **Step 5: コントローラ**

`app/controllers/admin/leave_types_controller.rb`:

```ruby
module Admin
  class LeaveTypesController < BaseController
    include Admin::Deactivatable

    before_action :set_leave_type, only: %i[show edit update deactivate activate]

    def index
      authorize [ :admin, LeaveType ]
      @leave_types = policy_scope([ :admin, LeaveType ]).order(:name)
    end

    def show
      authorize [ :admin, @leave_type ]
    end

    def new
      @leave_type = LeaveType.new
      authorize [ :admin, @leave_type ]
    end

    def create
      @leave_type = LeaveType.new(leave_type_params)
      authorize [ :admin, @leave_type ]
      if @leave_type.save
        redirect_to admin_leave_type_path(@leave_type), status: :see_other,
                    notice: "#{@leave_type.name} を登録しました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @leave_type ]
    end

    def update
      authorize [ :admin, @leave_type ]
      if @leave_type.update(leave_type_params)
        redirect_to admin_leave_type_path(@leave_type), status: :see_other, notice: "更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    # 他テナント id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_leave_type
      @leave_type = policy_scope([ :admin, LeaveType ]).find(params[:id])
    end

    def deactivatable_record = @leave_type

    # active / organization_id は permit しない（0b-2 設計 §4）
    def leave_type_params
      params.require(:leave_type).permit(:name, :system_type, :allow_half_day, :paid_leave, :description)
    end
  end
end
```

- [ ] **Step 6: ビュー**

`app/views/admin/leave_types/index.html.erb`:

```erb
<div class="mb-4 flex justify-between">
  <h2 class="text-lg font-bold">休暇種別</h2>
  <%= link_to "新規登録", new_admin_leave_type_path, class: "rounded bg-gray-800 px-4 py-2 text-white" %>
</div>

<table class="w-full text-left text-sm">
  <thead>
    <tr class="border-b font-bold">
      <th class="p-2">種別名</th><th class="p-2">区分</th><th class="p-2">半日取得</th>
      <th class="p-2">有給消化</th><th class="p-2">状態</th>
    </tr>
  </thead>
  <tbody>
    <% @leave_types.each do |lt| %>
      <tr class="border-b">
        <td class="p-2"><%= link_to lt.name, admin_leave_type_path(lt), class: "underline" %></td>
        <td class="p-2"><%= t_system_type(lt.system_type) %></td>
        <td class="p-2"><%= lt.allow_half_day? ? "可" : "—" %></td>
        <td class="p-2"><%= lt.paid_leave? ? "対象" : "—" %></td>
        <td class="p-2"><%= lt.active? ? "有効" : "無効" %></td>
      </tr>
    <% end %>
  </tbody>
</table>
```

`app/views/admin/leave_types/show.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold"><%= @leave_type.name %></h2>
<dl class="space-y-2 text-sm">
  <div><dt class="inline font-bold">区分:</dt> <dd class="inline"><%= t_system_type(@leave_type.system_type) %></dd></div>
  <div><dt class="inline font-bold">半日取得:</dt> <dd class="inline"><%= @leave_type.allow_half_day? ? "可" : "不可" %></dd></div>
  <div><dt class="inline font-bold">有給消化対象:</dt> <dd class="inline"><%= @leave_type.paid_leave? ? "対象（残高から減算）" : "対象外" %></dd></div>
  <div><dt class="inline font-bold">説明:</dt> <dd class="inline"><%= @leave_type.description.presence || "—" %></dd></div>
  <div><dt class="inline font-bold">状態:</dt> <dd class="inline"><%= @leave_type.active? ? "有効" : "無効" %></dd></div>
</dl>
<div class="mt-6 flex gap-2">
  <%= link_to "編集", edit_admin_leave_type_path(@leave_type), class: "rounded border px-4 py-2" %>
  <% if @leave_type.active? %>
    <%= button_to "無効化", deactivate_admin_leave_type_path(@leave_type), method: :patch,
          data: { turbo_confirm: "#{@leave_type.name} を無効化しますか？" }, class: "rounded bg-red-700 px-4 py-2 text-white" %>
  <% else %>
    <%= button_to "再有効化", activate_admin_leave_type_path(@leave_type), method: :patch, class: "rounded bg-gray-800 px-4 py-2 text-white" %>
  <% end %>
</div>
```

`app/views/admin/leave_types/_form.html.erb`:

```erb
<%= form_with model: [ :admin, leave_type ], class: "max-w-md space-y-4 text-sm" do |f| %>
  <% if leave_type.errors.any? %>
    <div class="rounded border border-red-400 bg-red-50 p-3 text-red-800">
      <ul><% leave_type.errors.full_messages.each do |msg| %><li><%= msg %></li><% end %></ul>
    </div>
  <% end %>

  <div><%= f.label :name, class: "block font-bold" %><%= f.text_field :name, class: "w-full rounded border p-2" %></div>
  <div>
    <%= f.label :system_type, class: "block font-bold" %>
    <%= f.select :system_type,
          LeaveType.system_types.keys.map { |k| [ t_system_type(k), k ] }, {},
          class: "w-full rounded border p-2" %>
  </div>
  <div><%= f.label :allow_half_day, class: "font-bold" do %><%= f.check_box :allow_half_day %> 半日取得を許可<% end %></div>
  <div><%= f.label :paid_leave, class: "font-bold" do %><%= f.check_box :paid_leave %> 有給消化対象（残高から減算）<% end %></div>
  <div><%= f.label :description, class: "block font-bold" %><%= f.text_area :description, rows: 3, class: "w-full rounded border p-2" %></div>
  <%= f.submit leave_type.persisted? ? "更新する" : "登録する", class: "rounded bg-gray-800 px-4 py-2 text-white" %>
<% end %>
```

`app/views/admin/leave_types/new.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold">休暇種別の新規登録</h2>
<%= render "form", leave_type: @leave_type %>
```

`app/views/admin/leave_types/edit.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold"><%= @leave_type.name %> の編集</h2>
<%= render "form", leave_type: @leave_type %>
```

- [ ] **Step 7: PASS → Commit**

Run: `bundle exec rspec spec/requests/admin_leave_types_spec.rb && bundle exec rspec`

```bash
git add -A && git commit -m "feat: 休暇種別 CRUD（enum 日本語表示・IDOR 全 member・permit 境界）"
```

---

### Task 11: NavComponent — タブ 3 つ + active 判定の修正

**Files:**
- Modify: `app/components/admin/nav_component.rb`, `app/components/admin/nav_component.html.erb`
- Create: `spec/components/admin/nav_component_spec.rb`

- [ ] **Step 1: 失敗するテスト**

`spec/components/admin/nav_component_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Admin::NavComponent, type: :component do
  it "配下パス（/admin/users/123）でも社員タブが active・他タブは非 active（バックログ回収）" do
    with_request_url "/admin/users/123" do
      render_inline(described_class.new)
    end
    active = page.find("a", text: "社員")
    expect(active[:class]).to include("font-bold")
    expect(page.find("a", text: "勤務パターン")[:class]).not_to include("font-bold")
    expect(page.find("a", text: "休暇種別")[:class]).not_to include("font-bold")
  end
end
```

注: `type: :component` には `rails_helper` への `require "view_component/test_helpers"` + `config.include ViewComponent::TestHelpers, type: :component` が必要（spec/support/view_component.rb を新設してそこに置く）。`with_request_url` は ViewComponent::TestHelpers 標準。

`spec/support/view_component.rb`:

```ruby
require "view_component/test_helpers"
require "capybara/rspec"

RSpec.configure do |config|
  config.include ViewComponent::TestHelpers, type: :component
  config.include Capybara::RSpecMatchers, type: :component
end
```

- [ ] **Step 2: 失敗確認** → FAIL（タブが 1 つ・current_page? は配下パスで false）

- [ ] **Step 3: 実装**

`app/components/admin/nav_component.rb`:

```ruby
module Admin
  # 管理画面タブナビ。0b-3 以降のマスタはこの tabs に 1 行足すだけで乗る（0b-1 設計 §1）
  class NavComponent < ViewComponent::Base
    def tabs
      [
        [ "社員", helpers.admin_users_path ],
        [ "勤務パターン", helpers.admin_work_patterns_path ],
        [ "休暇種別", helpers.admin_leave_types_path ]
      ]
    end

    # current_page? は完全一致のため配下（show/edit）で外れる — 前方一致で判定（バックログ回収）
    def active?(path) = helpers.request.path.start_with?(path)
  end
end
```

`app/components/admin/nav_component.html.erb`:

```erb
<nav class="mb-6 border-b border-gray-300">
  <ul class="flex gap-2">
    <% tabs.each do |label, path| %>
      <li>
        <%= link_to label, path,
              class: "inline-block px-4 py-2 #{active?(path) ? 'border-b-2 border-gray-800 font-bold' : 'text-gray-500'}" %>
      </li>
    <% end %>
  </ul>
</nav>
```

- [ ] **Step 4: PASS → Commit**

Run: `bundle exec rspec spec/components && bundle exec rspec`

```bash
git add -A && git commit -m "feat: 管理タブ 3 つ + active 判定を前方一致へ（component spec つき）"
```

---

### Task 12: 仕上げ — ROADMAP・全体検証・レビュー

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: ROADMAP 更新**（チェック + PR 番号は PR 作成時。文言・バックログを先に）

- 横断バックログ: 「Admin タブの active 表示」「エラーメッセージの i18n」の 2 行を `[x]`（本スライスで回収・PR 番号は後で添える）
- 横断バックログに 3 行追加:

```markdown
- [ ] **マスタのインライン編集（SPEC §12.3）**: 0b-2 はページ遷移型 edit で機能要件を充足。Turbo 化は UX 改善として後送り
- [ ] **実労働ベースの法定休憩再判定**: マスタ検証は必要条件のみ（所定 8h・休憩 45 分は残業 1 分で 60 分不足）。Phase 1/4 の事後アラートとして検討（打刻ブロック不可・社労士確認 #8）
- [ ] **LeaveType の annual×paid_leave 整合警告**: §8.6 の有給 5 日義務判定への影響。Phase 4 着手時に再検討
```

- 0b-4 行の末尾に注記を追加: 「**+ 割当済み WorkPattern の無効化ガード要否を判断**（User ガード②と同型の論点 — 0b-2 設計 §0）」

- [ ] **Step 2: 全体検証**

Run: `bundle exec rspec && bundle exec rubocop && bin/brakeman --no-pager`
Expected: 全 PASS・no offenses・警告 0（新規警告が出たら ignore でなくまず原因を確認）

- [ ] **Step 3: レビュー 2 種（controller が dispatch）**

- `tenant-isolation-reviewer`: `git diff main...HEAD` 対象（新モデル 2・policy 基底・concern）
- `labor-law-compliance-reviewer`: 34 条実装が設計（境界・文言・deep freeze）とズレていないか

- [ ] **Step 4: Commit → /preflight → PR**

```bash
git add docs/ROADMAP.md && git commit -m "docs: ROADMAP 0b-2 関連の更新（バックログ回収 2 件・追加 3 件・0b-4 注記）"
```

`/preflight` 実行 → ユーザーに PR 作成の確認。

---

## Self-Review 結果（計画作成時に実施済み）

- **Spec coverage:** 設計 §0〜§8 全項目にタスク対応（§0 決定→T6-8/T12・§1 構成→T8-11・§2→T2-4・§3→T5・§4→T7,9,10・§5→T1,T10・§6→T6,T11・§7 の全 example→T2-11 に分配・§8→T12）
- **Placeholder:** なし（全ステップ実コード・実コマンド。LeaveType policy spec のみ「同型コピー + 置換」指示だが置換対象を明記）
- **型整合:** `deactivatable_record`（T8 定義・T9/T10 実装）・`mode_conflict?` / `effective_*_break_minutes`（T3-4 定義・T9 ビュー使用）・`t_time` / `t_system_type`（T9/T10 定義・同所使用）・`LEGAL_BREAK_REQUIREMENTS` の message キー（T3 定義・spec の文言と一致）を確認済み
