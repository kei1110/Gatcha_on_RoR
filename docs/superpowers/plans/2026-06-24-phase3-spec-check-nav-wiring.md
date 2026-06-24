# Phase 2〜3 機能の動線整備（最小グローバルナビ）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Phase 0a〜3 で実装済みだが root=home からクリック到達できない機能画面（休暇申請・打刻変更・休日出勤・承認インボックス・月次サマリ/CSV・管理マスタ・残高 CRUD）へ、最小グローバルナビと欠落リンクを足して動線を通す。

**Architecture:** `Admin::NavComponent` 同型の `GlobalNavComponent`（role 出し分け）を layout に常設。加えて CCR index の「新規申請」リンク欠落（A2）・`admin/users#show` の残高セクション欠落（A3）・home の陳腐化文言（A4）を埋める。コードの振る舞いは不変＝**純粋に UI 動線の plumbing**（新ロジック・新 policy なし）。

**Tech Stack:** Rails 8.1 / ViewComponent / Hotwire / Pundit / RSpec（request + component spec）/ Tailwind。

## Global Constraints

- 出典: Phase 3 spec-check（ユーザーストーリー観点）で検出。ROADMAP 横断バックログ「Phase 2〜3 機能の動線整備」を本スライスで回収（PR で `[x]` 化）。
- commit identity = kei1110 `<eoh2145@gmail.com>`（local config 済）。commit message 末尾に `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。
- ナビ role 出し分けは **既存 idiom 準拠**: 申請系（休暇/打刻変更/休日出勤/月次サマリ）は全社員、**承認・代理打刻は `manager? || hr_admin?`**（`ProxyClockingPolicy#manager_or_admin?` 同型・`ApprovalAssignmentPolicy#index?` は `user.present?` ゆえ出し分けに使わない）、**管理は `hr_admin?`**（`Admin::BaseController#require_hr_admin` 同基準）。
- 新しい認可述語・テナント経路を**増やさない**（残高は既存 `@user.leave_balances` = acts_as_tenant スコープ・`@user` は `policy_scope` 由来ゆえ IDOR なし。`_work_pattern_assignments` と同型）。
- rubocop は `bundle exec rubocop --force-exclusion <files>`。app/ に触れるため最後に `bin/brakeman --no-pager`。
- 各タスク完了ごとに即コミット。`db/queue_schema.rb` が rspec 実行で再生成されたら `git checkout -- db/queue_schema.rb` で revert（成果に混ぜない）。

---

### Task 1: GlobalNavComponent（role 出し分け + active 状態）

**Files:**
- Create: `app/components/global_nav_component.rb`
- Create: `app/components/global_nav_component.html.erb`
- Test: `spec/components/global_nav_component_spec.rb`

**Interfaces:**
- Produces: `GlobalNavComponent.new(current_user:)` — `current_user` は `User`。`#links` は `[label, path, match_path]` の配列（role フィルタ済）。`#active?(path, match_path=nil)` は現在パス判定。layout（Task 2）が `render GlobalNavComponent.new(current_user: current_user)` で消費。

- [ ] **Step 1: 失敗するコンポーネント spec を書く**

```ruby
# spec/components/global_nav_component_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe GlobalNavComponent, type: :component do
  def render_at(path, user)
    with_request_url(path) { render_inline(described_class.new(current_user: user)) }
  end

  it "employee: 申請系リンクは出るが 承認/代理打刻/管理 は出ない" do
    render_at("/", User.new(role: :employee, name: "社員"))
    expect(page).to have_link("休暇申請")
    expect(page).to have_link("月次サマリ")
    expect(page).not_to have_link("承認")
    expect(page).not_to have_link("代理打刻")
    expect(page).not_to have_link("管理")
  end

  it "manager: 承認・代理打刻は出るが 管理 は出ない" do
    render_at("/", User.new(role: :manager, name: "上長"))
    expect(page).to have_link("承認")
    expect(page).to have_link("代理打刻")
    expect(page).not_to have_link("管理")
  end

  it "hr_admin: 管理も出る（承認・代理打刻も）" do
    render_at("/", User.new(role: :hr_admin, name: "管理者"))
    expect(page).to have_link("管理")
    expect(page).to have_link("承認")
    expect(page).to have_link("代理打刻")
  end

  it "現在パスのリンクが active（/leave_requests で 休暇申請 が font-bold・ホームは非 active）" do
    render_at("/leave_requests", User.new(role: :employee, name: "社員"))
    expect(page.find("a", text: "休暇申請")[:class]).to include("font-bold")
    expect(page.find("a", text: "ホーム")[:class]).not_to include("font-bold")
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/components/global_nav_component_spec.rb`
Expected: FAIL（`uninitialized constant GlobalNavComponent`）

- [ ] **Step 3: コンポーネント本体を実装**

```ruby
# app/components/global_nav_component.rb
# frozen_string_literal: true

# 全画面共通のグローバルナビ（Admin::NavComponent 同型・layout に常設）。
# Phase 0a〜3 で実装した機能画面への唯一のクリック動線（Phase 3 spec-check で動線断絶を検出）。
# role 出し分け: 申請系は全社員 / 承認・代理打刻は manager|hr_admin / 管理は hr_admin。
class GlobalNavComponent < ViewComponent::Base
  def initialize(current_user:)
    @current_user = current_user
  end

  attr_reader :current_user

  # [label, path, match_path] の配列（role でフィルタ済）。match_path は active 前方一致の基準
  # （/admin 配下を一括 active にする「管理」のみ指定・他は nil＝path 自体で判定）。
  def links
    items = [
      [ "ホーム", helpers.root_path, nil ],
      [ "休暇申請", helpers.leave_requests_path, nil ],
      [ "打刻変更", helpers.clock_change_requests_path, nil ],
      [ "休日出勤", helpers.holiday_work_requests_path, nil ],
      [ "月次サマリ", helpers.monthly_attendance_summaries_path, nil ]
    ]
    if approver?
      items << [ "承認", helpers.approval_assignments_path, nil ]
      items << [ "代理打刻", helpers.proxy_clockings_path, nil ]
    end
    items << [ "管理", helpers.admin_users_path, "/admin" ] if current_user.hr_admin?
    items
  end

  # root("/") は完全一致・それ以外は前方一致（Admin::NavComponent#active? と同方針）。
  def active?(path, match_path = nil)
    target = match_path || path
    target == "/" ? helpers.request.path == "/" : helpers.request.path.start_with?(target)
  end

  private

  # 承認者になり得るのは manager_id 階層 = manager|hr_admin（ProxyClockingPolicy#manager_or_admin? 同型）
  def approver? = current_user.manager? || current_user.hr_admin?
end
```

```erb
<%# app/components/global_nav_component.html.erb %>
<nav class="border-b border-gray-300 bg-white">
  <div class="container mx-auto flex flex-wrap items-center justify-between gap-2 px-5 py-3">
    <ul class="flex flex-wrap gap-1 text-sm">
      <% links.each do |label, path, match_path| %>
        <li>
          <%= link_to label, path,
                class: "inline-block rounded px-3 py-1.5 #{active?(path, match_path) ? 'bg-gray-800 font-bold text-white' : 'text-gray-600 hover:bg-gray-100'}" %>
        </li>
      <% end %>
    </ul>
    <div class="flex items-center gap-3 text-sm text-gray-600">
      <span><%= current_user.name %><% if ActsAsTenant.current_tenant %>（<%= ActsAsTenant.current_tenant.name %>）<% end %></span>
      <%= button_to "ログアウト", helpers.destroy_user_session_path, method: :delete,
            class: "rounded bg-gray-800 px-3 py-1.5 text-white" %>
    </div>
  </div>
</nav>
```

- [ ] **Step 4: spec が通ることを確認**

Run: `bundle exec rspec spec/components/global_nav_component_spec.rb`
Expected: PASS（4 examples）

- [ ] **Step 5: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion app/components/global_nav_component.rb spec/components/global_nav_component_spec.rb
git add app/components/global_nav_component.rb app/components/global_nav_component.html.erb spec/components/global_nav_component_spec.rb
git commit -m "feat: GlobalNavComponent（role 出し分けの最小グローバルナビ）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: layout にナビ常設 + home ヘッダの重複解消（A1）

**Files:**
- Modify: `app/views/layouts/application.html.erb`（`<body>` 冒頭・`<main>` の margin）
- Modify: `app/views/home/show.html.erb`（重複ヘッダ行を撤去）
- Test: `spec/requests/global_nav_spec.rb`（新規）

**Interfaces:**
- Consumes: Task 1 の `GlobalNavComponent.new(current_user:)`。

- [ ] **Step 1: 失敗する request spec を書く**

```ruby
# spec/requests/global_nav_spec.rb
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Global navigation", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }

  it "サインイン済みホームに機能ナビが出る（休暇申請・月次サマリ・各 path）" do
    user = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in user
    get root_url(host: tenant_host(org))
    expect(response.body).to include("休暇申請").and include("月次サマリ")
    expect(response.body).to include(leave_requests_path)
    expect(response.body).to include(monthly_attendance_summaries_path)
  end

  it "hr_admin は 管理 リンク（/admin/users）が出る" do
    admin = ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) }
    sign_in admin
    get root_url(host: tenant_host(org))
    expect(response.body).to include(admin_users_path)
  end

  it "employee には 管理 リンクが出ない" do
    user = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in user
    get root_url(host: tenant_host(org))
    expect(response.body).not_to include(">管理</a>")
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/requests/global_nav_spec.rb`
Expected: FAIL（ナビ未設置ゆえ `休暇申請` 等が body に無い）

- [ ] **Step 3: layout にナビを設置**

`app/views/layouts/application.html.erb` の `<body>` 直後（`flash.each` の前）に挿入し、`<main>` の `mt-28` を `mt-8` に変更（固定ヘッダは無くナビが先頭に来るため）:

```erb
  <body>
    <% if user_signed_in? %>
      <%= render GlobalNavComponent.new(current_user: current_user) %>
    <% end %>
    <% flash.each do |type, message| %>
```

```erb
    <main class="container mx-auto mt-8 px-5 flex">
```

- [ ] **Step 4: home の重複ヘッダ行を撤去**

`app/views/home/show.html.erb` の冒頭ヘッダ（代理打刻 / user / logout の行）はナビへ移ったため削除し、見出しだけ残す。差し替え後の全文:

```erb
<main class="mx-auto w-full max-w-3xl p-4">
  <h1 class="text-2xl font-bold">Gatcha 勤怠</h1>

  <% if @proxy_clock_event %>
    <%= render "home/proxy_clock_banner", event: @proxy_clock_event, record: @today_record %>
  <% end %>

  <%= render "home/clocking", state: @state %>
  <%= render Home::CalendarComponent.new(month: @month, today: @state.today,
                                         records: @records, day_types: @day_types) %>
</main>
```

- [ ] **Step 5: 新 spec が通ることを確認**

Run: `bundle exec rspec spec/requests/global_nav_spec.rb`
Expected: PASS（3 examples）

- [ ] **Step 6: フルスイートで既存 spec の退行が無いことを確認（ナビ全画面常設の副作用検出）**

Run: `bundle exec rspec`
Expected: 全 green。ナビが全ページに `休暇申請`/`管理` 等の文字列を載せるため、既存 request spec の `not_to include(...)` 系が誤発火していないか確認する。退行があれば該当アサーションをナビ非依存な文字列へ調整（例: ナビに無い具体メッセージで判定）。
`db/queue_schema.rb` が変わっていたら `git checkout -- db/queue_schema.rb`。

- [ ] **Step 7: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion spec/requests/global_nav_spec.rb
git add app/views/layouts/application.html.erb app/views/home/show.html.erb spec/requests/global_nav_spec.rb
git commit -m "feat: グローバルナビを layout に常設し home ヘッダ重複を解消（A1）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: CCR 新規申請リンク（A2）+ home 陳腐化文言（A4）

**Files:**
- Modify: `app/views/clock_change_requests/index.html.erb`（h1 隣に「新規申請」）
- Modify: `app/views/home/_clocking.html.erb:22`（「（Phase 2 で提供予定）」を実リンクへ）
- Test: `spec/requests/clock_change_requests_spec.rb`（既存に append）

**Interfaces:**
- Consumes: 既存 route `new_clock_change_request_path`。

- [ ] **Step 1: 失敗する request spec を append**

`spec/requests/clock_change_requests_spec.rb` の `RSpec.describe` ブロック内に追加:

```ruby
  describe "GET index" do
    it "新規申請リンクが出る（new への動線）" do
      get clock_change_requests_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(new_clock_change_request_path)
      expect(response.body).to include("新規申請")
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/requests/clock_change_requests_spec.rb -e "新規申請リンク"`
Expected: FAIL（index に new リンクが無い）

- [ ] **Step 3: CCR index に新規申請リンクを足す（LR/HWR と同作法）**

`app/views/clock_change_requests/index.html.erb` の h1 行を次に差し替え:

```erb
<%# app/views/clock_change_requests/index.html.erb %>
<div class="flex items-center justify-between mb-4">
  <h1 class="text-xl font-bold">打刻変更申請</h1>
  <%= link_to "新規申請", new_clock_change_request_path, class: "bg-blue-600 text-white px-3 py-1 rounded text-sm" %>
</div>
```

- [ ] **Step 4: home の陳腐化文言を実リンクへ**

`app/views/home/_clocking.html.erb` の該当行（`時刻の修正は打刻変更申請で行えます（Phase 2 で提供予定）`）を差し替え:

```erb
    <p class="mt-2 text-sm text-gray-500">時刻の修正は<%= link_to "打刻変更申請", new_clock_change_request_path, class: "text-blue-600 underline" %>で行えます</p>
```

- [ ] **Step 5: spec が通ることを確認**

Run: `bundle exec rspec spec/requests/clock_change_requests_spec.rb`
Expected: PASS（既存 + 新規 1 example）

- [ ] **Step 6: rubocop + commit**

```bash
bundle exec rubocop --force-exclusion spec/requests/clock_change_requests_spec.rb
git add app/views/clock_change_requests/index.html.erb app/views/home/_clocking.html.erb spec/requests/clock_change_requests_spec.rb
git commit -m "feat: CCR index に新規申請リンク + home 陳腐化文言を実リンク化（A2/A4）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: admin/users#show に休暇残高セクション（A3）

**Files:**
- Modify: `app/controllers/admin/users_controller.rb`（`show` で `@leave_balances` ロード）
- Create: `app/views/admin/users/_leave_balances.html.erb`
- Modify: `app/views/admin/users/show.html.erb`（partial を render）
- Test: `spec/requests/admin_users_spec.rb`（既存に append）

**Interfaces:**
- Consumes: 既存 route `new_admin_user_leave_balance_path(user)` / `edit_admin_user_leave_balance_path(user, balance)`、`LeaveBalance#remaining`。

- [ ] **Step 1: 失敗する request spec を append**

`spec/requests/admin_users_spec.rb` に `describe` を追加（`org` / `admin` は既存 let を再利用）:

```ruby
  describe "GET /admin/users/:id 残高セクション（A3）" do
    let!(:lt) { ActsAsTenant.with_tenant(org) { create(:leave_type, name: "有給") } }
    let!(:target) { ActsAsTenant.with_tenant(org) { create(:user, name: "対象 太郎") } }

    it "残高一覧と新規付与リンクが出る" do
      ActsAsTenant.with_tenant(org) do
        create(:leave_balance, user: target, leave_type: lt, fiscal_year: "2026",
               granted_days: 20, carry_over_days: 0, used_days: 5, granted_on: Date.new(2026, 4, 1))
      end
      sign_in admin
      get admin_user_url(target, host: tenant_host(org))
      expect(response.body).to include("休暇残高")
      expect(response.body).to include("有給")
      expect(response.body).to include(new_admin_user_leave_balance_path(target))
      expect(response.body).to include(edit_admin_user_leave_balance_path(target, target.leave_balances.first))
    end

    it "残高ゼロ件でも新規付与リンクと空状態が出る" do
      sign_in admin
      get admin_user_url(target, host: tenant_host(org))
      expect(response.body).to include("休暇残高")
      expect(response.body).to include(new_admin_user_leave_balance_path(target))
      expect(response.body).to include("残高はまだ登録されていません")
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb -e "残高セクション"`
Expected: FAIL（`休暇残高` セクション未描画）

- [ ] **Step 3: controller#show で残高をロード**

`app/controllers/admin/users_controller.rb` の `show` 末尾に追加（`@no_effective_assignment` の次行）:

```ruby
      @leave_balances = @user.leave_balances.includes(:leave_type)
                             .order(fiscal_year: :desc, leave_type_id: :asc)
```

- [ ] **Step 4: 残高 partial を作成（_work_pattern_assignments 同型）**

```erb
<%# app/views/admin/users/_leave_balances.html.erb %>
<section class="mt-8 max-w-2xl">
  <div class="flex items-center justify-between">
    <h3 class="text-base font-bold">休暇残高</h3>
    <%= link_to "+ 新規付与", new_admin_user_leave_balance_path(@user), class: "rounded border px-3 py-1 text-sm" %>
  </div>

  <% if @leave_balances.any? %>
    <table class="mt-3 w-full text-left text-sm">
      <thead>
        <tr class="border-b">
          <th class="py-1">年度</th><th>休暇種別</th><th>付与</th><th>繰越</th><th>使用</th><th>残</th><th></th>
        </tr>
      </thead>
      <tbody>
        <% @leave_balances.each do |b| %>
          <tr class="border-b">
            <td class="py-1"><%= b.fiscal_year %></td>
            <td><%= b.leave_type.name %></td>
            <td><%= b.granted_days.to_s("F") %></td>
            <td><%= b.carry_over_days.to_s("F") %></td>
            <td><%= b.used_days.to_s("F") %></td>
            <td><%= b.remaining.to_s("F") %></td>
            <td class="py-1"><%= link_to "編集", edit_admin_user_leave_balance_path(@user, b), class: "underline" %></td>
          </tr>
        <% end %>
      </tbody>
    </table>
  <% else %>
    <p class="mt-2 text-sm text-gray-500">残高はまだ登録されていません。</p>
  <% end %>
</section>
```

- [ ] **Step 5: show から partial を render**

`app/views/admin/users/show.html.erb` 末尾（`<%= render "work_pattern_assignments" %>` の次行）に追加:

```erb
<%= render "leave_balances" %>
```

- [ ] **Step 6: spec が通ることを確認**

Run: `bundle exec rspec spec/requests/admin_users_spec.rb`
Expected: PASS（既存 + 新規 2 examples）。`db/queue_schema.rb` が変わっていたら revert。

- [ ] **Step 7: rubocop + brakeman + commit**

```bash
bundle exec rubocop --force-exclusion app/controllers/admin/users_controller.rb spec/requests/admin_users_spec.rb
bin/brakeman --no-pager
git add app/controllers/admin/users_controller.rb app/views/admin/users/_leave_balances.html.erb app/views/admin/users/show.html.erb spec/requests/admin_users_spec.rb
git commit -m "feat: admin/users#show に休暇残高セクション（残高 CRUD 動線・A3）

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## 完了時（PR 前）

- [ ] `/preflight`（or 等価: `bundle exec rspec` 全 green・`bundle exec rubocop`・`bin/brakeman --no-pager`）
- [ ] `tenant-isolation-reviewer` を起動（controller の `@user.leave_balances` ロード + 全画面ナビ常設に対しテナント漏洩・IDOR の最終確認）
- [ ] ROADMAP 横断バックログ「Phase 2〜3 機能の動線整備（最小グローバルナビ）」を `[x]` + PR 番号へ更新
- [ ] PR 作成（base main・CI green 確認）

## Self-Review チェック結果

- **動線断絶カバレッジ**: A1（ナビ常設=Task 2）/ A2（CCR 新規=Task 3）/ A3（残高=Task 4）/ A4（陳腐化文言=Task 3）すべてにタスク対応あり。
- **Placeholder**: なし（全 step に実コード）。
- **型整合**: `GlobalNavComponent.new(current_user:)` は Task 1 定義 ↔ Task 2 consume 一致。`#links`/`#active?` 名称一致。`new_admin_user_leave_balance_path` / `edit_admin_user_leave_balance_path` / `LeaveBalance#remaining` は既存実体（routes.rb / leave_balance.rb で確認済）。
- **既知リスク**: Task 2 のナビ全画面常設は既存 request spec の `not_to include` を誤発火させ得る → Step 6 でフルスイート実行を必須化済。
