# Phase 0b-1 ユーザー管理 実装計画

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** hr_admin が画面から社員を登録・招待・編集・無効化できるユーザー管理（Admin 名前空間の最初のタブ）を構築する。

**Architecture:** 設計仕様 `docs/superpowers/specs/2026-06-10-phase0b1-user-management-design.md`（多視点レビュー反映済み）に従う。User モデルにガード 4 種と招待（recoverable 転用・`deliver_now`）を足し、`Admin::BaseController`（外殻ゲート）+ `Admin::UsersController`（全アクションでレコード authorize・policy_scope 経由 find）+ `Admin::UserPolicy` で認可を 2 層化する。

**Tech Stack:** Rails 8.1 / Devise 5（`~> 5.0` に固定）/ acts_as_tenant / Pundit / ViewComponent（本タスクで導入）/ RSpec + FactoryBot + pundit-matchers。

**前提知識（このリポジトリの掟）:**
- `require_tenant = true`。model/policy/mailer spec は `spec/support/tenant.rb` が test_tenant を自動設定。**request/system は意図的に未設定**（HOST ヘッダ＝サブドメインでテナントを名乗る。`tenant_host(org)` ヘルパ使用）
- 既存の見本: `spec/models/user_spec.rb`（鏡像・canary の流儀）、`spec/requests/password_reset_spec.rb`（`perform_enqueued_jobs`・deliveries の change matcher・URL ホスト assert）
- コミットは各タスク末で行う（ブランチ `feature/0b-1-user-management` 上）。rubocop-autoformat フックが .rb を自動整形する

**File Structure（最終形）:**
```
Gemfile                                          # devise ~> 5.0 固定 / view_component 追加
app/models/user.rb                               # ガード①〜④・assign_internal_password・send_invitation_instructions
app/mailers/tenant_devise_mailer.rb              # invitation_instructions（public）
app/views/devise/mailer/invitation_instructions.html.erb
app/views/devise/passwords/new.html.erb, edit.html.erb  # 生成 + 日本語文言（設定/変更 兼用）
app/policies/admin/user_policy.rb
app/controllers/admin/base_controller.rb
app/controllers/admin/users_controller.rb
app/components/admin/nav_component.rb, nav_component.html.erb
app/views/layouts/admin.html.erb                 # nested layout
app/views/layouts/application.html.erb           # yield(:content) 対応（1 行変更）
app/views/admin/users/{index,show,new,edit,_form}.html.erb
config/routes.rb                                 # namespace :admin
spec/models/user_spec.rb                         # ガード 4 種を追記
spec/mailers/tenant_devise_mailer_spec.rb
spec/policies/admin/user_policy_spec.rb
spec/requests/admin_users_spec.rb
spec/system/admin_invitation_spec.rb
docs/ROADMAP.md                                  # 0b-1 行の文言修正
```

---

### Task 1: Gemfile — devise 固定 + view_component 導入

**Files:**
- Modify: `Gemfile`

- [ ] **Step 1: Gemfile を編集**

`gem "devise"` の行を置換し、認可ブロックの下に view_component を追加:

```ruby
# Authentication（protected API・内部オーバーライド依存があるため悲観固定。メジャーアップは system spec を通してから）
gem "devise", "~> 5.0"
```

`gem "pundit"` の直後に:

```ruby
# UI 部品（SPEC §2.1。Admin タブナビが初出）
gem "view_component"
```

- [ ] **Step 2: bundle install**

Run: `bundle install`
Expected: `Bundle complete!`（devise は既存 5.0.x のまま・view_component が追加される）

- [ ] **Step 3: 起動確認**

Run: `bin/rails runner "puts ViewComponent::VERSION; puts Devise::VERSION"`
Expected: それぞれのバージョンが出力され例外なし

- [ ] **Step 4: Commit**

```bash
git add Gemfile Gemfile.lock
git commit -m "chore: devise を ~> 5.0 に固定し view_component を導入（0b-1 設計 §0）"
```

---

### Task 2: ガード① 最後のアクティブ hr_admin 保護

**Files:**
- Modify: `app/models/user.rb`
- Test: `spec/models/user_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/user_spec.rb` の `describe "manager 同一テナント強制..."` ブロックの後に追加:

```ruby
  describe "ガード① 最後のアクティブ hr_admin 保護（0b-1 設計 §3）" do
    let!(:admin) { create(:user, :hr_admin) }

    context "組織唯一のアクティブ hr_admin のとき" do
      it "降格を拒否する（自分でも他人でも同じバリデーション）" do
        admin.role = :employee
        expect(admin).not_to be_valid
        expect(admin.errors[:base]).to include("組織最後の管理者は降格・無効化できません")
      end

      it "無効化を拒否する" do
        admin.active = false
        expect(admin).not_to be_valid
      end

      it "降格と無効化の同時変更も拒否する" do
        admin.assign_attributes(role: :employee, active: false)
        expect(admin).not_to be_valid
      end

      it "role/active に触れない更新は許可する" do
        admin.name = "改名 太郎"
        expect(admin).to be_valid
      end

      it "他に hr_admin はいるが inactive のとき、救済要員に数えず拒否する" do
        create(:user, :hr_admin, active: false)
        admin.role = :employee
        expect(admin).not_to be_valid
      end
    end

    context "他にアクティブな hr_admin がいるとき" do
      before { create(:user, :hr_admin) }

      it "自己降格を許可する" do
        admin.role = :employee
        expect(admin).to be_valid
      end

      it "無効化を許可する" do
        admin.active = false
        expect(admin).to be_valid
      end
    end

    it "鏡像: 他テナントの hr_admin は救済要員に数えない" do
      ActsAsTenant.with_tenant(create(:organization)) { create(:user, :hr_admin) }
      admin.role = :employee
      expect(admin).not_to be_valid
    end

    it "without_tenant 文脈（console/seed 相当）でも保護される — fail-open しない" do
      org = admin.organization
      ActsAsTenant.with_tenant(create(:organization)) { create(:user, :hr_admin) }
      ActsAsTenant.without_tenant do
        reloaded = User.find(admin.id)
        reloaded.role = :employee
        expect(reloaded).not_to be_valid
      end
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/user_spec.rb -e "ガード①" `
Expected: FAIL（バリデーション未実装で valid のまま）

- [ ] **Step 3: 実装**

`app/models/user.rb` — `validate :manager_must_belong_to_same_organization` の次の行に追加:

```ruby
  validate :hr_admin_lockout_guard, on: :update
```

private 節の末尾に追加:

```ruby
  # ガード①: 最後のアクティブ hr_admin の降格・無効化を拒否（締め出し防止・0b-1 設計 §3）
  def hr_admin_lockout_guard
    was_active_admin = (role_changed? ? role_was == "hr_admin" : hr_admin?) &&
                       (active_changed? ? active_was : active?)
    still_active_admin = hr_admin? && active?
    return unless was_active_admin && !still_active_admin
    return if other_active_hr_admin_exists?

    errors.add(:base, "組織最後の管理者は降格・無効化できません")
  end

  # organization_id を明示 — without_tenant 文脈（console/seed）で全テナント横断 COUNT に
  # なる fail-open を遮断する（0a の「default scope に加えた明示防衛」と同型）
  def other_active_hr_admin_exists?
    self.class.where(organization_id: organization_id, role: :hr_admin, active: true)
        .where.not(id: id).exists?
  end
```

- [ ] **Step 4: 成功を確認**

Run: `bundle exec rspec spec/models/user_spec.rb`
Expected: 全 PASS（既存 example も壊れていないこと）

- [ ] **Step 5: Commit**

```bash
git add app/models/user.rb spec/models/user_spec.rb
git commit -m "feat: 最後のアクティブ hr_admin の降格・無効化を拒否（締め出し防止）"
```

---

### Task 3: ガード② 部下持ち無効化のブロック

**Files:**
- Modify: `app/models/user.rb`
- Test: `spec/models/user_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**（ガード①の describe の後に追加）

```ruby
  describe "ガード② 部下持ち無効化のブロック（0b-1 設計 §3）" do
    let!(:boss) { create(:user, :manager_role) }
    let!(:other_admin) { create(:user, :hr_admin) } # ガード①と切り離すための救済要員

    it "アクティブな部下がいる間は無効化を拒否し、人数をメッセージに含める" do
      create_list(:user, 2, manager: boss)
      boss.active = false
      expect(boss).not_to be_valid
      expect(boss.errors[:base])
        .to include("アクティブな部下が 2 名います。先に上長を付け替えてください")
    end

    it "部下が全員 inactive なら無効化できる（active 条件漏れの過剰拒否を検出）" do
      create(:user, manager: boss, active: false)
      boss.active = false
      expect(boss).to be_valid
    end

    it "部下がいなければ無効化できる" do
      boss.active = false
      expect(boss).to be_valid
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/user_spec.rb -e "ガード②"`
Expected: FAIL

- [ ] **Step 3: 実装** — `validate :hr_admin_lockout_guard, on: :update` の次に:

```ruby
  validate :deactivation_requires_no_active_subordinates, on: :update
```

private 節に:

```ruby
  # ガード②: アクティブな部下を残したままの無効化を拒否（不在上長の発生防止・0b-1 設計 §3）
  def deactivation_requires_no_active_subordinates
    return unless active_changed? && !active

    count = subordinates.where(active: true).count
    return if count.zero?

    errors.add(:base, "アクティブな部下が #{count} 名います。先に上長を付け替えてください")
  end
```

- [ ] **Step 4: 成功を確認**

Run: `bundle exec rspec spec/models/user_spec.rb`
Expected: 全 PASS

- [ ] **Step 5: Commit**

```bash
git add app/models/user.rb spec/models/user_spec.rb
git commit -m "feat: アクティブな部下を持つユーザーの無効化をブロック"
```

---

### Task 4: ガード③ 上長の自己参照・循環の拒否（visited-set）

**Files:**
- Modify: `app/models/user.rb`
- Test: `spec/models/user_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
  describe "ガード③ 上長の自己参照・循環の拒否（0b-1 設計 §3）" do
    it "自分自身を上長に指定できない" do
      user = create(:user)
      user.manager_id = user.id
      expect(user).not_to be_valid
      expect(user.errors[:manager_id]).to include("は循環しています")
    end

    it "2 ノード循環 A→B→A を拒否する" do
      a = create(:user)
      b = create(:user, manager: a)
      a.manager_id = b.id
      expect(a).not_to be_valid
    end

    it "3 ノード循環 A→B→C→A を拒否する" do
      a = create(:user)
      b = create(:user, manager: a)
      c = create(:user, manager: b)
      a.manager_id = c.id
      expect(a).not_to be_valid
    end

    it "正当な長鎖（深さ 10）は valid（深さ定数を持たないことの確認）" do
      chain = [create(:user)]
      9.times { chain << create(:user, manager: chain.last) }
      newcomer = build(:user, manager: chain.last)
      expect(newcomer).to be_valid
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/user_spec.rb -e "ガード③"`
Expected: FAIL

- [ ] **Step 3: 実装** — validate 群に追加:

```ruby
  validate :manager_chain_must_not_cycle, if: :manager_id_changed?
```

private 節に:

```ruby
  # ガード③: visited-set 方式の循環検出（深さ定数を持たない — §2.2-5 の「再帰ガード」型を避ける）。
  # Phase 1 の subordinate_of?（部下可視性）が全段遡上するため、書き込み時に不変条件を守る。
  # 既知の限界: A.manager=B / B.manager=A の並行 save の競合窓は v1 受容（設計 §3）
  def manager_chain_must_not_cycle
    return if manager_id.nil?

    visited = Set[id]
    node = manager
    while node
      if visited.include?(node.id)
        errors.add(:manager_id, "は循環しています")
        return
      end
      visited << node.id
      node = node.manager
    end
  end
```

注: `manager_id == id` の自己参照は `visited = Set[id]` に最初の `node.id` が一致して検出される（分岐不要）。新規レコード（`id == nil`）は既存チェーンに含まれ得ないため自己参照は構造的に不可能。

- [ ] **Step 4: 成功を確認**

Run: `bundle exec rspec spec/models/user_spec.rb`
Expected: 全 PASS

- [ ] **Step 5: Commit**

```bash
git add app/models/user.rb spec/models/user_spec.rb
git commit -m "feat: 上長チェーンの自己参照・循環を visited-set 方式で拒否"
```

---

### Task 5: ガード④ 非アクティブ上長の指定拒否

**Files:**
- Modify: `app/models/user.rb`
- Test: `spec/models/user_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
  describe "ガード④ 非アクティブ上長の指定拒否（0b-1 設計 §3・ガード②の代入側対称）" do
    it "inactive なユーザーを上長に指定できない" do
      retired = create(:user, active: false)
      expect(build(:user, manager: retired)).not_to be_valid
    end

    it "active なユーザーは上長に指定できる" do
      expect(build(:user, manager: create(:user))).to be_valid
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/user_spec.rb -e "ガード④"`
Expected: FAIL

- [ ] **Step 3: 実装** — validate 群に追加:

```ruby
  validate :manager_must_be_active, if: :manager_id_changed?
```

private 節に:

```ruby
  # ガード④: 無効化済みユーザーの上長指定を拒否（②は無効化側・こちらは代入側の対称防御）
  def manager_must_be_active
    return if manager_id.nil? || manager.nil? # nil（スコープ外）は同一組織バリデーションが拾う
    return if manager.active?

    errors.add(:manager_id, "は在籍中（アクティブ）のユーザーである必要があります")
  end
```

- [ ] **Step 4: 成功を確認 → Commit**

Run: `bundle exec rspec spec/models/user_spec.rb` → 全 PASS

```bash
git add app/models/user.rb spec/models/user_spec.rb
git commit -m "feat: 非アクティブユーザーの上長指定を拒否"
```

---

### Task 6: 招待 — 内部パスワード・send_invitation_instructions・専用メール

**Files:**
- Modify: `app/models/user.rb`, `app/mailers/tenant_devise_mailer.rb`
- Create: `app/views/devise/mailer/invitation_instructions.html.erb`
- Test: `spec/mailers/tenant_devise_mailer_spec.rb`（新規）, `spec/models/user_spec.rb`

- [ ] **Step 1: 失敗するテストを書く（model: 内部パスワード）**

`spec/models/user_spec.rb` に追加:

```ruby
  describe "招待用の内部パスワード（0b-1 設計 §2-1）" do
    it "パスワード未指定の作成は不可知ランダムパスワードで通る" do
      user = ActsAsTenant.test_tenant && User.new(
        name: "招待 花子", email: "invited@example.com", employee_code: "E900"
      )
      expect(user.save).to be(true)
      expect(user.encrypted_password).to be_present
    end

    it "パスワード明示時は上書きしない（seeds 互換）" do
      user = create(:user, password: "knownpassword1!")
      expect(user.valid_password?("knownpassword1!")).to be(true)
    end
  end
```

- [ ] **Step 2: 失敗するテストを書く（mailer・新規ファイル）**

`spec/mailers/tenant_devise_mailer_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe TenantDeviseMailer, type: :mailer do
  describe "#invitation_instructions" do
    let(:org_a) { create(:organization, subdomain: "orga") }
    let(:user)  { ActsAsTenant.with_tenant(org_a) { create(:user, name: "招待 花子") } }

    it "鏡像: URL は宛先の組織サブドメインで組まれ、current_tenant に依存しない（偽テスト防止の要）" do
      org_b = create(:organization, subdomain: "orgb")
      mail = ActsAsTenant.with_tenant(org_b) do
        TenantDeviseMailer.invitation_instructions(user, "RAWTOKEN123")
      end
      body = mail.body.encoded
      expect(body).to include("orga.example.com")
      expect(body).not_to include("orgb.example.com")
    end

    it "文面に期限の案内と自己再設定（パスワードを忘れた）の導線を含む" do
      body = TenantDeviseMailer.invitation_instructions(user, "RAWTOKEN123").body.encoded
      expect(body).to include("6 時間")
      expect(body).to include("再設定")
    end

    it "本文に内部パスワード片（hex 64 文字）を含まない" do
      body = TenantDeviseMailer.invitation_instructions(user, "RAWTOKEN123").body.encoded
      expect(body).not_to match(/[0-9a-f]{64}/)
    end
  end
end
```

- [ ] **Step 3: 失敗を確認**

Run: `bundle exec rspec spec/mailers spec/models/user_spec.rb -e 招待`
Expected: FAIL（NoMethodError: invitation_instructions / パスワード presence エラー）

- [ ] **Step 4: 実装（model）** — `app/models/user.rb`:

`normalizes :email, ...` の次に:

```ruby
  before_validation :assign_internal_password, on: :create
```

public メソッド群（`inactive_message` の後）に:

```ruby
  # 招待メール送付（recoverable 転用・0b-1 設計 §2-2）。
  # protected な set_reset_password_token への依存をこの 1 箇所に閉じ込める
  # （recoverable の send_reset_password_instructions の鏡像）。
  # send_devise_notification は deliver_now — リクエスト文脈内で送る（§3.6 ジョブ経路を作らない）
  def send_invitation_instructions
    raw_token = set_reset_password_token
    send_devise_notification(:invitation_instructions, raw_token, {})
    raw_token
  end
```

private 節に:

```ruby
  # 招待作成は不可知ランダムパスワードで password presence を満たす（§2.2-2 の「軽微な値セット」。
  # 誰にも開示せず、本人は招待リンク（reset token）でパスワードを設定する）
  def assign_internal_password
    return if password.present? || encrypted_password.present?

    self.password = SecureRandom.hex(32)
  end
```

- [ ] **Step 5: 実装（mailer）** — `app/mailers/tenant_devise_mailer.rb` の `protected` の**前**（public 領域）に:

```ruby
  # 招待メール（Devise 標準外のカスタムアクション）。User#send_invitation_instructions から届く
  def invitation_instructions(record, token, opts = {})
    @token = token
    devise_mail(record, :invitation_instructions, opts)
  end
```

- [ ] **Step 6: 実装（メール文面）** — `app/views/devise/mailer/invitation_instructions.html.erb`:

```erb
<p><%= @resource.name %> 様</p>

<p><%= @resource.organization.name %> の勤怠管理システム Gatcha に招待されました。<br>
以下のリンクからパスワードを設定してください。<strong>リンクの有効期限は 6 時間です。</strong></p>

<p><%= link_to "パスワードを設定する", edit_password_url(@resource, reset_password_token: @token) %></p>

<p>期限が切れた場合は、リンク先の「パスワードを忘れた方はこちら」から再設定できます。<br>
このメール自体を紛失した場合は、管理者に招待の再送を依頼してください。</p>
```

- [ ] **Step 7: 成功を確認**

Run: `bundle exec rspec spec/mailers spec/models/user_spec.rb`
Expected: 全 PASS

- [ ] **Step 8: Commit**

```bash
git add app/models/user.rb app/mailers/tenant_devise_mailer.rb app/views/devise/mailer spec/mailers spec/models/user_spec.rb
git commit -m "feat: 招待メール（recoverable 転用・不可知内部パスワード・テナント鏡像 spec）"
```

---

### Task 7: devise/passwords ビューの生成と文言調整

**Files:**
- Create: `app/views/devise/passwords/new.html.erb`, `app/views/devise/passwords/edit.html.erb`

- [ ] **Step 1: ビュー生成**

Run: `bin/rails generate devise:views -v passwords`
Expected: `app/views/devise/passwords/{new,edit}.html.erb` が生成される

- [ ] **Step 2: edit.html.erb の文言を「設定/変更」兼用へ**

見出し `<h2>Change your password</h2>` → `<h2>パスワードの設定</h2>`、submit `Change my password` → `パスワードを設定する`、ラベル `New password` → `新しいパスワード`、`Confirm new password` → `新しいパスワード（確認）`。
（招待受諾者が最初に見る画面のため「変更」と書かない — 設計 §1）

- [ ] **Step 3: new.html.erb の文言**

見出し → `パスワードの再設定`、submit → `再設定メールを送る`、ラベル Email → `メールアドレス`。本文に 1 行追記:

```erb
<p class="text-sm text-gray-600">招待リンクの期限が切れた方も、ここから自分でパスワードを設定できます。</p>
```

- [ ] **Step 4: 表示確認（既存 spec が経路を担保）**

Run: `bundle exec rspec spec/requests/password_reset_spec.rb`
Expected: 全 PASS（ビュー差し替えで既存リセットフローが壊れていないこと）

- [ ] **Step 5: Commit**

```bash
git add app/views/devise/passwords
git commit -m "feat: devise passwords ビューを生成し招待受諾と兼用の日本語文言へ"
```

---

### Task 8: Admin::UserPolicy

**Files:**
- Create: `app/policies/admin/user_policy.rb`
- Test: `spec/policies/admin/user_policy_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
require "rails_helper"

RSpec.describe Admin::UserPolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let(:record) { create(:user) }

  context "hr_admin" do
    let(:actor) { create(:user, :hr_admin) }

    it { is_expected.to permit_actions(%i[index show create update deactivate activate]) }

    describe "resend_invitation?（サーバ側強制・0b-1 設計 §2-5）" do
      it "未受諾（sign_in_count 0）かつ active なら許可" do
        expect(subject.resend_invitation?).to be(true)
      end

      it "ログイン済み（受諾済）には拒否 — トークン強制発行を塞ぐ" do
        record.update_column(:sign_in_count, 1)
        expect(subject.resend_invitation?).to be(false)
      end

      it "inactive には拒否" do
        record.update_column(:active, false)
        expect(subject.resend_invitation?).to be(false)
      end
    end
  end

  context "manager" do
    let(:actor) { create(:user, :manager_role) }
    it { is_expected.to forbid_actions(%i[index show create update deactivate activate resend_invitation]) }
  end

  context "employee" do
    let(:actor) { create(:user) }
    it { is_expected.to forbid_actions(%i[index show create update deactivate activate resend_invitation]) }
  end

  describe "Scope" do
    it "組織全員（inactive 含む）を返し、他テナントを漏らさない" do
      actor    = create(:user, :hr_admin)
      member   = create(:user)
      inactive = create(:user, active: false)
      ActsAsTenant.with_tenant(create(:organization)) { create(:user) }

      resolved = described_class::Scope.new(actor, User.all).resolve
      expect(resolved).to contain_exactly(actor, member, inactive, record)
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/policies/admin/user_policy_spec.rb`
Expected: FAIL（NameError: Admin::UserPolicy）

- [ ] **Step 3: 実装** — `app/policies/admin/user_policy.rb`:

```ruby
module Admin
  class UserPolicy < ApplicationPolicy
    def index? = hr_admin?
    def show? = hr_admin?
    def create? = hr_admin?
    def update? = hr_admin?
    def deactivate? = hr_admin?
    def activate? = hr_admin?

    # sign_in_count == 0 を「未受諾」とみなす判定は sign_in_after_reset_password
    # 既定 true（受諾＝初回サインイン）に依存する（0b-1 設計 §2-5）
    def resend_invitation? = hr_admin? && record.sign_in_count.zero? && record.active?

    class Scope < ApplicationPolicy::Scope
      # 組織全員。inactive を含む（再有効化・招待再送 UI の前提 — 絞ると UI が壊れる）
      def resolve = scope.all
    end

    private

    def hr_admin? = user.hr_admin?
  end
end
```

- [ ] **Step 4: 成功を確認 → Commit**

Run: `bundle exec rspec spec/policies` → 全 PASS

```bash
git add app/policies/admin spec/policies/admin
git commit -m "feat: Admin::UserPolicy（hr_admin 限定・再送 3 条件・Scope は inactive 含む全員）"
```

---

### Task 9: Admin 名前空間の器 — routes・BaseController・レイアウト・NavComponent・index/show

**Files:**
- Modify: `config/routes.rb`, `app/views/layouts/application.html.erb`
- Create: `app/controllers/admin/base_controller.rb`, `app/controllers/admin/users_controller.rb`, `app/views/layouts/admin.html.erb`, `app/components/admin/nav_component.rb`, `app/components/admin/nav_component.html.erb`, `app/views/admin/users/index.html.erb`, `app/views/admin/users/show.html.erb`
- Test: `spec/requests/admin_users_spec.rb`（新規）

- [ ] **Step 1: 失敗するテストを書く**（index/show/403/IDOR/DELETE 不在のみ。create 系は Task 10 で追記）

```ruby
require "rails_helper"

RSpec.describe "Admin::Users", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }

  describe "GET /admin/users" do
    it "hr_admin は一覧を見られる（inactive も並ぶ）" do
      retired = ActsAsTenant.with_tenant(org) { create(:user, name: "退職 済子", active: false) }
      sign_in admin
      get admin_users_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(admin.name).and include(retired.name)
    end

    it "employee は 403（hr_admin なら同一リクエストが 200 になる対照とペア）" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get admin_users_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)
    end

    it "manager も 403" do
      manager = ActsAsTenant.with_tenant(org) { create(:user, :manager_role) }
      sign_in manager
      get admin_users_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "IDOR（他テナント id は 404）" do
    let!(:other_org)  { create(:organization, subdomain: "globex") }
    let!(:other_user) { ActsAsTenant.with_tenant(other_org) { create(:user) } }

    before { sign_in admin }

    it "show / update / deactivate / resend_invitation のすべてで 404" do
      get admin_user_url(other_user, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)

      patch admin_user_url(other_user, host: tenant_host(org)), params: { user: { name: "x" } }
      expect(response).to have_http_status(:not_found)

      patch deactivate_admin_user_url(other_user, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)

      patch resend_invitation_admin_user_url(other_user, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(other_user.reload.reset_password_token).to be_nil # 書き込み副作用なしまで確認
    end
  end

  describe "物理削除なし（0b-1 設計 §0 の regression 防止）" do
    it "DELETE はルーティングされない" do
      sign_in admin
      expect {
        delete admin_user_url(admin, host: tenant_host(org))
      }.to raise_error(ActionController::RoutingError)
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb`
Expected: FAIL（NameError: admin_users_url）

- [ ] **Step 3: ルーティング** — `config/routes.rb` の `devise_for` の後に:

```ruby
  namespace :admin do
    resources :users, except: :destroy do
      member do
        patch :deactivate
        patch :activate
        patch :resend_invitation
      end
    end
  end
```

- [ ] **Step 4: BaseController** — `app/controllers/admin/base_controller.rb`:

```ruby
module Admin
  class BaseController < ApplicationController
    layout "admin"

    before_action :require_hr_admin

    private

    # 名前空間の外殻ガード（多層防御・0b-1 設計 §1）。authorize は呼ばない —
    # verify_authorized を満たした扱いにせず、各アクションのレコード authorize を強制し続ける
    def require_hr_admin
      raise Pundit::NotAuthorizedError, "hr_admin 専用領域" unless current_user&.hr_admin?
    end
  end
end
```

- [ ] **Step 5: UsersController（index/show と共通部）** — `app/controllers/admin/users_controller.rb`:

```ruby
module Admin
  class UsersController < BaseController
    before_action :set_user, only: %i[show edit update deactivate activate resend_invitation]

    def index
      authorize [:admin, User]
      @users = policy_scope([:admin, User]).order(:employee_code)
    end

    def show
      authorize [:admin, @user]
    end

    private

    # 他テナント id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_user
      @user = policy_scope([:admin, User]).find(params[:id])
    end

    # role / manager_id / exempt_from_overtime の permit は Admin 名前空間限定（0b-1 設計 §0）。
    # active は permit しない — deactivate / activate メンバーアクション専用
    def user_params
      params.require(:user)
            .permit(:name, :email, :employee_code, :role, :manager_id, :exempt_from_overtime)
    end
  end
end
```

- [ ] **Step 6: nested layout** — `app/views/layouts/application.html.erb` の `<main>` 内を 1 行変更:

```erb
      <%= content_for?(:content) ? yield(:content) : yield %>
```

`app/views/layouts/admin.html.erb`（新規）:

```erb
<% content_for :content do %>
  <div class="w-full">
    <h1 class="mb-4 text-xl font-bold">管理</h1>
    <%= render Admin::NavComponent.new %>
    <%= yield %>
  </div>
<% end %>
<%= render template: "layouts/application" %>
```

- [ ] **Step 7: NavComponent** — `app/components/admin/nav_component.rb`:

```ruby
module Admin
  # 管理画面タブナビ。0b-2 以降のマスタはこの TABS に 1 行足すだけで乗る（0b-1 設計 §1）
  class NavComponent < ViewComponent::Base
    def tabs
      [["社員", helpers.admin_users_path]]
    end
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
              class: "inline-block px-4 py-2 #{helpers.current_page?(path) ? 'border-b-2 border-gray-800 font-bold' : 'text-gray-500'}" %>
      </li>
    <% end %>
  </ul>
</nav>
```

- [ ] **Step 8: index/show ビュー** — `app/views/admin/users/index.html.erb`:

```erb
<div class="mb-4 flex justify-between">
  <h2 class="text-lg font-bold">社員</h2>
  <%= link_to "新規登録", new_admin_user_path, class: "rounded bg-gray-800 px-4 py-2 text-white" %>
</div>

<table class="w-full text-left text-sm">
  <thead>
    <tr class="border-b font-bold">
      <th class="p-2">社員番号</th><th class="p-2">氏名</th><th class="p-2">ロール</th>
      <th class="p-2">上長</th><th class="p-2">状態</th><th class="p-2"></th>
    </tr>
  </thead>
  <tbody>
    <% @users.each do |user| %>
      <tr class="border-b">
        <td class="p-2"><%= user.employee_code %></td>
        <td class="p-2"><%= link_to user.name, admin_user_path(user), class: "underline" %></td>
        <td class="p-2"><%= t_role(user.role) %><%= "（管理監督者）" if user.exempt_from_overtime %></td>
        <td class="p-2"><%= user.manager&.name %></td>
        <td class="p-2"><%= user.active? ? "在籍" : "無効" %></td>
        <td class="p-2">
          <% if policy([:admin, user]).resend_invitation? %>
            <%= button_to "招待再送", resend_invitation_admin_user_path(user), method: :patch,
                  class: "rounded border px-2 py-1" %>
          <% end %>
        </td>
      </tr>
    <% end %>
  </tbody>
</table>
```

`app/views/admin/users/show.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold"><%= @user.name %></h2>
<dl class="space-y-2 text-sm">
  <div><dt class="inline font-bold">社員番号:</dt> <dd class="inline"><%= @user.employee_code %></dd></div>
  <div><dt class="inline font-bold">メール:</dt> <dd class="inline"><%= @user.email %></dd></div>
  <div><dt class="inline font-bold">ロール:</dt> <dd class="inline"><%= t_role(@user.role) %></dd></div>
  <div><dt class="inline font-bold">管理監督者:</dt> <dd class="inline"><%= @user.exempt_from_overtime ? "はい" : "いいえ" %></dd></div>
  <div><dt class="inline font-bold">上長:</dt> <dd class="inline"><%= @user.manager&.name || "未設定" %></dd></div>
  <div><dt class="inline font-bold">状態:</dt> <dd class="inline"><%= @user.active? ? "在籍" : "無効" %></dd></div>
</dl>
<div class="mt-6 flex gap-2">
  <%= link_to "編集", edit_admin_user_path(@user), class: "rounded border px-4 py-2" %>
  <% if @user.active? %>
    <%= button_to "無効化", deactivate_admin_user_path(@user), method: :patch,
          data: { turbo_confirm: "#{@user.name} を無効化しますか？" }, class: "rounded bg-red-700 px-4 py-2 text-white" %>
  <% else %>
    <%= button_to "再有効化", activate_admin_user_path(@user), method: :patch, class: "rounded bg-gray-800 px-4 py-2 text-white" %>
  <% end %>
</div>
```

ロール表示ヘルパ — `app/helpers/application_helper.rb` に追加:

```ruby
  ROLE_LABELS = { "employee" => "社員", "manager" => "マネージャー", "hr_admin" => "人事管理者" }.freeze

  def t_role(role) = ROLE_LABELS.fetch(role, role)
```

- [ ] **Step 9: 成功を確認**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb`
Expected: 全 PASS

- [ ] **Step 10: Commit**

```bash
git add config/routes.rb app/controllers/admin app/views/layouts app/components app/views/admin app/helpers spec/requests/admin_users_spec.rb
git commit -m "feat: Admin 名前空間の器（外殻ゲート・タブナビ・社員一覧/詳細・IDOR 404）"
```

---

### Task 10: new/create（招待送付）

**Files:**
- Modify: `app/controllers/admin/users_controller.rb`
- Create: `app/views/admin/users/new.html.erb`, `app/views/admin/users/_form.html.erb`
- Test: `spec/requests/admin_users_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**（admin_users_spec.rb に describe を追加）

```ruby
  describe "POST /admin/users（招待つき作成・0b-1 設計 §2）" do
    before { sign_in admin }

    let(:valid_params) do
      { user: { name: "新人 一郎", email: "newbie@example.com", employee_code: "A-100",
                role: "employee", exempt_from_overtime: "0" } }
    end

    it "パスワードなしで作成され、招待メールが 1 通飛ぶ" do
      expect {
        post admin_users_url(host: tenant_host(org)), params: valid_params
      }.to change { ActionMailer::Base.deliveries.count }.by(1)
        .and change { ActsAsTenant.with_tenant(org) { User.count } }.by(1)
      expect(response).to redirect_to(admin_user_url(User.last.id, host: tenant_host(org)))
    end

    it "招待メールの URL は組織サブドメイン込み" do
      post admin_users_url(host: tenant_host(org)), params: valid_params
      expect(ActionMailer::Base.deliveries.last.body.encoded).to include("acme.example.com")
    end

    it "バリデーション NG の作成ではメールが飛ばない（送付タイミングの固定）" do
      invalid = { user: valid_params[:user].merge(email: "") }
      expect {
        post admin_users_url(host: tenant_host(org)), params: invalid
      }.not_to change { ActionMailer::Base.deliveries.count }
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb -e "招待つき作成"`
Expected: FAIL（new/create 未実装）

- [ ] **Step 3: コントローラに追加**（show の後）:

```ruby
    def new
      @user = User.new
      authorize [:admin, @user]
    end

    def create
      @user = User.new(user_params)
      authorize [:admin, @user]
      if @user.save
        @user.send_invitation_instructions
        redirect_to admin_user_path(@user), notice: "#{@user.name} を登録し、招待メールを送信しました"
      else
        render :new, status: :unprocessable_entity
      end
    end
```

- [ ] **Step 4: ビュー** — `app/views/admin/users/_form.html.erb`:

```erb
<%= form_with model: [:admin, user], class: "max-w-md space-y-4 text-sm" do |f| %>
  <% if user.errors.any? %>
    <div class="rounded border border-red-400 bg-red-50 p-3 text-red-800">
      <ul><% user.errors.full_messages.each do |msg| %><li><%= msg %></li><% end %></ul>
    </div>
  <% end %>

  <div><%= f.label :name, "氏名", class: "block font-bold" %><%= f.text_field :name, class: "w-full rounded border p-2" %></div>
  <div><%= f.label :email, "メールアドレス", class: "block font-bold" %><%= f.email_field :email, class: "w-full rounded border p-2" %></div>
  <div><%= f.label :employee_code, "社員番号", class: "block font-bold" %><%= f.text_field :employee_code, class: "w-full rounded border p-2" %></div>
  <div>
    <%= f.label :role, "ロール", class: "block font-bold" %>
    <%= f.select :role, ApplicationHelper::ROLE_LABELS.invert.to_a, {}, class: "w-full rounded border p-2" %>
  </div>
  <div>
    <%= f.label :manager_id, "上長", class: "block font-bold" %>
    <%# 候補は在籍中のみ（ガード④と UI 整合）。自分自身は除外 %>
    <%= f.collection_select :manager_id,
          policy_scope([:admin, User]).where(active: true).where.not(id: user.id).order(:employee_code),
          :id, :name, { include_blank: "（未設定）" }, class: "w-full rounded border p-2" %>
  </div>
  <div>
    <%= f.label :exempt_from_overtime, class: "font-bold" do %>
      <%= f.check_box :exempt_from_overtime %> 管理監督者（労基法 41 条・割増対象外）
    <% end %>
  </div>
  <%= f.submit user.persisted? ? "更新する" : "登録して招待メールを送る", class: "rounded bg-gray-800 px-4 py-2 text-white" %>
<% end %>
```

`app/views/admin/users/new.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold">社員の新規登録</h2>
<p class="mb-4 text-sm text-gray-600">パスワードは本人が招待メールのリンクから設定します（リンク有効期限 6 時間）。</p>
<%= render "form", user: @user %>
```

- [ ] **Step 5: 成功を確認 → Commit**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb` → 全 PASS

```bash
git add app/controllers/admin/users_controller.rb app/views/admin/users spec/requests/admin_users_spec.rb
git commit -m "feat: 社員の新規登録 + 招待メール送付（失敗時は送らない）"
```

---

### Task 11: edit/update（permit 境界・email 変更時の再送促し）

**Files:**
- Modify: `app/controllers/admin/users_controller.rb`
- Create: `app/views/admin/users/edit.html.erb`
- Test: `spec/requests/admin_users_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
  describe "PATCH /admin/users/:id（0b-1 設計 §0 permit 境界・§2-6）" do
    let!(:member) { ActsAsTenant.with_tenant(org) { create(:user) } }

    before { sign_in admin }

    it "role / manager_id / exempt_from_overtime を変更できる（Admin 限定 permit）" do
      boss = ActsAsTenant.with_tenant(org) { create(:user, :manager_role) }
      patch admin_user_url(member, host: tenant_host(org)),
            params: { user: { role: "manager", manager_id: boss.id, exempt_from_overtime: "1" } }
      member.reload
      expect(member.role).to eq("manager")
      expect(member.manager_id).to eq(boss.id)
      expect(member.exempt_from_overtime).to be(true)
    end

    it "active と organization_id は permit されない（無視される）" do
      other_org = create(:organization)
      patch admin_user_url(member, host: tenant_host(org)),
            params: { user: { name: "改名", active: "false", organization_id: other_org.id } }
      member.reload
      expect(member.name).to eq("改名")
      expect(member.active).to be(true)
      expect(member.organization_id).to eq(org.id)
    end

    it "未受諾ユーザーのメール変更時は flash で再送を促す" do
      patch admin_user_url(member, host: tenant_host(org)),
            params: { user: { email: "corrected@example.com" } }
      expect(flash[:notice]).to include("再送")
    end

    it "ガード違反（最後の hr_admin 降格）は 422 + 状態不変 + メッセージ表示" do
      patch admin_user_url(admin, host: tenant_host(org)), params: { user: { role: "employee" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(admin.reload.role).to eq("hr_admin")
      expect(response.body).to include("組織最後の管理者は降格・無効化できません")
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb -e "permit 境界"`
Expected: FAIL

- [ ] **Step 3: コントローラに追加**:

```ruby
    def edit
      authorize [:admin, @user]
    end

    def update
      authorize [:admin, @user]
      if @user.update(user_params)
        notice = "更新しました"
        # 旧トークンは email 変更で Devise が自動失効する（clear_reset_password_token?）。
        # 自動送信はせず明示操作（再送ボタン）へ誘導する（0b-1 設計 §2-6）
        if @user.email_previously_changed? && @user.sign_in_count.zero?
          notice += "。メールアドレスが変わったため、一覧から招待を再送してください"
        end
        redirect_to admin_user_path(@user), notice: notice
      else
        render :edit, status: :unprocessable_entity
      end
    end
```

`app/views/admin/users/edit.html.erb`:

```erb
<h2 class="mb-4 text-lg font-bold"><%= @user.name %> の編集</h2>
<%= render "form", user: @user %>
```

flash 表示が無いとテスト不可のため `app/views/layouts/application.html.erb` の `<main>` 直前に追加:

```erb
    <% flash.each do |type, message| %>
      <div class="container mx-auto mt-4 px-5 rounded border p-3 text-sm <%= type == "alert" ? "border-red-400 bg-red-50 text-red-800" : "border-green-400 bg-green-50 text-green-800" %>">
        <%= message %>
      </div>
    <% end %>
```

- [ ] **Step 4: 成功を確認 → Commit**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb` → 全 PASS

```bash
git add app/controllers/admin/users_controller.rb app/views/admin/users app/views/layouts/application.html.erb spec/requests/admin_users_spec.rb
git commit -m "feat: 社員編集（Admin 限定 permit・email 変更時の再送促し・ガード違反 422）"
```

---

### Task 12: deactivate / activate

**Files:**
- Modify: `app/controllers/admin/users_controller.rb`
- Test: `spec/requests/admin_users_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
  describe "PATCH deactivate / activate（0b-1 設計 §3 ガードとの連動）" do
    before { sign_in admin }

    it "部下なし社員は無効化でき、再有効化もできる" do
      member = ActsAsTenant.with_tenant(org) { create(:user) }
      patch deactivate_admin_user_url(member, host: tenant_host(org))
      expect(member.reload.active).to be(false)

      patch activate_admin_user_url(member, host: tenant_host(org))
      expect(member.reload.active).to be(true)
    end

    it "最後の hr_admin の無効化はガードが拒否し、状態不変 + alert にメッセージ" do
      patch deactivate_admin_user_url(admin, host: tenant_host(org))
      expect(admin.reload.active).to be(true)
      expect(flash[:alert]).to include("組織最後の管理者は降格・無効化できません")
    end

    it "無効化された元・最後の hr_admin も、別のアクティブ hr_admin がいれば成立する（ガード①相互作用）" do
      second = ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) }
      patch deactivate_admin_user_url(admin, host: tenant_host(org))
      expect(admin.reload.active).to be(false) # second がいるので許可

      patch activate_admin_user_url(admin, host: tenant_host(org))
      expect(admin.reload.active).to be(true) # 再有効化にガードはない
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb -e deactivate`
Expected: FAIL

- [ ] **Step 3: コントローラに追加**:

```ruby
    def deactivate
      authorize [:admin, @user]
      if @user.update(active: false)
        redirect_to admin_user_path(@user), notice: "#{@user.name} を無効化しました"
      else
        redirect_to admin_user_path(@user), alert: @user.errors.full_messages.join("。")
      end
    end

    def activate
      authorize [:admin, @user]
      @user.update!(active: true) # 再有効化を妨げるガードはない（0b-1 設計 §3）
      redirect_to admin_user_path(@user), notice: "#{@user.name} を再有効化しました"
    end
```

- [ ] **Step 4: 成功を確認 → Commit**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb` → 全 PASS

```bash
git add app/controllers/admin/users_controller.rb spec/requests/admin_users_spec.rb
git commit -m "feat: 社員の無効化/再有効化（モデルガードと連動・状態不変 assert）"
```

---

### Task 13: resend_invitation（負例 4 種）

**Files:**
- Modify: `app/controllers/admin/users_controller.rb`
- Test: `spec/requests/admin_users_spec.rb`

- [ ] **Step 1: 失敗するテストを書く**

```ruby
  describe "PATCH resend_invitation（0b-1 設計 §2-4/2-5）" do
    include ActiveSupport::Testing::TimeHelpers

    let!(:invited) { ActsAsTenant.with_tenant(org) { create(:user) } } # sign_in_count 0

    before { sign_in admin }

    it "未受諾ユーザーへ再送できる" do
      expect {
        patch resend_invitation_admin_user_url(invited, host: tenant_host(org))
      }.to change { ActionMailer::Base.deliveries.count }.by(1)
      expect(invited.reload.reset_password_token).to be_present
    end

    it "再送で旧トークンは失効する（旧 raw トークンでのパスワード設定は不変）" do
      old_raw = ActsAsTenant.with_tenant(org) { invited.send_invitation_instructions }
      patch resend_invitation_admin_user_url(invited, host: tenant_host(org))

      put user_password_url(host: tenant_host(org)),
          params: { user: { reset_password_token: old_raw,
                            password: "newpassword1!", password_confirmation: "newpassword1!" } }
      expect(invited.reload.valid_password?("newpassword1!")).to be(false)
    end

    it "期限切れ（6 時間超）のトークンは消費できない" do
      raw = ActsAsTenant.with_tenant(org) { invited.send_invitation_instructions }
      travel 7.hours do
        put user_password_url(host: tenant_host(org)),
            params: { user: { reset_password_token: raw,
                              password: "newpassword1!", password_confirmation: "newpassword1!" } }
        expect(invited.reload.valid_password?("newpassword1!")).to be(false)
      end
    end

    it "ログイン済み（sign_in_count > 0）への直接 PATCH は 403 — トークン強制発行を塞ぐ" do
      received = ActsAsTenant.with_tenant(org) { create(:user, sign_in_count: 1) }
      expect {
        patch resend_invitation_admin_user_url(received, host: tenant_host(org))
      }.not_to change { ActionMailer::Base.deliveries.count }
      expect(response).to have_http_status(:forbidden)
    end

    it "inactive ユーザーへの直接 PATCH は 403・メール 0 通" do
      retired = ActsAsTenant.with_tenant(org) { create(:user, active: false) }
      expect {
        patch resend_invitation_admin_user_url(retired, host: tenant_host(org))
      }.not_to change { ActionMailer::Base.deliveries.count }
      expect(response).to have_http_status(:forbidden)
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb -e resend`
Expected: FAIL（アクション未実装）

- [ ] **Step 3: コントローラに追加**:

```ruby
    def resend_invitation
      authorize [:admin, @user] # resend_invitation? が 3 条件をサーバ側強制（policy 参照）
      @user.send_invitation_instructions
      redirect_to admin_users_path, notice: "#{@user.name} へ招待メールを再送しました"
    end
```

- [ ] **Step 4: 成功を確認 → Commit**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb` → 全 PASS

```bash
git add app/controllers/admin/users_controller.rb spec/requests/admin_users_spec.rb
git commit -m "feat: 招待再送（policy 3 条件のサーバ側強制・旧トークン失効・期限切れの負例）"
```

---

### Task 14: system spec — 招待 E2E 一周

**Files:**
- Create: `spec/system/admin_invitation_spec.rb`

- [ ] **Step 1: E2E テストを書く**

```ruby
require "rails_helper"

RSpec.describe "社員招待の E2E（0b-1 設計 §4 system）", type: :system do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) do
    ActsAsTenant.with_tenant(org) { create(:user, :hr_admin, password: "adminpass1!") }
  end

  it "招待 → メールリンク → パスワード設定 → 当該テナントでログイン成功" do
    switch_tenant(org)

    # hr_admin でログインし社員を招待
    visit new_user_session_path
    fill_in "Email", with: admin.email
    fill_in "Password", with: "adminpass1!"
    click_button "Log in"

    visit new_admin_user_path
    fill_in "氏名", with: "新人 一郎"
    fill_in "メールアドレス", with: "newbie@example.com"
    fill_in "社員番号", with: "A-100"
    click_button "登録して招待メールを送る"
    expect(page).to have_content("招待メールを送信しました")

    # 招待リンクは require_no_authentication のため先にログアウト（設計 §2-3 既知事項）
    visit root_path
    click_button "ログアウト"

    # メールから設定 URL を取り出して受諾（deliver_now ゆえ deliveries に直接届く）
    mail_body = ActionMailer::Base.deliveries.last.body.encoded
    invite_url = mail_body[%r{https?://acme\.example\.com[^"]*reset_password_token=[^"]+}]
    expect(invite_url).to be_present

    visit invite_url
    fill_in "新しいパスワード", with: "firstpassword1!"
    fill_in "新しいパスワード（確認）", with: "firstpassword1!"
    click_button "パスワードを設定する"

    # sign_in_after_reset_password 既定 true → そのままサインイン済み（正のアンカー assert）
    expect(page).to have_content("新人 一郎 としてログイン中")
    expect(page).to have_content(org.name)
  end
end
```

- [ ] **Step 2: 実行して PASS を確認**

Run: `bundle exec rspec spec/system/admin_invitation_spec.rb`
Expected: PASS（失敗したら deliveries の URL 形式・devise ビューのラベル文言を突合して修正）

- [ ] **Step 3: Commit**

```bash
git add spec/system/admin_invitation_spec.rb
git commit -m "test: 招待からログインまでの E2E 一周（system）"
```

---

### Task 15: 仕上げ — ROADMAP 更新・全体検証

**Files:**
- Modify: `docs/ROADMAP.md`

- [ ] **Step 1: ROADMAP 0b-1 行の文言修正**（チェック+PR 番号は PR 作成時に付ける）

`docs/ROADMAP.md` の 0b-1 行の「`role` / `manager_id` / `exempt_from_overtime` の変更 UI（mass-assignment 恒久除外の専用アクション）」を以下へ置換:

```markdown
- [ ] **0b-1 ユーザー管理**: 社員 CRUD（hr_admin 専用）・`role` / `manager_id` / `exempt_from_overtime` の変更 UI（Admin 名前空間限定の明示 permit — 設計 §0 で「専用アクション」方式を supersede）・招待メール（recoverable 転用・§16.7-3）
```

- [ ] **Step 2: 全 spec + RuboCop**

Run: `bundle exec rspec && bundle exec rubocop`
Expected: 全 PASS・offense なし（あれば `bundle exec rubocop -A` で自動修正して再実行）

- [ ] **Step 3: tenant-isolation-reviewer によるレビュー**（設計 §5。models に触れたため必須）

Agent tool で `tenant-isolation-reviewer` を起動し、`git diff main...HEAD` を対象にレビュー。Critical があれば修正してから次へ。

- [ ] **Step 4: Commit → preflight → PR**

```bash
git add docs/ROADMAP.md
git commit -m "docs: ROADMAP 0b-1 の方式文言を設計に同期（専用アクション → Admin 限定 permit）"
```

`/preflight` を実行して push 前検証 → ユーザーに PR 作成の確認。

---

## Self-Review 結果（計画作成時に実施済み）

- **Spec coverage:** 設計 §0〜§5 の全項目にタスクが対応（§0 devise 固定→T1 / §1 器→T9 / §2 招待→T6,7,10,13 / §3 ガード 4 種→T2-5 / §4 の全 example→T2-14 に分配 / §5→T15）
- **Placeholder:** なし（全ステップに実コード・実コマンド）
- **型整合:** `send_invitation_instructions`（T6 定義・T10/T13/T14 で使用）、`t_role`（T9 定義・T9/T10 で使用）、`tenant_host`/`switch_tenant`（既存 support）を確認済み
