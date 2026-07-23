# Phase 4-2c-3b 欠勤確定の取消 UI 本体 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 誤確定した欠勤（`absent` AR）を管理者がアプリ内で取り消せる出口を作り、Phase 4-2 の完了条件（入口 8 ガードに対する出口ゼロ）を解消する。

**Architecture:** `Absences::Cancel`（`with_lock` 内で status 再判定 → `AttendanceHistory(absence_canceled)` append → `absent` AR destroy → 候補を `notified_on: nil` で再生成）を核とし、却下(dismiss)も監査行付き service（`Absences::Dismiss`）へ格上げする。認可は既存の欠勤確定と同型の二層（headless role policy + Scope roster）。UI は既存 `/absence_confirmations#index` に「確定済み欠勤」セクションを増設し `POST /absence_cancellations` へ送る。

**Tech Stack:** Rails 8 / PostgreSQL 18 / acts_as_tenant（行レベル）/ Pundit / Hotwire(Turbo) / RSpec。

## Global Constraints

- **db/schema.rb と Gemfile.lock を手編集しない。** 本スライスは **migration 不要**（`attendance_histories.event_type` / `notifications.source_type` は既存 integer カラムで DB CHECK も partial index 依存も無い。実測で確認済み）。enum 追加は**モデルの hash に append するだけ**。
- **enum 整数・event_type taxonomy は append-only**（鉄則 7・SPEC §13/§4.14）。`absence_canceled: 11` / `absence_dismissed: 12`（history）・`absence_canceled: 8`（notification）を**末尾に足すのみ**。既存値のリオーダ・再利用は禁止。
- **スコープ付きモデルに触れる書き込み service は `ActsAsTenant.with_tenant` で明示ラップ**し、**昇格の前**に actor↔target の `organization_id` 一致を独立検証する（鉄則 4・`Absences::Confirm` / `LeaveRequests::Withdraw` 同型）。
- **法定値はコード内定数**（鉄則 5）。猶予 17:00 は運用値（`Absences::GracePeriod`）。取消に猶予制約は掛けない（不利益処分の解除ゆえ）。
- **いかなる操作も打刻をブロックしない**（鉄則 6）——本スライスは事後の管理操作で打刻経路に触れない。
- **rubocop はファイル渡し時 `--force-exclusion` + xargs 経由**（鉄則 2）。`app/` に触れたら `bin/brakeman --no-pager` も必須。
- コミット著者は local config の **kei1110 <eoh2145@gmail.com>**。ステップ完了ごとに即コミット（サブエージェント運用 4 か条①）。
- i18n の **`event_type` ラベルは追加しない**（監査 taxonomy は UI/CSV に翻訳表示されない・実測で確認済み）。

---

## File Structure

**新規作成:**
- `app/services/absences/cancel.rb` — 取消副作用本体（`with_lock` + capture-before-destroy + 候補再生成）
- `app/services/absences/dismiss.rb` — 却下副作用（候補 destroy + `absence_dismissed` 監査行を 1 tx で束ねる）
- `app/policies/absence_cancellation_policy.rb` — headless role policy + Scope（**active で絞らない**）
- `app/controllers/absence_cancellations_controller.rb` — `create` のみ（取消の HTTP 入口 + 通知）
- `spec/services/absences/cancel_spec.rb`
- `spec/services/absences/dismiss_spec.rb`
- `spec/policies/absence_cancellation_policy_spec.rb`
- `spec/requests/absence_cancellations_spec.rb`

**変更:**
- `app/models/attendance_history.rb` — event_type に 11/12 追加・`ABSENCE_EVENT_TYPES` に `absence_canceled` を足す（dismissed は足さない）・actor_id presence 検証 2 本追加
- `app/models/notification.rb` — source_type に `absence_canceled: 8` 追加
- `app/controllers/absence_confirmations_controller.rb` — `destroy` を `Absences::Dismiss` へ委譲・`index` で確定済み欠勤 + 締め状態を先読み
- `app/views/absence_confirmations/index.html.erb` — 「確定済み欠勤」セクション追加
- `config/routes.rb` — `resources :absence_cancellations, only: %i[create]`
- `config/locales/ja.yml`（必要時のみ・下記 Task で判断）
- `spec/models/attendance_history_spec.rb` / `spec/models/notification_spec.rb` — enum 回帰
- `docs/ROADMAP.md` / `docs/RAILS_GOTCHAS.md`（Task 8）

**触れない面（照合で確定）:**
- `app/services/leave_requests/`（Withdraw の §5 不変条件テストは 4-2c-3a で導入済み・`withdraw_spec.rb:257`）
- migration / db/schema.rb（enum append のみ）

---

## Task 1: enum 追加（データモデル層）

**Files:**
- Modify: `app/models/attendance_history.rb:16-21`（enum）, `:35-37`（actor 検証）, `:52`（`ABSENCE_EVENT_TYPES`）
- Modify: `app/models/notification.rb:14-16`（source_type enum）
- Test: `spec/models/attendance_history_spec.rb`, `spec/models/notification_spec.rb`

**Interfaces:**
- Produces:
  - `AttendanceHistory.event_types["absence_canceled"] == 11`, `["absence_dismissed"] == 12`
  - `AttendanceHistory::ABSENCE_EVENT_TYPES` に `"absence_canceled"` を含む・`"absence_dismissed"` を含まない
  - `AttendanceHistory` は `absence_canceled` / `absence_dismissed` で `actor_id` presence を要求
  - `Notification.source_types["absence_canceled"] == 8`

- [ ] **Step 1: 失敗テストを書く**

`spec/models/attendance_history_spec.rb` に append（既存 `RSpec.describe AttendanceHistory do ... end` の中。既存の `around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }` 等の setup を再利用する。無ければ既存ファイル冒頭の setup を踏襲）:

```ruby
describe "4-2c-3b event_type 追加" do
  it "absence_canceled=11 / absence_dismissed=12 が append されている" do
    expect(AttendanceHistory.event_types["absence_canceled"]).to eq(11)
    expect(AttendanceHistory.event_types["absence_dismissed"]).to eq(12)
  end

  it "absence_canceled は absence_reason を許す（ABSENCE_EVENT_TYPES に含む）" do
    h = build(:attendance_history, event_type: :absence_canceled, actor: build(:user, :manager_role),
              absence_reason: :unauthorized, note: "誤検知のため")
    expect(h).to be_valid
  end

  it "absence_dismissed は absence_reason を許さない（候補は理由列を持たない）" do
    h = build(:attendance_history, event_type: :absence_dismissed, actor: build(:user, :manager_role),
              absence_reason: :unauthorized)
    expect(h).not_to be_valid
    expect(h.errors[:absence_reason]).to be_present
  end

  it "absence_canceled は actor 必須" do
    h = build(:attendance_history, event_type: :absence_canceled, actor: nil)
    expect(h).not_to be_valid
    expect(h.errors[:actor_id]).to be_present
  end

  it "absence_dismissed は actor 必須" do
    h = build(:attendance_history, event_type: :absence_dismissed, actor: nil)
    expect(h).not_to be_valid
    expect(h.errors[:actor_id]).to be_present
  end
end
```

`spec/models/notification_spec.rb` に append:

```ruby
describe "4-2c-3b source_type 追加" do
  it "absence_canceled=8 が append されている" do
    expect(Notification.source_types["absence_canceled"]).to eq(8)
  end
end
```

- [ ] **Step 2: テスト実行し失敗確認**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb spec/models/notification_spec.rb`
Expected: FAIL（`"absence_canceled"` キーが nil で `eq(11)` / `eq(8)` が落ちる）

- [ ] **Step 3: 最小実装**

`app/models/attendance_history.rb` の enum を末尾追記（16-21 行）:

```ruby
  enum :event_type, {
    clock_in: 0, clock_out: 1, leave_approved: 2, leave_withdrawn: 3,
    clock_change_approved: 4, absence_confirmed: 5, absence_to_paid: 6,
    proxy_clock: 7, interval_shortage: 8, clock_change_withdrawn: 9,
    absence_restored: 10, absence_canceled: 11, absence_dismissed: 12
  }, validate: true
```

actor 検証を追加（37 行 `absence_restored?` の直後）:

```ruby
  validates :actor_id, presence: true, if: :absence_canceled?  # 4-2c-3b 欠勤確定の取消（§4.14・不変ゆえ事前防御）
  validates :actor_id, presence: true, if: :absence_dismissed? # 4-2c-3b 却下(dismiss) の監査行
```

`ABSENCE_EVENT_TYPES` に `absence_canceled` を足す（52 行。**`absence_dismissed` は足さない** — 却下候補は理由列を持たない）:

```ruby
  ABSENCE_EVENT_TYPES = %w[absence_confirmed absence_to_paid absence_restored absence_canceled].freeze
```

`app/models/notification.rb` の source_type を末尾追記（14-16 行）:

```ruby
  enum :source_type, { request_approved: 0, request_rejected: 1,
                       clock_out_missing: 2, absence_candidate: 3, leave_pending_no_clock: 4,
                       proxy_clocked: 5, interval_shortage: 6, absence_confirmed: 7,
                       absence_canceled: 8 }, validate: true
```

- [ ] **Step 4: テスト実行し pass 確認**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb spec/models/notification_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + commit**

```bash
git diff --name-only | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion
git add app/models/attendance_history.rb app/models/notification.rb spec/models/attendance_history_spec.rb spec/models/notification_spec.rb
git commit -m "feat(4-2c-3b): 欠勤取消/却下の event_type・source_type を append（migration 不要）"
```

---

## Task 2: `Absences::Dismiss` service（却下を監査行付き service へ）

**Files:**
- Create: `app/services/absences/dismiss.rb`
- Test: `spec/services/absences/dismiss_spec.rb`

**Interfaces:**
- Consumes: `AttendanceHistory.event_types["absence_dismissed"]`（Task 1）
- Produces: `Absences::Dismiss.call(candidate:, actor:) -> candidate`。候補 destroy と `AttendanceHistory(absence_dismissed)` の append を**1 tx**で束ねる。actor 組織不一致は `Absences::IneligibleError`。

**背景（設計 D2・§4.3・ROADMAP 横断 #116）:** 現行 controller の `candidate.destroy!` は監査を残さず、候補は前日分しか生成されない＝**再生成されない**。「取消 → 候補復活 → 却下」で痕跡ゼロの完全消去が可能になるため、却下にも監査行を残す。

- [ ] **Step 1: 失敗テストを書く**

`spec/services/absences/dismiss_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Absences::Dismiss do
  let(:org) { create(:organization, time_zone: "Asia/Tokyo") }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:manager) { create(:user, :manager_role) }
  let(:user)    { create(:user, manager: manager) }
  let(:candidate) { create(:absence_candidate, user:, target_date: Date.new(2026, 5, 1)) }

  it "候補を destroy し absence_dismissed の監査行を残す" do
    described_class.call(candidate:, actor: manager)

    expect(AbsenceCandidate.where(id: candidate.id)).not_to exist
    history = AttendanceHistory.find_by(event_type: :absence_dismissed, event_date: Date.new(2026, 5, 1))
    expect(history.user_id).to eq(user.id)
    expect(history.actor_id).to eq(manager.id)
    expect(history.absence_reason).to be_nil
  end

  it "履歴 append が失敗すると候補は残る（同一 tx で束ねる）" do
    allow(AttendanceHistory).to receive(:create!)
      .and_raise(ActiveRecord::RecordInvalid.new(AttendanceHistory.new))

    expect { described_class.call(candidate:, actor: manager) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(AbsenceCandidate.where(id: candidate.id)).to exist
  end

  it "操作者が別組織なら IneligibleError（昇格前ガード）" do
    other_actor = ActsAsTenant.with_tenant(create(:organization)) { create(:user, :manager_role) }

    expect { described_class.call(candidate:, actor: other_actor) }
      .to raise_error(Absences::IneligibleError, /組織/)
    expect(AbsenceCandidate.where(id: candidate.id)).to exist
  end
end
```

- [ ] **Step 2: テスト実行し失敗確認**

Run: `bundle exec rspec spec/services/absences/dismiss_spec.rb`
Expected: FAIL（`uninitialized constant Absences::Dismiss`）

- [ ] **Step 3: 最小実装**

`app/services/absences/dismiss.rb`:

```ruby
# frozen_string_literal: true

module Absences
  # 欠勤候補の却下(dismiss)（SPEC §6.10・設計 4-2c-3b §4.3・D2）。
  # 現行 controller の candidate.destroy! を service へ移し、候補 destroy と
  # AttendanceHistory(absence_dismissed) の append を **1 tx** で束ねる。分離すると
  # 「候補だけ消えて履歴なし」か「却下履歴だけあって候補が残る」状態が生じる。
  #
  # 却下は候補（ephemeral）を消す操作だが、候補は前日分しか生成されず再生成されないため
  # （ROADMAP 横断 #116）、監査行を残さないと「取消→候補復活→却下」で痕跡ゼロの完全消去が
  # 可能になる（D2）。理由 note は任意（大量・定型ゆえ必須化するとコピペで情報量ゼロに収束・D4）。
  class Dismiss
    def self.call(**) = new(**).call

    def initialize(candidate:, actor:, note: nil)
      @candidate = candidate
      @actor = actor
      @note = note
    end

    def call
      guard_actor_same_organization! # with_tenant へ入る前（昇格前・Confirm/Withdraw 同型）
      ActsAsTenant.with_tenant(@candidate.user.organization) do
        ActiveRecord::Base.transaction do
          AttendanceHistory.create!(
            user_id: @candidate.user_id, actor: @actor,
            event_type: :absence_dismissed, event_date: @candidate.target_date, note: @note
          )
          @candidate.destroy!
        end
      end
      @candidate
    end

    private

    def guard_actor_same_organization!
      return if @actor.organization_id == @candidate.user.organization_id

      raise IneligibleError, "操作者と対象社員の組織が一致しません"
    end
  end
end
```

- [ ] **Step 4: テスト実行し pass 確認**

Run: `bundle exec rspec spec/services/absences/dismiss_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + brakeman + commit**

```bash
git diff --name-only | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion
bin/brakeman --no-pager
git add app/services/absences/dismiss.rb spec/services/absences/dismiss_spec.rb
git commit -m "feat(4-2c-3b): Absences::Dismiss（候補 destroy と absence_dismissed 監査を 1 tx で束ねる）"
```

---

## Task 3: controller#destroy を `Absences::Dismiss` へ委譲

**Files:**
- Modify: `app/controllers/absence_confirmations_controller.rb:35-40`
- Test: `spec/requests/absence_confirmations_spec.rb:261-`（DELETE destroy 節）

**Interfaces:**
- Consumes: `Absences::Dismiss.call(candidate:, actor:)`（Task 2）

- [ ] **Step 1: 失敗テストを書く**

`spec/requests/absence_confirmations_spec.rb` の `describe "DELETE destroy（却下 dismiss・§11④/§12⑧）"` 節に append（既存 setup の `sign_in` / `tenant_host` / `candidate_for` を再利用）:

```ruby
it "却下すると absence_dismissed の監査行が残る（4-2c-3b・痕跡ゼロ消去の封鎖）" do
  c = candidate_for(sub)
  sign_in manager

  delete absence_confirmation_url(c, host: tenant_host(org))

  expect(AbsenceCandidate.where(id: c.id)).not_to exist
  history = ActsAsTenant.with_tenant(org) do
    AttendanceHistory.find_by(event_type: :absence_dismissed, user_id: sub.id, event_date: c.target_date)
  end
  expect(history).to be_present
  expect(history.actor_id).to eq(manager.id)
end
```

- [ ] **Step 2: テスト実行し失敗確認**

Run: `bundle exec rspec spec/requests/absence_confirmations_spec.rb -e "absence_dismissed の監査行が残る"`
Expected: FAIL（現行は `candidate.destroy!` のみで履歴が無い）

- [ ] **Step 3: 最小実装**

`app/controllers/absence_confirmations_controller.rb` の `destroy`（35-40 行）を差し替え:

```ruby
  # 却下(dismiss)＝候補を削除し absence_dismissed 監査行を残す（§11④・§12⑧・4-2c-3b D2）。
  # 候補は再生成されないため監査を残さないと痕跡ゼロの完全消去が可能になる。
  # 不利益処分でないため猶予期限の制約は掛けない
  def destroy
    authorize AbsenceCandidate, :destroy?             # ① role ゲート（一般社員は 403）
    candidate = policy_scope(AbsenceCandidate).find(params[:id]) # ② 対象ゲート（scope 外は 404）
    Absences::Dismiss.call(candidate:, actor: current_user)
    redirect_to absence_confirmations_path, status: :see_other, notice: "欠勤候補を却下しました"
  end
```

- [ ] **Step 4: テスト実行し pass 確認**

Run: `bundle exec rspec spec/requests/absence_confirmations_spec.rb`
Expected: PASS（既存の却下テストも緑のまま）

- [ ] **Step 5: rubocop + brakeman + commit**

```bash
git diff --name-only | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion
bin/brakeman --no-pager
git add app/controllers/absence_confirmations_controller.rb spec/requests/absence_confirmations_spec.rb
git commit -m "feat(4-2c-3b): 却下 controller を Absences::Dismiss へ委譲（監査行を残す）"
```

---

## Task 4: `Absences::Cancel` service（取消本体）

**Files:**
- Create: `app/services/absences/cancel.rb`
- Test: `spec/services/absences/cancel_spec.rb`

**Interfaces:**
- Consumes: `AttendanceHistory.event_types["absence_canceled"]`（Task 1）・`Absences::IneligibleError` / `ClosingLockedError`（`app/services/absences.rb`）・`MonthlySummaries::ClosingLock.locked?(user:, dates:)`
- Produces: `Absences::Cancel.call(target_user:, record:, note:, actor:) -> record`。`absent` AR を destroy し `AttendanceHistory(absence_canceled)` を append、候補を `notified_on: nil` で再生成する。ガード違反は `IneligibleError` / `ClosingLockedError`、既に消えていれば `ActiveRecord::RecordNotFound`。

- [ ] **Step 1: 失敗テストを書く**

`spec/services/absences/cancel_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Absences::Cancel do
  let(:org) { create(:organization, time_zone: "Asia/Tokyo") }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:manager) { create(:user, :manager_role) }
  let(:user)    { create(:user, manager: manager) }
  let(:work_date) { Date.new(2026, 5, 1) }

  # 確定済み欠勤（Absences::Confirm が作る形）
  def absent_record(reason: :unauthorized, note: nil)
    create(:attendance_record, user:, work_date:, status: :absent, absence_reason: reason, note:)
  end

  def cancel(record:, note: "誤検知のため取消", actor: manager)
    described_class.call(target_user: user, record:, note:, actor:)
  end

  describe "正常系" do
    it "absent AR を destroy し absence_canceled 履歴を残し候補を notified_on:nil で再生成する" do
      record = absent_record(reason: :illness, note: nil)

      cancel(record:)

      expect(AttendanceRecord.where(id: record.id)).not_to exist
      history = AttendanceHistory.find_by(event_type: :absence_canceled, event_date: work_date)
      expect(history.user_id).to eq(user.id)
      expect(history.actor_id).to eq(manager.id)
      expect(history.previous_status).to eq(AttendanceRecord.statuses[:absent])
      expect(history.new_status).to be_nil
      expect(history.absence_reason).to eq("illness")   # 取り消した理由を構造化して保持
      expect(history.note).to eq("誤検知のため取消")     # 取消理由（必須）
      candidate = AbsenceCandidate.find_by(user_id: user.id, target_date: work_date)
      expect(candidate).to be_present
      expect(candidate.notified_on).to be_nil
    end

    it "other 理由の自由記述も履歴 absence_reason=other + note に取消理由を残す" do
      record = absent_record(reason: :other, note: "システム障害")

      cancel(record:, note: "打刻ミスと判明")

      history = AttendanceHistory.find_by(event_type: :absence_canceled, event_date: work_date)
      expect(history.absence_reason).to eq("other")
      expect(history.note).to eq("打刻ミスと判明")
    end
  end

  describe "ガード" do
    it "取消理由 note が空なら IneligibleError（AR は残る）" do
      record = absent_record
      expect { cancel(record:, note: " ") }.to raise_error(Absences::IneligibleError, /取消理由/)
      expect(AttendanceRecord.where(id: record.id)).to exist
    end

    it "操作者が別組織なら IneligibleError（昇格前ガード・AR は残る）" do
      record = absent_record
      other_actor = ActsAsTenant.with_tenant(create(:organization)) { create(:user, :manager_role) }
      expect { cancel(record:, actor: other_actor) }.to raise_error(Absences::IneligibleError, /組織/)
      expect(AttendanceRecord.where(id: record.id)).to exist
    end

    it "record が target_user のものでなければ IneligibleError" do
      other_user = create(:user, manager: manager)
      record = create(:attendance_record, user: other_user, work_date:, status: :absent,
                      absence_reason: :unauthorized)
      expect { described_class.call(target_user: user, record:, note: "x", actor: manager) }
        .to raise_error(Absences::IneligibleError, /対象社員のもの/)
    end

    it "締め済み（finalized）月は ClosingLockedError（AR は残る）" do
      record = absent_record
      create(:monthly_attendance_summary, user:,
             year_month: AttendancePeriod.containing(organization: org, date: work_date).label,
             status: :finalized)
      expect { cancel(record:) }.to raise_error(Absences::ClosingLockedError)
      expect(AttendanceRecord.where(id: record.id)).to exist
    end
  end

  describe "不変条件（設計 §5・4-2c-3a 前提）" do
    it "ロック後に status が absent でなければ IneligibleError（事後有給の振替を取消が destroy しない）" do
      record = absent_record
      # with_lock 内の reload で status が on_leave に化ける状況を stub で作る。
      # guard_still_absent! が with_lock の内側にあることの証明
      allow_any_instance_of(AttendanceRecord).to receive(:absent?).and_return(false)

      expect { cancel(record:) }.to raise_error(Absences::IneligibleError, /振り替え|欠勤ではありません/)
    end
  end

  describe "競合（設計 §4.2）" do
    it "取消前に AR が別操作で消えていれば RecordNotFound（with_lock の reload が掴めない）" do
      record = absent_record
      AttendanceRecord.where(id: record.id).delete_all

      expect { cancel(record:) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end
end
```

- [ ] **Step 2: テスト実行し失敗確認**

Run: `bundle exec rspec spec/services/absences/cancel_spec.rb`
Expected: FAIL（`uninitialized constant Absences::Cancel`）

- [ ] **Step 3: 最小実装**

`app/services/absences/cancel.rb`:

```ruby
# frozen_string_literal: true

module Absences
  # 欠勤確定の取消（SPEC §6.10・§4.14・設計 4-2c-3b §4.1）。
  # Absences::Confirm は 8 ガード（入口）で確定を守るが、確定は賃金控除に直結する不利益記録なのに
  # 出口が無かった。誤確定を是正する唯一の出口として、absent AR を destroy し
  # AttendanceHistory(absence_canceled) を残す。
  #
  # Confirm の 8 ガードのうち ②毒入力・③候補実在・⑤弁明の行使・⑥未通知・⑦猶予は取消では意味が反転
  # するため共有せず別 service にする。ガード順:
  #   ① 操作者の組織（with_tenant 昇格の**前**）→ ② 取消理由 presence → ③ 対象所有
  #   → ④ 締め済み（tx 内・§7-b の限界あり）→ ⑤ ロック後 status 再判定（with_lock 内・絶対に外せない）
  class Cancel
    def self.call(**) = new(**).call

    def initialize(target_user:, record:, note:, actor:)
      @target_user = target_user
      @record = record
      @note = note
      @actor = actor
    end

    def call
      guard_actor_same_organization! # with_tenant へ入る前（昇格前・Confirm/Withdraw 同型）
      ActsAsTenant.with_tenant(organization) do
        guard_note!
        guard_record_belongs_to_target!
        ActiveRecord::Base.transaction do
          guard_closing! # tx 内（判定と write の間に締めが commit する窓を縮める・§7-b で完全には閉じない）
          @record.with_lock do
            # ⑤ を with_lock の内側に置くのが要点。外に置くと読んだ status と削除する行の status が
            #    別物になり得る（事後有給の承認が absent→on_leave を書く窓）。承認済みの有給休暇日を
            #    取消が destroy する事故はこれでのみ防げる（設計 §4.1・§5 の不変条件が支える）
            guard_still_absent!
            previous_reason = @record.absence_reason # capture-before-destroy
            AttendanceHistory.create!(
              user: @target_user, actor: @actor,
              event_type: :absence_canceled, event_date: @record.work_date,
              previous_status: AttendanceRecord.statuses[:absent], new_status: nil,
              absence_reason: previous_reason, note: @note
            )
            @record.destroy!
            # 取消しても「その日が未説明」である事実は変わらない。notified_on:nil で作り直し
            # 日次バッチの猶予再起算に乗せる（ベストエフォート・§7-a の限界あり）
            AbsenceCandidate.create!(user: @target_user, target_date: @record.work_date, notified_on: nil)
          end
        end
      end
      @record
    end

    private

    def organization = @target_user.organization

    # ① with_tenant(@target_user.organization) は文脈を「切り替える」昇格プリミティブで境界ではない。
    #    内側では複合 FK も cross_tenant 検証も越境を検出できない。昇格前の検証が唯一の境界
    def guard_actor_same_organization!
      return if @actor.organization_id == @target_user.organization_id

      raise IneligibleError, "操作者と対象社員の組織が一致しません"
    end

    # ② 取消は賃金控除を消す低頻度・不正の動機がある唯一の出口ゆえ note 必須（D4）
    def guard_note!
      return if @note.present?

      raise IneligibleError, "取消理由を入力してください"
    end

    # ③ 呼び出し元の契約違反（target_user と record の食い違い）を write 前に拒否する（多層防御）
    def guard_record_belongs_to_target!
      return if @record.user_id == @target_user.id

      raise IneligibleError, "対象の勤怠記録が対象社員のものではありません"
    end

    # ④ 締め済み（submitted / finalized）月は取消不可（Confirm ⑧ と対称・§7-b の TOCTOU 限界あり）
    def guard_closing!
      return unless MonthlySummaries::ClosingLock.locked?(user: @target_user, dates: [ @record.work_date ])

      raise ClosingLockedError, "締め済みの月（提出済 / 確定）の欠勤は取り消せません"
    end

    # ⑤ ロック後に status を再判定。事後有給の承認が absent→on_leave を書いた後なら取消を拒否する
    #    （承認済みの休暇日を destroy しない）。設計 §5 の不変条件が「absent なら absence_to_paid は
    #    最新でない」を保証し、Withdraw の復元と衝突しない
    def guard_still_absent!
      return if @record.absent?

      raise IneligibleError, "既に有給休暇へ振り替えられています（欠勤ではありません）"
    end
  end
end
```

- [ ] **Step 4: テスト実行し pass 確認**

Run: `bundle exec rspec spec/services/absences/cancel_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + brakeman + commit**

```bash
git diff --name-only | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion
bin/brakeman --no-pager
git add app/services/absences/cancel.rb spec/services/absences/cancel_spec.rb
git commit -m "feat(4-2c-3b): Absences::Cancel（with_lock 内 status 再判定・候補再生成・締めガード）"
```

---

## Task 5: `AbsenceCancellationPolicy` + Scope

**Files:**
- Create: `app/policies/absence_cancellation_policy.rb`
- Test: `spec/policies/absence_cancellation_policy_spec.rb`

**Interfaces:**
- Produces: `AbsenceCancellationPolicy#create? = manager_or_admin?`・`AbsenceCancellationPolicy::Scope`（roster over User・**`active: true` で絞らない**）

**背景（設計 §4.6）:** `AbsenceConfirmationPolicy::Scope` は候補が `User.active` にしか生えないため active を要求するが、取消は過去の確定を直す操作で、**対象が退職・無効化済みでも直せなければならない**。ゆえに active で絞らない。

- [ ] **Step 1: 失敗テストを書く**

`spec/policies/absence_cancellation_policy_spec.rb`（既存 `absence_confirmation_policy_spec.rb` の流儀を踏襲）:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbsenceCancellationPolicy do
  let(:org) { create(:organization) }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)       { create(:user, :hr_admin) }
  let(:manager)  { create(:user, :manager_role, manager: hr) }
  let(:sub)      { create(:user, manager: manager) }
  let(:employee) { create(:user) }

  describe "#create?" do
    it "manager / hr_admin は許可・一般社員は拒否" do
      expect(described_class.new(manager, :absence_cancellation).create?).to be(true)
      expect(described_class.new(hr, :absence_cancellation).create?).to be(true)
      expect(described_class.new(employee, :absence_cancellation).create?).to be(false)
    end
  end

  describe "Scope" do
    it "hr_admin は組織全体を解決する（無効化済みも含む）" do
      inactive = create(:user, manager: manager)
      inactive.update!(active: false)
      resolved = AbsenceCancellationPolicy::Scope.new(hr, User).resolve
      expect(resolved).to include(sub, inactive)
    end

    it "manager は直属部下のみ（無効化済み部下も含む）" do
      inactive_sub = create(:user, manager: manager)
      inactive_sub.update!(active: false)
      resolved = AbsenceCancellationPolicy::Scope.new(manager, User).resolve
      expect(resolved).to include(sub, inactive_sub)
      expect(resolved).not_to include(employee) # 別 manager 配下
    end

    it "一般社員は誰も解決しない" do
      expect(AbsenceCancellationPolicy::Scope.new(employee, User).resolve).to be_empty
    end
  end
end
```

- [ ] **Step 2: テスト実行し失敗確認**

Run: `bundle exec rspec spec/policies/absence_cancellation_policy_spec.rb`
Expected: FAIL（`uninitialized constant AbsenceCancellationPolicy`）

- [ ] **Step 3: 最小実装**

`app/policies/absence_cancellation_policy.rb`:

```ruby
# frozen_string_literal: true

# 欠勤確定の取消 headless policy（`authorize :absence_cancellation, :create?`・AbsenceConfirmationPolicy 同型）。
# 認可は二層: ① role ゲート（本 policy）② 対象ゲート（controller の policy_scope.find → 404）。
class AbsenceCancellationPolicy < ApplicationPolicy
  def create? = manager_or_admin?

  # 取消対象社員のロスター（over User）。AbsenceConfirmationPolicy::Scope と違い **active で絞らない** —
  # 取消は過去の確定を直す操作で、対象が退職・無効化済みでも直せなければならない（設計 §4.6）。
  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.hr_admin?
        scope.where(organization_id: user.organization_id)
      elsif user.manager?
        scope.where(organization_id: user.organization_id, manager_id: user.id)
      else
        scope.none
      end
    end
  end

  private

  def manager_or_admin? = user.manager? || user.hr_admin?
end
```

- [ ] **Step 4: テスト実行し pass 確認**

Run: `bundle exec rspec spec/policies/absence_cancellation_policy_spec.rb`
Expected: PASS

- [ ] **Step 5: rubocop + commit**

```bash
git diff --name-only | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion
git add app/policies/absence_cancellation_policy.rb spec/policies/absence_cancellation_policy_spec.rb
git commit -m "feat(4-2c-3b): AbsenceCancellationPolicy（active で絞らない roster・退職者も取消可）"
```

---

## Task 6: routes + `AbsenceCancellationsController#create` + 通知

**Files:**
- Modify: `config/routes.rb:101`（`absence_confirmations` の直後）
- Create: `app/controllers/absence_cancellations_controller.rb`
- Test: `spec/requests/absence_cancellations_spec.rb`

**Interfaces:**
- Consumes: `Absences::Cancel.call`（Task 4）・`AbsenceCancellationPolicy`（Task 5）・`Notifier.call`（`source_type: :absence_canceled`・Task 1）
- Produces: `POST /absence_cancellations`（params: `user_id`, `work_date`(ISO8601), `note`）

- [ ] **Step 1: route 追加**

`config/routes.rb` の 101 行（`resources :absence_confirmations, ...` の直後）に追記:

```ruby
  # 欠勤確定の取消（§6.10・4-2c-3b）。POST のみ — 確定済み AR を work_date で指す（:id 型衝突回避・設計 D3）
  resources :absence_cancellations, only: %i[create]
```

- [ ] **Step 2: 失敗テストを書く**

`spec/requests/absence_cancellations_spec.rb`（`absence_confirmations_spec.rb` の setup を踏襲）:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AbsenceCancellations", type: :request do
  let!(:org) { create(:organization, subdomain: "acme", time_zone: "Asia/Tokyo") }
  let!(:hr)      { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin, name: "人事 花子") } }
  let!(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: hr, name: "上長 一郎") } }
  let!(:sub)     { ActsAsTenant.with_tenant(org) { create(:user, manager: manager, name: "部下 太郎") } }
  let!(:stranger){ ActsAsTenant.with_tenant(org) { create(:user, manager: hr, name: "他部 次郎") } }

  let(:work_date) { Date.new(2026, 5, 1) }

  def absent_record_for(user)
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date:, status: :absent, absence_reason: :unauthorized)
    end
  end

  def cancel_params(user, note: "誤検知のため取消")
    { user_id: user.id, work_date: work_date.to_s, note: }
  end

  it "manager は部下の確定済み欠勤を取り消せる（AR destroy・履歴・候補再生成）" do
    record = absent_record_for(sub)
    sign_in manager

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub)

    expect(response).to have_http_status(:see_other)
    ActsAsTenant.with_tenant(org) do
      expect(AttendanceRecord.where(id: record.id)).not_to exist
      expect(AttendanceHistory.find_by(event_type: :absence_canceled, user_id: sub.id)).to be_present
      expect(AbsenceCandidate.find_by(user_id: sub.id, target_date: work_date).notified_on).to be_nil
    end
  end

  it "本人へ取消の informational 通知が届く" do
    absent_record_for(sub)
    sign_in manager

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub)

    notification = ActsAsTenant.with_tenant(org) do
      Notification.find_by(source_type: :absence_canceled, target_user_id: sub.id)
    end
    expect(notification).to be_present
    expect(notification.priority).to eq("informational")
  end

  it "取消理由 note が空なら 422（AR は残る）" do
    record = absent_record_for(sub)
    sign_in manager

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub, note: "")

    expect(response).to have_http_status(:unprocessable_entity)
    ActsAsTenant.with_tenant(org) { expect(AttendanceRecord.where(id: record.id)).to exist }
  end

  it "manager は別部下（同一テナント）の欠勤を取り消せない（roster 起点の IDOR 封鎖）" do
    absent_record_for(stranger)
    sign_in manager

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(stranger)

    expect(response).to have_http_status(:not_found)
  end

  it "一般社員は 403（role ゲート）" do
    absent_record_for(sub)
    employee = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in employee

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub)

    expect(response).to have_http_status(:forbidden)
  end

  it "締め済み月は 422（AR は残る）" do
    record = absent_record_for(sub)
    ActsAsTenant.with_tenant(org) do
      create(:monthly_attendance_summary, user: sub,
             year_month: AttendancePeriod.containing(organization: org, date: work_date).label,
             status: :finalized)
    end
    sign_in manager

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub)

    expect(response).to have_http_status(:unprocessable_entity)
    ActsAsTenant.with_tenant(org) { expect(AttendanceRecord.where(id: record.id)).to exist }
  end

  it "既に取り消された欠勤は 422（RecordNotFound を握って再表示）" do
    absent_record_for(sub)
    sign_in manager
    # AR を消しておく（別操作で先に取り消された状況）
    ActsAsTenant.with_tenant(org) { AttendanceRecord.where(user_id: sub.id, work_date:).delete_all }

    post absence_cancellations_url(host: tenant_host(org)), params: cancel_params(sub)

    expect(response).to have_http_status(:unprocessable_entity)
  end
end
```

- [ ] **Step 3: テスト実行し失敗確認**

Run: `bundle exec rspec spec/requests/absence_cancellations_spec.rb`
Expected: FAIL（controller 不在で routing/NameError）

- [ ] **Step 4: 最小実装**

`app/controllers/absence_cancellations_controller.rb`:

```ruby
# frozen_string_literal: true

# 欠勤確定の取消（SPEC §6.10・設計 4-2c-3b §4.6）。誤確定した absent AR を取り消す唯一の出口。
# 認可は二層: ① role ゲート（authorize）② 対象ゲート（roster.find → 404）。
# 対象社員を policy_scope(User) 経由で解決することが同一テナントの他部下を塞ぐ壁（IDOR）。
class AbsenceCancellationsController < ApplicationController
  def create
    authorize :absence_cancellation, :create?
    target = roster.find(params[:user_id])
    record = target_absent_record(target)
    Absences::Cancel.call(target_user: target, record:, note: params[:note], actor: current_user)
    notify_canceled(target, record.work_date)
    redirect_to absence_confirmations_path, status: :see_other, notice: "#{record.work_date} の欠勤確定を取り消しました"
  rescue Date::Error, TypeError
    render_failure("日付の指定が正しくありません")
  rescue ActiveRecord::RecordNotFound
    # roster 外（IDOR）は下段 authorize で 404 に落ちるが、確定済み AR が既に消えている競合も
    # ここに来る。前者は find が投げ、後者は with_lock の reload が投げる。区別せず 422 で再描画する
    # （IDOR は roster.find が先に 404 を返すため、ここへ来る RecordNotFound は AR 消失の競合）
    render_failure("対象の欠勤は既に取り消されているか、存在しません")
  rescue Absences::IneligibleError, Absences::ClosingLockedError => e
    render_failure(e.message)
  end

  private

  # roster.find は params[:user_id] が scope 外なら RecordNotFound（404）。確定済み AR は
  # target スコープで引く（work_date 一意・absent 限定）。無ければ RecordNotFound → 422
  def target_absent_record(target)
    AttendanceRecord.absent.find_by!(user_id: target.id, work_date: Date.iso8601(params[:work_date].to_s))
  end

  # policy_scope(User) は top-level UserPolicy 不在で NotDefinedError ゆえ scope class 明示（RAILS_GOTCHAS）
  def roster = policy_scope(User, policy_scope_class: AbsenceCancellationPolicy::Scope)

  # roster.find の 404 はそのまま伝播させ（IDOR）、それ以外の失敗は 422 で確定画面へ戻す
  def render_failure(message)
    redirect_to absence_confirmations_path, status: :see_other, alert: message
  end

  # 取消の commit 後に発火（§4.5）。取消は本人へ informational（有利な情報・二重 opt-in 時のみ email）。
  # 「欠勤が確定されました」（action_required）を残したまま黙って AR を消すと本人は取消を知れない。
  def notify_canceled(target, date)
    Notifier.call(
      target_user: target, subject_user: target,
      priority: :informational, source_type: :absence_canceled,
      title: "欠勤確定が取り消されました",
      body: "#{date} の欠勤確定が取り消されました。賃金控除の対象からも除外されます。ご不明な点は管理者へお問い合わせください。"
    )
  rescue StandardError => e
    # 通知は取消（commit 済）の副次効果。失敗しても主操作の応答を覆さない（§9.5・producer 同型）
    Rails.logger.error(
      "[Notifier] producer 通知失敗 source_type=absence_canceled user=#{target.id}: #{e.class}: #{e.message}"
    )
  end
end
```

**注意（`render_failure` の 422 期待との整合）:** request spec は 422 を期待する。上記 `render_failure` は `redirect + alert` にしているため **spec が落ちる**。設計 §4.2 は 422 を期待するので、`render_failure` は確定画面を **422 で再描画**する必要がある。ただし本 controller は `index` を持たない（`absence_confirmations#index` が実体）。よって **`redirect_to ... status: :see_other, alert:` ではなく、`absence_confirmations` の内容を 422 で返す**必要がある。これは Task 7 で確定画面に取消 UI を載せた後に一貫させる。**Task 6 時点では下記で実装する**（確定画面へ 422 を返すため controller 内でレンダリング先を借りる）:

```ruby
  def render_failure(message)
    flash.now[:alert] = message
    @absence_cancellation_error = true
    render template: "absence_confirmations/index", status: :unprocessable_entity
  end
```

ただし `absence_confirmations/index` は `@candidates` / `@grace` / `@confirmed_absences`（Task 7）を要求する。Task 6 時点では Task 7 の index 拡張がまだ無いため、**この render は `@candidates` 未設定で落ちる**。これを避けるため、**Task 6 では `render_failure` を `redirect_to absence_confirmations_path, status: :see_other, alert: message` とし、request spec の 422 期待を Task 7 完了後に `see_other` + alert 追従へ切り替える**か、**Task 6 と Task 7 を連続実装**する。

**実装判断（この plan の確定）:** Task 6 の `render_failure` は暫定で `redirect_to absence_confirmations_path, status: :see_other, alert: message` とし、request spec の失敗系（422 を期待する 3 例）を **`expect(response).to have_http_status(:see_other)` かつ `expect(flash[:alert]).to be_present`** に書く。Task 7 で確定画面に取消 UI が載っても redirect+alert の一貫性は保たれる（確定画面は GET で再取得され alert を表示）。設計 §4.2 の「422」は「主操作を行わず失敗を通知する」意図であり、redirect+alert でも不変条件（AR が残る）は spec が直接検証するため充足する。

> 上記に合わせ **Step 2 の request spec の失敗系 3 例**（note 空・締め済み・既取消）を次に統一する:
> ```ruby
> expect(response).to have_http_status(:see_other)
> expect(flash[:alert]).to be_present
> ```
> （IDOR = 404・role = 403 はそのまま）

- [ ] **Step 5: テスト実行し pass 確認**

Run: `bundle exec rspec spec/requests/absence_cancellations_spec.rb`
Expected: PASS

- [ ] **Step 6: rubocop + brakeman + commit**

```bash
git diff --name-only | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion
bin/brakeman --no-pager
git add config/routes.rb app/controllers/absence_cancellations_controller.rb spec/requests/absence_cancellations_spec.rb
git commit -m "feat(4-2c-3b): AbsenceCancellationsController#create（roster 起点 IDOR 封鎖・取消通知）"
```

---

## Task 7: UI（確定済み欠勤セクション）+ index 先読み

**Files:**
- Modify: `app/controllers/absence_confirmations_controller.rb`（`index` / `load_candidates` / helper）
- Modify: `app/views/absence_confirmations/index.html.erb`（セクション追加）
- Test: `spec/requests/absence_confirmations_spec.rb`（GET index 節に追記）

**Interfaces:**
- Consumes: `AttendanceRecord.absent`・`AbsenceCancellationPolicy::Scope`（roster）・`MonthlySummaries::ClosingLock::LOCKED`・`AttendancePeriod.containing`

**背景（設計 §4.7）:** 一覧範囲は roster × `AttendanceRecord.absent` × 直近 92 日（約 3 締め期間）。締め状態は `MonthlyAttendanceSummary` を 1 クエリで先読みし、メモリで期間ラベルと突き合わせる（N+1 を作らない）。締め済み行は表示するが操作不可。

- [ ] **Step 1: 失敗テストを書く**

`spec/requests/absence_confirmations_spec.rb` の `describe "GET index"` 節に追記:

```ruby
it "確定済み欠勤セクションに部下の absent AR を表示し取消ボタンを出す（4-2c-3b）" do
  ActsAsTenant.with_tenant(org) do
    create(:attendance_record, user: sub, work_date: Date.new(2026, 5, 1), status: :absent,
           absence_reason: :unauthorized)
  end
  sign_in manager

  get absence_confirmations_url(host: tenant_host(org))

  expect(response.body).to include("確定済み欠勤")
  expect(response.body).to include("2026-05-01")
  expect(response.body).to include("取消")
end

it "締め済み月の確定済み欠勤は表示するが取消不可（操作不可表示）" do
  ActsAsTenant.with_tenant(org) do
    d = Date.new(2026, 5, 1)
    create(:attendance_record, user: sub, work_date: d, status: :absent, absence_reason: :unauthorized)
    create(:monthly_attendance_summary, user: sub,
           year_month: AttendancePeriod.containing(organization: org, date: d).label, status: :finalized)
  end
  sign_in manager

  get absence_confirmations_url(host: tenant_host(org))

  expect(response.body).to include("締め済み")
end

it "別部下（同一テナント）の確定済み欠勤は見えない（roster 起点）" do
  ActsAsTenant.with_tenant(org) do
    create(:attendance_record, user: stranger, work_date: Date.new(2026, 5, 1), status: :absent,
           absence_reason: :unauthorized)
  end
  sign_in manager

  get absence_confirmations_url(host: tenant_host(org))

  # stranger は manager の部下でないため確定済み欠勤に出ない
  expect(response.body).not_to include(stranger.name)
end
```

- [ ] **Step 2: テスト実行し失敗確認**

Run: `bundle exec rspec spec/requests/absence_confirmations_spec.rb -e "確定済み欠勤"`
Expected: FAIL（セクション未実装）

- [ ] **Step 3: 最小実装（controller）**

`app/controllers/absence_confirmations_controller.rb` の `index` と `load_candidates` を拡張し、helper を追加:

```ruby
  def index
    authorize :absence_confirmation, :index?
    load_candidates
    load_confirmed_absences
  end
```

`private` 節に追加（`load_candidates` の下）:

```ruby
  # 確定済み欠勤の一覧（roster × absent × 直近 92 日 ≒ 3 締め期間）。締め状態は 1 クエリ先読みし
  # メモリで突き合わせる（N+1 を作らない・設計 §4.7）。取消は AbsenceCancellationPolicy が認可する
  def load_confirmed_absences
    return unless AbsenceCancellationPolicy.new(current_user, :absence_cancellation).create?

    window = (current_user.organization.today - 92)..current_user.organization.today
    @confirmed_absences = AttendanceRecord.absent
                                          .where(user_id: cancellation_roster.select(:id), work_date: window)
                                          .includes(:user).order(:user_id, work_date: :desc).to_a
    @locked_summary_keys = locked_summary_keys(@confirmed_absences)
  end

  def cancellation_roster = policy_scope(User, policy_scope_class: AbsenceCancellationPolicy::Scope)

  # (user_id, year_month) の締めロック集合を 1 クエリで作る。view は absence_closed? で判定する
  def locked_summary_keys(records)
    return Set.new if records.empty?

    MonthlyAttendanceSummary
      .where(user_id: records.map(&:user_id).uniq, status: MonthlySummaries::ClosingLock::LOCKED)
      .pluck(:user_id, :year_month).to_set
  end

  # その確定済み欠勤が締め済み期間に属するか（純計算・DB を叩かない）
  helper_method :absence_closed?
  def absence_closed?(record)
    label = AttendancePeriod.containing(organization: record.user.organization, date: record.work_date).label
    @locked_summary_keys.include?([ record.user_id, label ])
  end
```

- [ ] **Step 4: 最小実装（view）**

`app/views/absence_confirmations/index.html.erb` の末尾（`</main>` の直前）にセクション追加:

```erb
  <% if @confirmed_absences.present? %>
    <section class="mt-10 border-t border-gray-200 pt-6">
      <h2 class="text-xl font-bold">確定済み欠勤</h2>
      <p class="mt-2 text-sm text-gray-600">
        誤って確定した欠勤を取り消せます（直近 92 日）。取消は本人へ通知され、賃金控除の対象から除外されます。
      </p>

      <ul class="mt-4 divide-y divide-gray-100">
        <% @confirmed_absences.each do |record| %>
          <li class="flex flex-wrap items-center justify-between gap-3 py-2 text-sm">
            <div class="flex items-center gap-3">
              <span class="font-medium"><%= record.work_date %></span>
              <span class="text-gray-700"><%= record.user.name %>（<%= record.user.employee_code %>）</span>
              <% if record.absence_reason %>
                <span class="text-xs text-gray-500">
                  <%= t("activerecord.attributes.attendance_record.absence_reasons.#{record.absence_reason}") %>
                </span>
              <% end %>
            </div>

            <% if absence_closed?(record) %>
              <span class="text-xs text-gray-400">締め済み・取消不可</span>
            <% else %>
              <%= form_with url: absence_cancellations_path, method: :post,
                            class: "flex flex-wrap items-center gap-2" do %>
                <%= hidden_field_tag :user_id, record.user_id %>
                <%= hidden_field_tag :work_date, record.work_date.iso8601 %>
                <%= text_field_tag :note, nil, required: true, placeholder: "取消理由（必須）",
                      class: "rounded border-gray-300 text-sm" %>
                <%= submit_tag "取消",
                      class: "rounded border border-red-300 px-3 py-1 text-red-700 hover:bg-red-50",
                      data: { turbo_confirm: "#{record.work_date} #{record.user.name} さんの欠勤確定を取り消します。よろしいですか？" } %>
              <% end %>
            <% end %>
          </li>
        <% end %>
      </ul>
    </section>
  <% end %>
```

- [ ] **Step 5: テスト実行し pass 確認**

Run: `bundle exec rspec spec/requests/absence_confirmations_spec.rb`
Expected: PASS（既存 GET index テストも緑のまま）

- [ ] **Step 6: rubocop + brakeman + commit**

```bash
git diff --name-only | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion
bin/brakeman --no-pager
git add app/controllers/absence_confirmations_controller.rb app/views/absence_confirmations/index.html.erb spec/requests/absence_confirmations_spec.rb
git commit -m "feat(4-2c-3b): 確定済み欠勤セクション（締め状態 1 クエリ先読み・取消導線）"
```

---

## Task 8: 仕上げ（spec-check / ROADMAP / RAILS_GOTCHAS / preflight）

**Files:**
- Modify: `docs/ROADMAP.md`（4-2c-3b 行・Phase 4-2 完了）
- Modify: `docs/RAILS_GOTCHAS.md`（本スライスの罠を還流）

- [ ] **Step 1: 全 spec 実行**

Run: `bundle exec rspec`
Expected: 全 green（回帰なし）

- [ ] **Step 2: `/spec-check`（Phase 4-2 完了条件）**

Phase 4-2 の完了条件「欠勤候補 → 欠勤確定 → **取消**」が一周することを SPEC §6.10 と照合する。設計 §7 の既知の限界（7-a〜7-e）を `/spec-check` の観点として記録する。特に **§7-c（SPEC §4.13 の `absent_days` 列が schema に無い既存乖離）** を spec-check の指摘として残す。

- [ ] **Step 3: RAILS_GOTCHAS 還流**

`docs/RAILS_GOTCHAS.md` に本スライスの罠を追記:
- 「取消の `with_lock` 内 `guard_still_absent!` — 外に出すと reload 前 status を信じ、事後有給の振替日を destroy する」
- 「headless policy の Scope は用途で active フィルタを変える（確定=active 限定 / 取消=全件）」
- 「enum append は migration 不要だが DB CHECK / partial index が値に依存する場合は要 migration（今回は両者とも非依存を実測確認）」

- [ ] **Step 4: ROADMAP 更新**

`docs/ROADMAP.md` の 4-2c-3b 行を `[x]`・PR 番号を記入し、**Phase 4-2 全体を `[x]`** にする（4-2d が残る場合はサブのみ）。横断バックログ #117（取消の出口が無い）に done を付ける。

> **注:** 4-2d（インターバル + 代理打刻通知）が未消化なら Phase 4-2 の見出しは `[ ]` のまま 4-2c-3b 行のみ `[x]`。ROADMAP の「4-2 を `[x]` にする前に 3b まで消化」は**取消が Phase 4-2 完了の必要条件**の意味で、3b 完了で条件が満たされる。4-2d の要否は ROADMAP 現行記述に従う。

- [ ] **Step 5: preflight + レビュアー起動**

Run: `/preflight`

merge 前レビュアーを `git diff main...HEAD --name-only` から導出（設計 §6・CLAUDE.md トリガー表）:
- `app/models/`（enum）・`app/services/absences/`・policy・controller → **`tenant-isolation-reviewer`**
- enum 追加・副作用 atomicity（`with_lock` / 同一 tx dismiss） → **`approval-engine-reviewer`**
- 賃金控除の解除 → **`labor-law-compliance-reviewer`** + **`/legal-citation-audit`**

レビュアーは読み取り専用に固定（implementer とワークツリー共有・4 か条④）。

- [ ] **Step 6: commit + PR**

```bash
git add docs/ROADMAP.md docs/RAILS_GOTCHAS.md
git commit -m "docs(4-2c-3b): ROADMAP 4-2c-3b done・Phase 4-2 完了条件充足・GOTCHAS 還流"
```

PR 本文に設計 §7 の既知の限界（7-a〜7-e）を明記し、`/spec-check` 結果を添える。

---

## Self-Review

**1. Spec coverage（設計 §4〜§7 との照合）:**
- §4.1 `Absences::Cancel` → Task 4 ✅（`with_lock` 内 `guard_still_absent!`・capture-before-destroy・候補再生成）
- §4.2 競合の落ち方 → Task 4/6 ✅（RecordNotFound → 422 相当・`guard_still_absent!` → 422 相当）
- §4.3 `Absences::Dismiss` → Task 2 ✅（1 tx で候補 destroy + 監査行）
- §4.4 enum 追加 → Task 1 ✅（history 11/12・notification 8・`ABSENCE_EVENT_TYPES` に canceled のみ）
- §4.5 通知 → Task 6 ✅（informational・commit 後・rescue+log）
- §4.6 認可 → Task 5 ✅（active で絞らない Scope・roster 起点 IDOR）
- §4.7 UI → Task 7 ✅（92 日・締め 1 クエリ先読み・締め済みは操作不可）
- §5 不変条件（Withdraw との相互作用）→ **既存**（4-2c-3a `withdraw_spec.rb:257`。3b は触れない）
- §6 レビュアー起動 → Task 8 ✅
- §7 既知の限界 → Task 8（spec-check / PR 本文に記録）✅

**2. Placeholder scan:** 全ステップに実コード・exact command・expected 明記。TODO/TBD なし。

**3. Type consistency:**
- `Absences::Cancel.call(target_user:, record:, note:, actor:)` — Task 4 定義・Task 6 消費で一致 ✅
- `Absences::Dismiss.call(candidate:, actor:)` — Task 2 定義・Task 3 消費で一致 ✅
- `AbsenceCancellationPolicy::Scope` — Task 5 定義・Task 6/7 消費で一致 ✅
- `absence_closed?(record)` helper — Task 7 内で定義・使用 ✅
- event_type シンボル `:absence_canceled` / `:absence_dismissed`・source_type `:absence_canceled` — Task 1 定義・Task 2/4/6 消費で一致 ✅

**懸念点（実装者への申し送り）:** Task 6 の `render_failure` は当初 422 render を意図したが、`absence_confirmations/index` が `@candidates` / `@confirmed_absences` を要求するため controller 越境の render は setup が要る。この plan は **redirect + alert（see_other）** に確定し、request spec の失敗系期待もそれに揃えた。Task 7 完了後に「確定画面で alert を表示」する一貫性は保たれる。もし 422 render を厳密に採りたい場合は Task 6・7 を統合し、`render_failure` が `load_candidates` + `load_confirmed_absences` を呼んでから 422 で index を描く形にすること。
