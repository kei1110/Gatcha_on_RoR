# Phase 4-1b 通知配信コア Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 通知生成の単一入口 `Notifier` と email 配信機構（抑制 PORO・配信ジョブ・ディスパッチャ→子ジョブ・Mailer）を作る（caller=producer 接続は 4-1c）。

**Architecture:** `Notifier`(Service) が Notification を作成し（in_app の実体）、優先度 × 二重 opt-in で email 要否を判定、抑制は純 PORO `Notifications::SuppressionWindow`（値注入）で `scheduled_at` を決め `NotificationDelivery` を作成。自身の DB 書き込みは明示 tx で囲み、**tx 確定後**に in_app broadcast（Turbo Streams・署名 stream）と `NotificationEmailJob.set(wait_until:).perform_later` を発火（rollback 時の幻通知/未コミット sweep 防止）。毎時 `NotificationDispatchJob`(ディスパッチャ)→`NotificationDispatchTenantJob`(子) が取りこぼし回収＋ dispatcher 雛形の規範実装。

**Tech Stack:** Rails 8.1 / acts_as_tenant / SolidQueue（recurring）/ Turbo Streams（turbo-rails・SolidCable）/ ActionMailer / RSpec + FactoryBot

**設計**: `docs/superpowers/specs/2026-06-26-phase4-1-notification-infrastructure-design.md` の §4（配信ロジック）+ §9（多視点レビュー反映・**§2〜§6 を上書きする拘束力**）。本計画は §9 を必須要件として転写する。

## Global Constraints

- **テナント安全（§3.6）**: 全 model に `acts_as_tenant(:organization)`。ジョブの perform は `ActsAsTenant.with_tenant(org)` でラップ（`require_tenant = true` ゆえ未ラップは例外）。ディスパッチャだけは `current_tenant = nil` 前提で `Organization` をスコープ外列挙し**子に org_id だけ渡す**。
- **PORO 契約（§2.2-1・§9②）**: `SuppressionWindow` は AR 読み取りを持たない。Notifier が解決した値だけを注入し、DB なしで境界算術を網羅テストする。
- **producer 接ぎ目 atomicity（§9③・最重要）**: `Notifier` 自身の DB 書き込みは明示 tx で囲み、**in_app broadcast と job enqueue は tx 確定後**に発火。`apply_*_effects!`/`with_lock` 内には置かない（これは 4-1c の producer 側の責務だが、Notifier 自身も tx 後発火で同じ不変条件を満たす）。
- **タイムゾーン（§9①）**: quiet hours 判定は**組織ローカル時刻**。`Time.current`(UTC) を `ActsAsTenant.current_tenant.time_zone` で `in_time_zone` してから PORO に渡す（`organization.rb#today`/`#time_zone` と同経路）。
- **二重 opt-in（§4.1）**: 組織 `OrganizationSetting#email_notification_enabled` ∧ 個人 `User#email_enabled` の AND。
- **Turbo Streams 署名不変条件（§9⑨）**: `Turbo::StreamsChannel.broadcast_*_to(target_user, ...)`（GlobalID 署名 stream）のみ。未署名の独自 ActionCable channel を新設しない。broadcast 先は target_user に限定。**repo 初の Turbo Streams 利用ゆえ基盤ごと DoD 固定**。
- **status は SolidQueue 結果の反映（§2・§9⑧）**: `NotificationDelivery#status` は独立状態機械でない。error 確定は ActiveJob 組込 `executions` を正とし `retry_count` 列はその監査ミラー。status 遷移の書き込みは単一メソッド（`with_lock` 内）に集約。
- **Mailer host（§9⑦）**: job 文脈に request が無いため、リンク host は `notification.organization.subdomain` から構築（`request.subdomain` 不可）。`default from:` は `ApplicationMailer` の placeholder を継承せず `ENV.fetch("MAILER_SENDER", ...)`。
- **検証コマンド**: 各タスクは `bundle exec rspec <該当spec>` green。app/ に触れる全タスク完了後に `bundle exec rubocop --force-exclusion`（明示渡し時 `--force-exclusion` 必須）と `bin/brakeman --no-pager`。
- **コミット trailer**: 各コミットの本文末尾に `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`。

---

## File Structure

| ファイル | 責務 |
|---|---|
| `app/services/notifications/suppression_window.rb`（新） | 純 PORO。値注入で `suppressed?` / `next_allowed_at`（quiet hours 境界・日跨ぎ・休日） |
| `app/mailers/notification_mailer.rb`（新） | `#notify(notification)` 汎用通知メール。subdomain 入りリンク |
| `app/views/notification_mailer/notify.html.erb` / `notify.text.erb`（新） | メール本文（HTML/text） |
| `app/jobs/notification_email_job.rb`（新） | `perform(organization_id:, delivery_id:)`。with_tenant 再確立 + with_lock 冪等 + retry/error |
| `app/services/notifier.rb`（新） | 生成入口。Notification 作成 → email 要否 → 抑制 → Delivery → tx 後に broadcast + enqueue |
| `app/views/notifications/_notification.html.erb`（新・最小） | broadcast 描画用（4-1c で NotificationBellComponent に合わせ再整形） |
| `app/jobs/notification_dispatch_job.rb`（新） | ディスパッチャ。`Organization.active` をスコープ外列挙 → 子 enqueue |
| `app/jobs/notification_dispatch_tenant_job.rb`（新） | 子。with_tenant で当該テナントの due な email pending Delivery を email job へ |
| `app/models/organization.rb`（修正） | `scope :active` 追加（§9⑩） |
| `config/recurring.yml`（修正） | `notification_dispatch`（every hour）追加（§10） |

**依存順（タスク順の根拠）**: SuppressionWindow（依存なし）→ Mailer（依存なし）→ EmailJob（Mailer 依存）→ Notifier（SuppressionWindow + EmailJob 定数解決依存）→ Dispatch 群（EmailJob 依存）。Notifier の `have_enqueued_job(NotificationEmailJob)` テストは定数 `NotificationEmailJob` の実在を要するため EmailJob を先行させる。

**スコープ外（4-1c へ）**: ベル UI（NotificationBellComponent・`turbo_stream_from`）・通知一覧/既読 controller・通知設定 controller・承認/却下 producer 接続・`notifications` route・§1.4 行・統合テスト（承認→ベル）。4-1a モデルのテスト負債（必須 belongs_to の discriminating 化・subject_user の DB 層 FK 負例・perf index `subject_user_id`/`deliveries[org,notification_id]`）はクエリ形状が定まる 4-1c で対称化する（ledger 記載どおり）。

**モデル実行ポリシー**: implementer は Task 1/2（転写型・純 PORO/Mailer）=haiku、Task 3/4/5（tx 境界・with_lock・broadcast・テナント反復の判断含む）=sonnet。逸脱が出たら即 sonnet 昇格。task-reviewer=sonnet、最終 whole-branch=opus。

---

### Task 1: `Notifications::SuppressionWindow`（純 PORO）

email 抑制判定の純 PORO。AR 読み取りを持たず、解決済み値だけを注入する（§9②）。quiet hours は **start 包含・end 排他**、日跨ぎ（start=19/end=8）と非日跨ぎ（start=8/end=19）と start==end 縮退（空窓＝非抑制）を扱う。

**Files:**
- Create: `app/services/notifications/suppression_window.rb`
- Test: `spec/services/notifications/suppression_window_spec.rb`

**Interfaces:**
- Consumes: なし（純 PORO）
- Produces: `Notifications::SuppressionWindow.new(now_local:, quiet_enabled:, quiet_start:, quiet_end:, holiday_block:, holiday:)` →
  - `#suppressed?` → Boolean
  - `#next_allowed_at` → `ActiveSupport::TimeWithZone`（抑制終了時刻・組織ローカル。非抑制なら `now_local`）
  - 引数: `now_local`=組織ローカル時刻(TimeWithZone) / `quiet_enabled`,`holiday_block`,`holiday`=Boolean / `quiet_start`,`quiet_end`=Integer(0..23 時)

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/notifications/suppression_window_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifications::SuppressionWindow do
  # now_local は組織ローカル時刻（注入）。JST で固定（PORO は zone を値から読む）。
  def jst(hour, min = 0, day = 26)
    Time.find_zone!("Asia/Tokyo").local(2026, 6, day, hour, min, 0)
  end

  def window(now_local:, quiet_enabled: true, quiet_start: 19, quiet_end: 8,
             holiday_block: false, holiday: false)
    described_class.new(now_local:, quiet_enabled:, quiet_start:, quiet_end:,
                        holiday_block:, holiday:)
  end

  describe "#suppressed? — 日跨ぎ窓（start=19, end=8・既定）" do
    it "18:59 は非抑制（start 排他前）" do
      expect(window(now_local: jst(18, 59))).not_to be_suppressed
    end

    it "19:00 は抑制（start 包含）" do
      expect(window(now_local: jst(19, 0))).to be_suppressed
    end

    it "07:59 は抑制（end 排他前）" do
      expect(window(now_local: jst(7, 59))).to be_suppressed
    end

    it "08:00 は非抑制（end 排他）" do
      expect(window(now_local: jst(8, 0))).not_to be_suppressed
    end
  end

  describe "#suppressed? — 非日跨ぎ窓（start=8, end=19）" do
    it "07:59 は非抑制" do
      expect(window(now_local: jst(7, 59), quiet_start: 8, quiet_end: 19)).not_to be_suppressed
    end

    it "08:00 は抑制" do
      expect(window(now_local: jst(8, 0), quiet_start: 8, quiet_end: 19)).to be_suppressed
    end

    it "18:59 は抑制" do
      expect(window(now_local: jst(18, 59), quiet_start: 8, quiet_end: 19)).to be_suppressed
    end

    it "19:00 は非抑制" do
      expect(window(now_local: jst(19, 0), quiet_start: 8, quiet_end: 19)).not_to be_suppressed
    end
  end

  describe "#suppressed? — start==end 縮退（空窓）" do
    it "どの時刻でも非抑制" do
      expect(window(now_local: jst(19, 0), quiet_start: 19, quiet_end: 19)).not_to be_suppressed
      expect(window(now_local: jst(3, 0), quiet_start: 19, quiet_end: 19)).not_to be_suppressed
    end
  end

  describe "#suppressed? — quiet 無効" do
    it "quiet_enabled=false なら quiet 帯でも非抑制" do
      expect(window(now_local: jst(20, 0), quiet_enabled: false)).not_to be_suppressed
    end
  end

  describe "#suppressed? — 休日ブロック" do
    it "holiday_block ∧ holiday なら抑制（quiet 帯外でも）" do
      expect(window(now_local: jst(12, 0), holiday_block: true, holiday: true)).to be_suppressed
    end

    it "holiday_block=false なら休日でも非抑制" do
      expect(window(now_local: jst(12, 0), holiday_block: false, holiday: true)).not_to be_suppressed
    end

    it "holiday=false なら holiday_block でも非抑制" do
      expect(window(now_local: jst(12, 0), holiday_block: true, holiday: false)).not_to be_suppressed
    end
  end

  describe "#next_allowed_at" do
    it "非抑制なら now_local をそのまま返す" do
      now = jst(12, 0)
      expect(window(now_local: now).next_allowed_at).to eq(now)
    end

    it "夜間(20:00)抑制 → 翌朝 08:00 JST" do
      result = window(now_local: jst(20, 0)).next_allowed_at
      expect(result).to eq(jst(8, 0, 27))
    end

    it "早朝(03:00)抑制 → 当日 08:00 JST" do
      result = window(now_local: jst(3, 0)).next_allowed_at
      expect(result).to eq(jst(8, 0, 26))
    end

    it "休日ブロック抑制 → 翌日 0:00 JST" do
      result = window(now_local: jst(12, 0), quiet_enabled: false,
                      holiday_block: true, holiday: true).next_allowed_at
      expect(result).to eq(jst(0, 0, 27))
    end

    it "quiet と休日が両方抑制中なら遅い方まで待つ" do
      # 20:00 抑制(→翌08:00) かつ 休日(→翌00:00) → max = 翌08:00
      result = window(now_local: jst(20, 0), holiday_block: true, holiday: true).next_allowed_at
      expect(result).to eq(jst(8, 0, 27))
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/notifications/suppression_window_spec.rb`
Expected: FAIL（`uninitialized constant Notifications::SuppressionWindow`）

- [ ] **Step 3: 最小実装**

`app/services/notifications/suppression_window.rb`:

```ruby
# frozen_string_literal: true

module Notifications
  # email 抑制判定の純 PORO（SPEC §4.15・設計 §4.2 / §9①②）。
  # AR 読み取り（preference 解決・休日判定）は Notifier が行い、解決済み値だけを注入する。
  # これにより DB なしで境界算術を網羅テストできる（§2.2-1 PORO 契約）。
  # quiet hours: start 包含・end 排他。start>end は日跨ぎ、start==end は空窓（非抑制）。
  class SuppressionWindow
    def initialize(now_local:, quiet_enabled:, quiet_start:, quiet_end:, holiday_block:, holiday:)
      @now_local = now_local
      @quiet_enabled = quiet_enabled
      @quiet_start = quiet_start
      @quiet_end = quiet_end
      @holiday_block = holiday_block
      @holiday = holiday
    end

    def suppressed?
      in_quiet_hours? || holiday_blocked?
    end

    # 抑制終了時刻（組織ローカル）。両方抑制中なら遅い方。非抑制なら now_local。
    def next_allowed_at
      return @now_local unless suppressed?

      candidates = []
      candidates << quiet_hours_end_at if in_quiet_hours?
      candidates << next_day_start if holiday_blocked?
      candidates.max
    end

    private

    def in_quiet_hours?
      return false unless @quiet_enabled
      return false if @quiet_start == @quiet_end # 空窓

      hour = @now_local.hour
      if @quiet_start < @quiet_end
        hour >= @quiet_start && hour < @quiet_end       # 非日跨ぎ
      else
        hour >= @quiet_start || hour < @quiet_end       # 日跨ぎ
      end
    end

    def holiday_blocked?
      @holiday_block && @holiday
    end

    # quiet_end 時の次の到来（now より後の最初の quiet_end:00）
    def quiet_hours_end_at
      candidate = @now_local.change(hour: @quiet_end, min: 0, sec: 0)
      candidate <= @now_local ? candidate + 1.day : candidate
    end

    def next_day_start
      (@now_local + 1.day).beginning_of_day
    end
  end
end
```

- [ ] **Step 4: テスト green を確認**

Run: `bundle exec rspec spec/services/notifications/suppression_window_spec.rb`
Expected: PASS（全 example green）

- [ ] **Step 5: コミット**

```bash
git add app/services/notifications/suppression_window.rb spec/services/notifications/suppression_window_spec.rb
git commit -m "feat: Notifications::SuppressionWindow（email 抑制の純 PORO・quiet hours 境界/日跨ぎ/休日）"
```

---

### Task 2: `NotificationMailer#notify`

汎用通知メール。job 文脈ゆえ request が無いため、リンク host は `notification.organization.subdomain` から構築する（§9⑦）。`default from:` は ENV から。4-1b では route 未整備のため `root_url(host:)` を使う（4-1c で `notifications_url` に差し替え）。

**Files:**
- Create: `app/mailers/notification_mailer.rb`
- Create: `app/views/notification_mailer/notify.html.erb`
- Create: `app/views/notification_mailer/notify.text.erb`
- Test: `spec/mailers/notification_mailer_spec.rb`

**Interfaces:**
- Consumes: `Notification`（`#title`/`#body`/`#target_user.email`/`#organization.subdomain`）
- Produces: `NotificationMailer.notify(notification)` → `ActionMailer::MessageDelivery`（`to`=target_user.email / `subject`=notification.title / body にサブドメイン入りリンク）

- [ ] **Step 1: 失敗するテストを書く**

`spec/mailers/notification_mailer_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationMailer, type: :mailer do
  describe "#notify" do
    let(:org) { create(:organization, subdomain: "acme") }
    let(:user) { ActsAsTenant.with_tenant(org) { create(:user, email: "u@example.com") } }
    let(:notification) do
      ActsAsTenant.with_tenant(org) do
        create(:notification, target_user: user, title: "申請が承認されました",
                              body: "あなたの休暇申請が承認されました。")
      end
    end

    subject(:mail) { described_class.notify(notification) }

    it "宛先は target_user のメール" do
      expect(mail.to).to eq(["u@example.com"])
    end

    it "件名は notification.title" do
      expect(mail.subject).to eq("申請が承認されました")
    end

    it "本文に notification.body を含む" do
      expect(mail.body.encoded).to include("あなたの休暇申請が承認されました。")
    end

    it "リンクは組織サブドメイン入り（§9⑦・job 文脈で request 無し）" do
      expect(mail.body.encoded).to include("acme.")
    end

    it "別テナント文脈でも org のサブドメインで組む（current_tenant 由来でない・鏡像）" do
      other = create(:organization, subdomain: "other")
      ActsAsTenant.with_tenant(other) do
        expect(mail.body.encoded).to include("acme.")
        expect(mail.body.encoded).not_to include("other.")
      end
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/mailers/notification_mailer_spec.rb`
Expected: FAIL（`uninitialized constant NotificationMailer`）

- [ ] **Step 3: 最小実装**

`app/mailers/notification_mailer.rb`:

```ruby
# frozen_string_literal: true

# 汎用通知メール（設計 §4.3 / §9⑦）。NotificationEmailJob から deliver_now される。
# job 文脈ゆえ request が無い → リンク host は notification.organization.subdomain から構築。
class NotificationMailer < ApplicationMailer
  default from: ENV.fetch("MAILER_SENDER", "notifications@example.com")

  def notify(notification)
    @notification = notification
    org = notification.organization
    host = "#{org.subdomain}.#{ENV.fetch('APP_HOST', 'example.com')}"
    # 4-1b では notifications route 未整備ゆえ root。4-1c で notifications_url(host:) に差し替え。
    @url = root_url(host: host)
    mail(to: notification.target_user.email, subject: notification.title)
  end
end
```

`app/views/notification_mailer/notify.html.erb`:

```erb
<p><%= @notification.body %></p>
<p><%= link_to "アプリで確認する", @url %></p>
```

`app/views/notification_mailer/notify.text.erb`:

```erb
<%= @notification.body %>

アプリで確認する: <%= @url %>
```

- [ ] **Step 4: テスト green を確認**

Run: `bundle exec rspec spec/mailers/notification_mailer_spec.rb`
Expected: PASS

- [ ] **Step 5: コミット**

```bash
git add app/mailers/notification_mailer.rb app/views/notification_mailer/ spec/mailers/notification_mailer_spec.rb
git commit -m "feat: NotificationMailer#notify（subdomain 入りリンク・job 文脈で request 無し・§9⑦）"
```

---

### Task 3: `NotificationEmailJob`

email 配信ジョブ。後送ゆえ実行時はテナント文脈が消失 → 冒頭 `with_tenant` で再確立（§3.6）。`with_lock` 内で `pending?` を確認してから送信（冪等）。`deliver_now` を `with_lock` 内で実行＝SMTP I/O 間の行ロック保持は**意図的**（4-1 は低ボリューム前提・§9⑧）。transient 失敗は `retry_on`。`executions` を正に error 確定（`retry_count` は監査ミラー）。最終失敗時は **re-raise せず** status:error を確定させて commit（with_lock tx 内で raise すると rollback するため）。

**Files:**
- Create: `app/jobs/notification_email_job.rb`
- Test: `spec/jobs/notification_email_job_spec.rb`

**Interfaces:**
- Consumes: `NotificationMailer.notify(notification)`（Task 2）/ `NotificationDelivery`（4-1a・`#notification`/`#pending?`/`#sent?`/`status` enum）
- Produces: `NotificationEmailJob.perform_later(organization_id:, delivery_id:)` / `perform(organization_id:, delivery_id:)`。成功で `status: :sent`、最終失敗で `status: :error`。冪等（sent 済を二重送信しない）。

- [ ] **Step 1: 失敗するテストを書く**

`spec/jobs/notification_email_job_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationEmailJob, type: :job do
  include ActiveJob::TestHelper

  let(:org) { create(:organization, subdomain: "acme") }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user, email: "u@example.com") } }
  let(:notification) { ActsAsTenant.with_tenant(org) { create(:notification, target_user: user) } }
  let(:delivery) do
    ActsAsTenant.with_tenant(org) { create(:notification_delivery, notification:, status: :pending) }
  end

  before { ActionMailer::Base.deliveries.clear }

  it "pending を送信し status: sent にする（テナント再確立）" do
    expect {
      described_class.perform_now(organization_id: org.id, delivery_id: delivery.id)
    }.to change { ActionMailer::Base.deliveries.size }.by(1)
    expect(delivery.reload).to be_sent
  end

  it "sent 済は二重送信しない（冪等）" do
    ActsAsTenant.with_tenant(org) { delivery.update!(status: :sent) }
    expect {
      described_class.perform_now(organization_id: org.id, delivery_id: delivery.id)
    }.not_to change { ActionMailer::Base.deliveries.size }
  end

  it "削除済み delivery は無視（早期 return）" do
    missing_id = delivery.id
    ActsAsTenant.with_tenant(org) { delivery.destroy! }
    expect {
      described_class.perform_now(organization_id: org.id, delivery_id: missing_id)
    }.not_to change { ActionMailer::Base.deliveries.size }
  end

  it "transient 失敗（未最終）は再 raise し pending を維持（retry_on が再試行）" do
    allow(NotificationMailer).to receive(:notify).and_raise(Net::OpenTimeout)
    allow_any_instance_of(described_class).to receive(:executions).and_return(1)
    expect {
      described_class.perform_now(organization_id: org.id, delivery_id: delivery.id)
    }.to raise_error(Net::OpenTimeout)
    expect(delivery.reload).to be_pending
  end

  it "リトライ枯渇（executions >= MAX）で status: error 確定（re-raise せず commit）" do
    allow(NotificationMailer).to receive(:notify).and_raise(Net::OpenTimeout)
    allow_any_instance_of(described_class).to receive(:executions).and_return(described_class::MAX_ATTEMPTS)
    expect {
      described_class.perform_now(organization_id: org.id, delivery_id: delivery.id)
    }.not_to raise_error
    expect(delivery.reload).to be_error
    expect(delivery.retry_count).to eq(described_class::MAX_ATTEMPTS - 1)
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/jobs/notification_email_job_spec.rb`
Expected: FAIL（`uninitialized constant NotificationEmailJob`）

- [ ] **Step 3: 最小実装**

`app/jobs/notification_email_job.rb`:

```ruby
# frozen_string_literal: true

# email 配信ジョブ（設計 §4.3 / §9⑦⑧）。Notifier が set(wait_until:).perform_later で予約、
# ディスパッチャ子ジョブが取りこぼし回収で再 enqueue する。
# 後送ゆえ実行時はテナント文脈が消失 → 冒頭 with_tenant で再確立（§3.6・check-job-tenant-wrap 対象）。
class NotificationEmailJob < ApplicationJob
  # transient な配送失敗のみ再試行。executions は ActiveJob 組込で増える（error 確定の正・§9⑧）。
  RETRYABLE = [Net::OpenTimeout, Net::ReadTimeout, Net::SMTPServerBusy, Errno::ECONNREFUSED].freeze
  MAX_ATTEMPTS = 4 # 1 初回 + 3 リトライ。executions >= MAX_ATTEMPTS で error 確定

  retry_on(*RETRYABLE, wait: :polynomially_longer, attempts: MAX_ATTEMPTS)

  def perform(organization_id:, delivery_id:)
    org = Organization.find(organization_id)
    ActsAsTenant.with_tenant(org) do # §3.6 必須（リクエスト文脈なし）
      delivery = NotificationDelivery.find_by(id: delivery_id)
      return if delivery.nil? # 削除済みは無視

      # SMTP I/O 間の行ロック保持は意図的（低ボリューム前提・§9⑧）。
      # status 遷移の書き込みはこの with_lock 内に集約（散在状態機械にしない）。
      delivery.with_lock do
        return unless delivery.pending? # 冪等: sent/error は二重送信しない

        send_email(delivery)
      end
    end
  end

  private

  def send_email(delivery)
    NotificationMailer.notify(delivery.notification).deliver_now
    delivery.update!(status: :sent, retry_count: executions - 1)
  rescue *RETRYABLE => e
    if executions >= MAX_ATTEMPTS
      # 最終失敗: error を確定し commit させるため re-raise しない（retry_count は監査ミラー）
      delivery.update!(status: :error, retry_count: executions - 1)
      Rails.logger.error("[NotificationEmail] ##{delivery.id} error after #{executions} executions: #{e.class}")
    else
      raise e # retry_on が再スケジュール（with_lock tx は rollback・pending のまま）
    end
  end
end
```

- [ ] **Step 4: テスト green を確認**

Run: `bundle exec rspec spec/jobs/notification_email_job_spec.rb`
Expected: PASS（5 example green）

- [ ] **Step 5: コミット**

```bash
git add app/jobs/notification_email_job.rb spec/jobs/notification_email_job_spec.rb
git commit -m "feat: NotificationEmailJob（with_tenant 再確立 + with_lock 冪等 + executions 基点 error 確定・§9⑦⑧）"
```

---

### Task 4: `Notifier`（生成入口）

通知生成の単一入口。Notification を作成（in_app の実体）→ 優先度 × 二重 opt-in で email 要否 → 抑制で scheduled_at → Delivery 作成（すべて明示 tx 内）→ **tx 確定後**に in_app broadcast（署名 stream・§9⑨）と `NotificationEmailJob.set(wait_until:).perform_later`（§9③）。broadcast 描画用の最小 partial も作る（4-1c で再整形）。

**Files:**
- Create: `app/services/notifier.rb`
- Create: `app/views/notifications/_notification.html.erb`
- Test: `spec/services/notifier_spec.rb`

**Interfaces:**
- Consumes: `Notifications::SuppressionWindow`（Task 1）/ `NotificationEmailJob`（Task 3・`perform_later(organization_id:, delivery_id:)`）/ `Notification`・`NotificationDelivery`（4-1a）/ `CompanyCalendarResolver#day_type(date)`（既存・シンボル返す）/ `Organization#setting`・`#time_zone`（既存）
- Produces: `Notifier.call(target_user:, title:, body:, priority:, source_type:, subject_user: nil)` → 作成した `Notification`。副作用: in_app broadcast（常時）・email Delivery 作成 + 1 件 enqueue（優先度 × 二重 opt-in を満たす時のみ）。

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/notifier_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Notifier, type: :service do
  include ActiveJob::TestHelper

  let(:org) { create(:organization, subdomain: "acme") }
  let(:target) { ActsAsTenant.with_tenant(org) { create(:user, email_enabled: false) } }

  def call(**overrides)
    ActsAsTenant.with_tenant(org) do
      described_class.call(**{ target_user: target, title: "承認されました", body: "本文",
                              priority: :informational, source_type: :request_approved }.merge(overrides))
    end
  end

  # 平日昼 JST に固定（quiet/holiday 非抑制）。holiday_block も既定 true ゆえ平日を担保。
  around do |ex|
    travel_to(Time.utc(2026, 6, 24, 3, 0)) { ex.run } # 2026-06-24(水) 12:00 JST
  end

  describe "in_app（常時・優先度/opt-in 非依存）" do
    it "Notification を必ず作成する" do
      expect { call(priority: :reference) }.to change { ActsAsTenant.with_tenant(org) { Notification.count } }.by(1)
    end

    it "target_user の署名 stream に broadcast する（§9⑨）" do
      expect { call }.to have_broadcasted_to(target).from_channel(Turbo::StreamsChannel)
    end
  end

  describe "優先度 × 二重 opt-in（§4.1）" do
    def email_deliveries
      ActsAsTenant.with_tenant(org) { NotificationDelivery.email.count }
    end

    it "action_required は全 opt-in off でも email Delivery 生成（常時）" do
      ActsAsTenant.with_tenant(org) { org.setting.update!(email_notification_enabled: false) }
      expect { call(priority: :action_required) }.to change { email_deliveries }.by(1)
    end

    it "informational・組織 on × 個人 off → email 無" do
      ActsAsTenant.with_tenant(org) do
        org.setting.update!(email_notification_enabled: true)
        target.update!(email_enabled: false)
      end
      expect { call(priority: :informational) }.not_to change { email_deliveries }
    end

    it "informational・組織 off × 個人 on → email 無" do
      ActsAsTenant.with_tenant(org) do
        org.setting.update!(email_notification_enabled: false)
        target.update!(email_enabled: true)
      end
      expect { call(priority: :informational) }.not_to change { email_deliveries }
    end

    it "informational・両 on → email Delivery 生成 + enqueue" do
      ActsAsTenant.with_tenant(org) do
        org.setting.update!(email_notification_enabled: true)
        target.update!(email_enabled: true)
      end
      expect { call(priority: :informational) }
        .to change { email_deliveries }.by(1)
        .and have_enqueued_job(NotificationEmailJob)
    end

    it "reference は両 opt-in でも email Delivery 0 件" do
      ActsAsTenant.with_tenant(org) do
        org.setting.update!(email_notification_enabled: true)
        target.update!(email_enabled: true)
      end
      expect { call(priority: :reference) }.not_to change { email_deliveries }
    end
  end

  describe "抑制 → scheduled_at（email のみ・§4.2）" do
    before do
      ActsAsTenant.with_tenant(org) do
        org.setting.update!(email_notification_enabled: true, holiday_block_enabled: false)
        target.update!(email_enabled: true)
      end
    end

    it "非抑制（平日昼）は scheduled_at ≒ 即時" do
      ActsAsTenant.with_tenant(org) do
        described_class.call(target_user: target, title: "t", body: "b",
                             priority: :action_required, source_type: :request_approved)
        delivery = NotificationDelivery.email.last
        expect(delivery.scheduled_at).to be_within(5.seconds).of(Time.current)
      end
    end

    it "quiet 帯（夜間）は scheduled_at が未来（翌朝）にずれる" do
      travel_to(Time.utc(2026, 6, 24, 11, 0)) do # 20:00 JST
        ActsAsTenant.with_tenant(org) do
          described_class.call(target_user: target, title: "t", body: "b",
                               priority: :action_required, source_type: :request_approved)
          delivery = NotificationDelivery.email.last
          expect(delivery.scheduled_at).to be > Time.current
        end
      end
    end

    it "enqueue は wait_until: scheduled_at で行う" do
      travel_to(Time.utc(2026, 6, 24, 11, 0)) do
        ActsAsTenant.with_tenant(org) do
          described_class.call(target_user: target, title: "t", body: "b",
                               priority: :action_required, source_type: :request_approved)
          delivery = NotificationDelivery.email.last
          enqueued = enqueued_jobs.find { |j| j[:job] == NotificationEmailJob }
          # :at は wait_until の epoch float（ActiveJob::TestHelper）。未来に予約されている。
          expect(enqueued[:at]).to be_within(1.second).of(delivery.scheduled_at.to_f)
        end
      end
    end
  end
end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/services/notifier_spec.rb`
Expected: FAIL（`uninitialized constant Notifier`）

- [ ] **Step 3: 最小実装**

`app/services/notifier.rb`:

```ruby
# frozen_string_literal: true

# 通知生成の単一入口（設計 §2 / §4.1〜§4.3 / §9③④⑨）。
# 1) Notification を作成（in_app の実体）
# 2) 優先度 × 二重 opt-in で email 要否を判定
# 3) email 要なら SuppressionWindow で scheduled_at を決め NotificationDelivery を作成
# 自身の DB 書き込みは明示 tx で囲み、tx 確定後に in_app broadcast + job enqueue を発火
# （rollback 時の幻通知 / 未コミット sweep 防止・§9③）。caller=producer 接続は 4-1c。
class Notifier
  HOLIDAY_DAY_TYPES = %i[saturday sunday holiday legal_holiday company_holiday].freeze

  def self.call(**) = new(**).call

  def initialize(target_user:, title:, body:, priority:, source_type:, subject_user: nil)
    @target_user = target_user
    @title = title
    @body = body
    @priority = priority.to_sym
    @source_type = source_type.to_sym
    @subject_user = subject_user
  end

  def call
    notification = nil
    delivery = nil
    ActiveRecord::Base.transaction do
      notification = Notification.create!(
        target_user: @target_user, subject_user: @subject_user,
        title: @title, body: @body, priority: @priority, source_type: @source_type
      )
      delivery = build_email_delivery(notification)
    end
    # tx 確定後（§9③）: 幻ベル・未コミット sweep を防ぐため commit 後に発火
    broadcast_in_app(notification)
    enqueue_email(delivery) if delivery
    notification
  end

  private

  # 優先度 × 二重 opt-in（§4.1）で email Delivery を作成。不要なら nil。
  def build_email_delivery(notification)
    return nil unless email?

    NotificationDelivery.create!(
      notification:, channel: :email, status: :pending, scheduled_at: email_scheduled_at
    )
  end

  def email?
    case @priority
    when :action_required then true        # 常時（opt-in 無関係）
    when :informational then double_opt_in? # 二重 opt-in 時のみ
    else false                              # reference: メール無し
    end
  end

  def double_opt_in?
    ActsAsTenant.current_tenant.setting.email_notification_enabled && @target_user.email_enabled
  end

  # 抑制（§4.2・email のみ）。非抑制なら即時。
  def email_scheduled_at
    window = suppression_window
    window.suppressed? ? window.next_allowed_at : Time.current
  end

  def suppression_window
    pref = resolved_preference
    org = ActsAsTenant.current_tenant
    now_local = Time.current.in_time_zone(org.time_zone) # 組織ローカル（§9①）
    Notifications::SuppressionWindow.new(
      now_local:,
      quiet_enabled: pref.quiet_hours_enabled,
      quiet_start: pref.quiet_hours_start,
      quiet_end: pref.quiet_hours_end,
      holiday_block: pref.holiday_block_enabled,
      holiday: holiday_today?(org, now_local.to_date)
    )
  end

  # UserNotificationPreference → 無ければ OrganizationSetting（§4.2）。
  # 両者は quiet_hours_enabled / quiet_hours_start / quiet_hours_end / holiday_block_enabled を持つ。
  def resolved_preference
    UserNotificationPreference.find_by(user: @target_user) || ActsAsTenant.current_tenant.setting
  end

  def holiday_today?(org, date)
    CompanyCalendarResolver.new(organization: org).day_type(date).in?(HOLIDAY_DAY_TYPES)
  end

  # 署名 stream（GlobalID）にのみ broadcast（§9⑨）。target は 4-1c のベル list 要素。
  def broadcast_in_app(notification)
    Turbo::StreamsChannel.broadcast_prepend_to(
      @target_user,
      target: "notifications",
      partial: "notifications/notification",
      locals: { notification: }
    )
  end

  def enqueue_email(delivery)
    NotificationEmailJob.set(wait_until: delivery.scheduled_at)
                        .perform_later(organization_id: ActsAsTenant.current_tenant.id, delivery_id: delivery.id)
  end
end
```

`app/views/notifications/_notification.html.erb`（最小・4-1c で NotificationBellComponent に合わせ再整形）:

```erb
<%# 4-1b: broadcast 描画用の最小要素。4-1c でベルのドロップダウン項目に再整形する %>
<li id="<%= dom_id(notification) %>" class="notification-item">
  <%= notification.title %>
</li>
```

- [ ] **Step 4: テスト green を確認**

Run: `bundle exec rspec spec/services/notifier_spec.rb`
Expected: PASS（全 example green）

注（実装者向け）: `have_broadcasted_to` は cable.yml の `test: adapter: test`（確認済）で動く。green にならない場合は `spec/rails_helper.rb` の RSpec.configure に `config.include ActiveJob::TestHelper` 等が要るか確認（rspec-rails が `have_broadcasted_to` を提供）。**調査が要る逸脱は BLOCKED 報告**し、勝手に独自 channel を作らない（§9⑨）。

- [ ] **Step 5: コミット**

```bash
git add app/services/notifier.rb app/views/notifications/_notification.html.erb spec/services/notifier_spec.rb
git commit -m "feat: Notifier（生成入口・優先度×二重opt-in×抑制・tx後 broadcast/enqueue・§9③④⑨）"
```

---

### Task 5: ディスパッチャ→子ジョブ + `Organization.active` + recurring

毎時 sweep。ディスパッチャは `current_tenant = nil` 前提で `Organization.active` をスコープ外列挙し子に org_id を渡す。子は with_tenant で当該テナントの **due な email pending** Delivery を email job へ。取りこぼし回収（Delivery 作成済・enqueue 前クラッシュ）＋ 4-2/4-3 が踏襲する dispatcher 雛形の規範実装（§9⑪）。

**Files:**
- Create: `app/jobs/notification_dispatch_job.rb`
- Create: `app/jobs/notification_dispatch_tenant_job.rb`
- Modify: `app/models/organization.rb`（`scope :active` 追加・§9⑩）
- Modify: `config/recurring.yml`（`notification_dispatch` 追加）
- Test: `spec/jobs/notification_dispatch_job_spec.rb`
- Test: `spec/jobs/notification_dispatch_tenant_job_spec.rb`
- Test: `spec/models/organization_spec.rb`（`scope :active` の example 追記）

**Interfaces:**
- Consumes: `Organization.active`（本タスクで追加）/ `NotificationEmailJob`（Task 3）/ `NotificationDelivery.email.pending`（4-1a の enum + scope）
- Produces: `NotificationDispatchJob.perform_now` → active org ごとに `NotificationDispatchTenantJob.perform_later(org_id)` / `NotificationDispatchTenantJob.perform(org_id)` → 当該テナントの due pending email Delivery ごとに `NotificationEmailJob.perform_later(organization_id:, delivery_id:)`

- [ ] **Step 1: 失敗するテスト（`Organization.active`）を書く**

`spec/models/organization_spec.rb` に追記（既存 describe 群の末尾に新規 describe を追加）:

```ruby
  describe ".active スコープ（§9⑩・ディスパッチャ用）" do
    it "active=true のみ返す" do
      active = create(:organization)
      inactive = create(:organization, active: false)
      expect(Organization.active).to include(active)
      expect(Organization.active).not_to include(inactive)
    end
  end
```

- [ ] **Step 2: 失敗を確認**

Run: `bundle exec rspec spec/models/organization_spec.rb -e "active スコープ"`
Expected: FAIL（`undefined method 'active' for Organization` ないし全件返り include 失敗）

- [ ] **Step 3: `Organization.active` を実装**

`app/models/organization.rb` の validates 群の直後（`validate :fiscal_year_end_month_locked_when_balances_exist` の下）に追加:

```ruby
  # ディスパッチャ（NotificationDispatchJob）がスコープ外列挙に使う（§9⑩・設計 §4.4）。
  # resolve_tenant は生 where(active:) を使うため scope 化はここが初出。
  scope :active, -> { where(active: true) }
```

- [ ] **Step 4: green を確認**

Run: `bundle exec rspec spec/models/organization_spec.rb -e "active スコープ"`
Expected: PASS

- [ ] **Step 5: 失敗する子ジョブテストを書く**

`spec/jobs/notification_dispatch_tenant_job_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationDispatchTenantJob, type: :job do
  include ActiveJob::TestHelper

  let(:org) { create(:organization) }

  def delivery(status:, scheduled_at:, channel: :email, organization: org)
    ActsAsTenant.with_tenant(organization) do
      n = create(:notification)
      create(:notification_delivery, notification: n, status:, scheduled_at:, channel:)
    end
  end

  it "当該テナントの due な email pending のみ email job へ" do
    due = delivery(status: :pending, scheduled_at: 1.hour.ago)
    delivery(status: :pending, scheduled_at: 1.hour.from_now) # 未来 → 拾わない
    delivery(status: :sent, scheduled_at: 1.hour.ago)         # sent → 拾わない
    delivery(status: :error, scheduled_at: 1.hour.ago)        # error → 拾わない

    expect {
      described_class.perform_now(org.id)
    }.to have_enqueued_job(NotificationEmailJob)
      .with(organization_id: org.id, delivery_id: due.id)
      .exactly(1).time
  end

  it "他テナントの due pending を拾わない（クロステナント漏洩ゼロ・§3.6）" do
    other = create(:organization)
    delivery(status: :pending, scheduled_at: 1.hour.ago, organization: other)

    expect {
      described_class.perform_now(org.id)
    }.not_to have_enqueued_job(NotificationEmailJob)
  end
end
```

- [ ] **Step 6: 失敗を確認**

Run: `bundle exec rspec spec/jobs/notification_dispatch_tenant_job_spec.rb`
Expected: FAIL（`uninitialized constant NotificationDispatchTenantJob`）

- [ ] **Step 7: 子ジョブを実装**

`app/jobs/notification_dispatch_tenant_job.rb`:

```ruby
# frozen_string_literal: true

# ディスパッチャの子（設計 §4.3 / §4.4 / §9⑪）。with_tenant で当該テナントの
# due な email pending Delivery を NotificationEmailJob へ流す（取りこぼし回収）。
class NotificationDispatchTenantJob < ApplicationJob
  def perform(organization_id)
    org = Organization.find(organization_id)
    ActsAsTenant.with_tenant(org) do # §3.6 必須（リクエスト文脈なし）
      NotificationDelivery.email.pending
                          .where(scheduled_at: ..Time.current)
                          .find_each do |delivery|
        NotificationEmailJob.perform_later(organization_id: org.id, delivery_id: delivery.id)
      end
    end
  end
end
```

- [ ] **Step 8: green を確認**

Run: `bundle exec rspec spec/jobs/notification_dispatch_tenant_job_spec.rb`
Expected: PASS

- [ ] **Step 9: 失敗するディスパッチャテストを書く**

`spec/jobs/notification_dispatch_job_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationDispatchJob, type: :job do
  include ActiveJob::TestHelper

  it "active org ごとに子ジョブを 1 件 enqueue（inactive は除外・§9⑩）" do
    org_a = create(:organization)
    org_b = create(:organization)
    create(:organization, active: false) # inactive → 除外

    expect {
      described_class.perform_now
    }.to have_enqueued_job(NotificationDispatchTenantJob).exactly(2).times

    expect(NotificationDispatchTenantJob).to have_been_enqueued.with(org_a.id)
    expect(NotificationDispatchTenantJob).to have_been_enqueued.with(org_b.id)
  end
end
```

- [ ] **Step 10: 失敗を確認**

Run: `bundle exec rspec spec/jobs/notification_dispatch_job_spec.rb`
Expected: FAIL（`uninitialized constant NotificationDispatchJob`）

- [ ] **Step 11: ディスパッチャを実装**

`app/jobs/notification_dispatch_job.rb`:

```ruby
# frozen_string_literal: true

# 通知配信のディスパッチャ（設計 §4.3 / §4.4 / §9⑪）。current_tenant = nil 前提で
# Organization をスコープ外列挙し、子に org_id だけ渡す（§3.6）。毎時 recurring。
# 正当化: enqueue 取りこぼし回収（Delivery 作成済・enqueue 前クラッシュ）＋
# 4-2/4-3 が踏襲する dispatcher 雛形の規範実装（§9⑪）。
class NotificationDispatchJob < ApplicationJob
  def perform
    Organization.active.find_each do |org|
      NotificationDispatchTenantJob.perform_later(org.id)
    end
  end
end
```

- [ ] **Step 12: green を確認**

Run: `bundle exec rspec spec/jobs/notification_dispatch_job_spec.rb`
Expected: PASS

- [ ] **Step 13: recurring.yml に登録**

`config/recurring.yml` の `production:` ブロックに追記（既存 `clear_solid_queue_finished_jobs` の下）:

```yaml
  notification_dispatch:
    class: NotificationDispatchJob
    schedule: every hour
```

- [ ] **Step 14: 全 spec + 静的検査**

Run: `bundle exec rspec spec/services/notifications/suppression_window_spec.rb spec/mailers/notification_mailer_spec.rb spec/jobs/notification_email_job_spec.rb spec/services/notifier_spec.rb spec/jobs/notification_dispatch_job_spec.rb spec/jobs/notification_dispatch_tenant_job_spec.rb spec/models/organization_spec.rb`
Expected: 全 PASS

Run: `bundle exec rubocop --force-exclusion app/services/notifier.rb app/services/notifications/suppression_window.rb app/mailers/notification_mailer.rb app/jobs/notification_email_job.rb app/jobs/notification_dispatch_job.rb app/jobs/notification_dispatch_tenant_job.rb app/models/organization.rb`
Expected: no offenses

Run: `bin/brakeman --no-pager`
Expected: 0 warnings

- [ ] **Step 15: コミット**

```bash
git add app/jobs/notification_dispatch_job.rb app/jobs/notification_dispatch_tenant_job.rb app/models/organization.rb config/recurring.yml spec/jobs/notification_dispatch_job_spec.rb spec/jobs/notification_dispatch_tenant_job_spec.rb spec/models/organization_spec.rb
git commit -m "feat: 通知ディスパッチャ→子ジョブ + Organization.active + recurring（取りこぼし回収・規範実装・§9⑩⑪）"
```

---

## 仕上げ（Task 6・サブエージェント駆動の最終工程として controller が実施）

- [ ] 全 spec green（`bundle exec rspec`）・rubocop（`--force-exclusion`）・brakeman 0 warn
- [ ] `tenant-isolation-reviewer`（jobs / models / Notifier に触れたため必須）— ディスパッチャのスコープ外列挙・子の with_tenter ラップ・Notifier の current_tenant 依存を検証
- [ ] ROADMAP 4-1 行更新（4-1b にチェック・PR 番号付与）
- [ ] `/preflight` → push → PR（base main・kei1110 へ `gh auth switch` 確認）
- [ ] §1.4 到達性 DoD は 4-1b では対象外（内部 API・caller は 4-1c）— PR 説明に明記

---

## Self-Review（spec 突合）

**1. Spec coverage（§4 / §9）**:
- §4.1 優先度×二重 opt-in → Task 4（matrix 6 example）✓
- §4.2 抑制（PORO・組織ローカル・start 包含/end 排他・日跨ぎ）→ Task 1（網羅）+ Task 4（wiring）✓
- §4.3 コンポーネント（Notifier/SuppressionWindow/EmailJob/Dispatch×2/Mailer）→ Task 1-5 全網羅 ✓
- §4.4 ジョブのテナント安全 → Task 3/5（with_tenant・スコープ外列挙）✓
- §9① TZ → Task 4（`in_time_zone(org.time_zone)`）✓ / §9② PORO → Task 1 ✓ / §9③ tx 後発火 → Task 4 ✓ / §9④ model 検証は 4-1a 済（本 slice は新 model 無し）✓ / §9⑦ Mailer host → Task 2 ✓ / §9⑧ executions 基点 error → Task 3 ✓ / §9⑨ 署名 stream → Task 4 ✓ / §9⑩ Organization.active → Task 5 ✓ / §9⑪ sweep 正当化 → Task 5 コメント ✓
- §9⑤⑥（Policy/フォーム）・§9⑬ の UI 系負例（既読 IDOR・承認 tx rollback・多段中間）→ **4-1c**（producer/UI 着地時）。本 slice 範囲外を明記済 ✓
- §9⑬ の配信コア負例（quiet 境界・二重 opt-in 3 セル・冪等二重発火・dispatch 絞り込み）→ Task 1/3/4/5 に配置 ✓

**2. Placeholder scan**: TBD/TODO/「適切に」なし。全 step に実コードとテストコードを記載 ✓

**3. Type consistency**:
- `Notifier.call(target_user:, title:, body:, priority:, source_type:, subject_user:)` — Task 4 定義、他タスクは呼ばない（caller は 4-1c）✓
- `NotificationEmailJob.perform_later(organization_id:, delivery_id:)` — Task 3 定義、Task 4（enqueue）/ Task 5（子ジョブ）で同一シグネチャ参照 ✓
- `NotificationDispatchTenantJob.perform(organization_id)`（位置引数）— Task 5 定義、ディスパッチャから `perform_later(org.id)` ✓
- `Notifications::SuppressionWindow.new(now_local:, quiet_enabled:, quiet_start:, quiet_end:, holiday_block:, holiday:)` — Task 1 定義、Task 4 で同一キーワード ✓
- `MAX_ATTEMPTS`（Task 3 定数）— spec から `described_class::MAX_ATTEMPTS` 参照 ✓
- `HOLIDAY_DAY_TYPES` は Notifier 内部定数（resolver 返値シンボルと一致: saturday/sunday/holiday/legal_holiday/company_holiday・weekday は除外）✓
