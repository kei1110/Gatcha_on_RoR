# Phase 2-5 撤回フロー Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 承認済の LeaveRequest / ClockChangeRequest を申請者が撤回申請 → 固定 2 段承認 → 副作用を逆操作で巻き戻す（残高減算・記録復元・履歴）まで一周させ、撤回却下で原承認へ無副作用復帰させる。

**Architecture:** 承認エンジン（`Approvals::Start/Approve/Reject`）を「現状態に応じて承認/撤回のイベントを撃ち分ける」よう汎用化。撤回 state/event は新 concern `Withdrawable`（`include Approvable` + aasm 再オープン）に隔離し HWR を構造的に除外。撤回承認世代の assignment は `ApprovalAssignment.purpose` enum で分離。逆操作は `ApplyApproval` の鏡像サービス 2 本。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / AASM / acts_as_tenant / Pundit / ViewComponent / RSpec + FactoryBot。

**設計典拠:** `docs/superpowers/specs/2026-06-19-phase2-5-withdrawal-flow-design.md`（多視点レビュー反映済・本計画は同設計の D1–D7 + R1–R9 を実装に落とす）。

## Global Constraints

- **テナント安全（§3.6）**: app/models に触れたら `acts_as_tenant` 維持。逆操作サービスは `ActsAsTenant.with_tenant(host.organization)` でラップ（将来ジョブ化に fail-closed）。複合 index は `organization_id` 先頭。
- **schema.rb は手編集禁止**（migration 経由）。`bundle exec rubocop` はファイル明示時 `--force-exclusion` 必須。commit identity は kei1110 <eoh2145@gmail.com>（local config 済）。
- **承認状態は AASM イベント経由のみ更新**（§7.3・`update_column`/`update_all` 禁止）。
- **enum 整数は append-only/凍結**（リオーダ禁止）: approval_status `applying:0 approved:1 rejected:2 canceled:3 withdrawal_requested:4 withdrawn:5`。attendance_histories.event_type 既存 0–8 + `clock_change_withdrawn:9`。purpose `approval:0 withdrawal:1`。
- **副作用 atomicity（§13.6）**: 逆操作は `Approve` の `with_lock` 内・同一 tx で走り内側 rescue せず raise 伝播。`reject_withdrawal` には副作用を付けない。
- **ステップ完了ごとに即コミット**。探索で触った不要編集は revert。app/ に触れたら `bin/brakeman --no-pager` も。
- 検証: `bundle exec rspec` / `bundle exec rubocop --force-exclusion <files>` / `bin/brakeman --no-pager`。

---

## Task 1: ApprovalAssignment purpose 列 + uniqueness 追補（R1）

承認世代分離の土台。撤回世代の position 1/2 を生成可能にする最重要修正。

**Files:**
- Create: `db/migrate/<ts>_add_purpose_to_approval_assignments.rb`
- Create: `db/migrate/<ts>_add_withdrawal_reason_to_leave_requests.rb`
- Modify: `app/models/approval_assignment.rb`（enum 追加・uniqueness scope に :purpose）
- Test: `spec/models/approval_assignment_spec.rb`（既存に purpose ケース追加）

**Interfaces:**
- Produces: `ApprovalAssignment#purpose`（enum・prefix `purpose_` → `purpose_approval?`/`purpose_withdrawal?`）。DB index `index_approval_assignments_unique_stage` が `[organization_id, approvable_type, approvable_id, purpose, position]` unique。

- [ ] **Step 1: migration 2 本を生成**

Run:
```bash
bin/rails g migration AddPurposeToApprovalAssignments
bin/rails g migration AddWithdrawalReasonToLeaveRequests
```

- [ ] **Step 2: purpose migration を記述**

`db/migrate/<ts>_add_purpose_to_approval_assignments.rb`:
```ruby
# frozen_string_literal: true

class AddPurposeToApprovalAssignments < ActiveRecord::Migration[8.1]
  def change
    add_column :approval_assignments, :purpose, :integer, null: false, default: 0  # approval:0 / withdrawal:1

    remove_index :approval_assignments, name: "index_approval_assignments_unique_stage"
    add_index :approval_assignments,
              %i[organization_id approvable_type approvable_id purpose position],
              unique: true, name: "index_approval_assignments_unique_stage"
  end
end
```

`db/migrate/<ts>_add_withdrawal_reason_to_leave_requests.rb`:
```ruby
# frozen_string_literal: true

class AddWithdrawalReasonToLeaveRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :leave_requests, :withdrawal_reason, :text
  end
end
```

- [ ] **Step 3: migrate 実行**

Run: `bin/rails db:migrate`
Expected: schema.rb に `purpose` 列・新 unique index・`leave_requests.withdrawal_reason` が反映（手編集しない）。

- [ ] **Step 4: ApprovalAssignment に失敗するテストを書く**

`spec/models/approval_assignment_spec.rb` の既存 describe 群に追加:
```ruby
describe "purpose 世代分離（2-5）" do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:host) { ApprovalTestRecord.create!(requester: create(:user, organization: org)) }
  let(:approver) { create(:user, :manager_role, organization: org) }

  it "同一 approvable に approval/withdrawal 世代で同 position を共存できる" do
    a = host.approval_assignments.create!(organization: org, approver:, position: 1, purpose: :approval, decision: :pending)
    b = host.approval_assignments.build(organization: org, approver:, position: 1, purpose: :withdrawal, decision: :pending)
    expect(b).to be_valid
    expect { b.save! }.not_to raise_error
    expect(a.purpose_approval?).to be true
  end

  it "同一 purpose 内では position 重複を拒否（モデル検証）" do
    host.approval_assignments.create!(organization: org, approver:, position: 1, purpose: :withdrawal, decision: :pending)
    dup = host.approval_assignments.build(organization: org, approver:, position: 1, purpose: :withdrawal, decision: :pending)
    expect(dup).not_to be_valid
    expect(dup.errors[:position]).to be_present
  end
end
```

- [ ] **Step 5: テストが失敗するのを確認**

Run: `bundle exec rspec spec/models/approval_assignment_spec.rb -e "purpose 世代分離"`
Expected: FAIL（`purpose` enum 未定義 or uniqueness が purpose 非対応で 1 件目が衝突）。

- [ ] **Step 6: ApprovalAssignment を修正**

`app/models/approval_assignment.rb` の enum 群に追加し、position uniqueness の scope を差し替え:
```ruby
  enum :decision, { pending: 0, approved: 1, rejected: 2 }, validate: true
  enum :purpose, { approval: 0, withdrawal: 1 }, validate: true, prefix: :purpose

  validates :position, inclusion: { in: [ 1, 2 ] }
  validates :position, uniqueness: { scope: [ :organization_id, :approvable_type, :approvable_id, :purpose ] }
```

- [ ] **Step 7: テストが通るのを確認**

Run: `bundle exec rspec spec/models/approval_assignment_spec.rb`
Expected: PASS（既存テストも緑）。

- [ ] **Step 8: コミット**

```bash
git add db/migrate db/schema.rb app/models/approval_assignment.rb spec/models/approval_assignment_spec.rb
git commit -m "feat(2-5): ApprovalAssignment に purpose 列 + uniqueness 追補（撤回世代分離・R1）"
```

---

## Task 2: Approvable enum 0–5 + purpose スコープ導出 + awaiting_decision?

基底 concern を拡張。撤回 state/event は持たせず（Task 3）、導出のみ purpose 対応にする。HWR/ApprovalTestRecord（Approvable-only）も enum 0–5 を持つが到達不能。

**Files:**
- Modify: `app/models/concerns/approvable.rb`
- Test: `spec/models/concerns/approvable_spec.rb`（enum 凍結を 0–5 へ更新）

**Interfaces:**
- Produces: `Approvable#active_purpose`（`:withdrawal` if `withdrawal_requested?` else `:approval`）・`#awaiting_decision?`・`#apply_withdrawal_effects!(acting_user:)`（no-op）。`current_approval_position`/`all_stages_approved?`/`single_stage?`/`pending_approver` が `purpose: active_purpose` でスコープ。

- [ ] **Step 1: 既存 enum 凍結テストを 0–5 へ更新（失敗させる）**

`spec/models/concerns/approvable_spec.rb` の該当 it を書き換え:
```ruby
  describe "enum 整数マッピング（凍結）" do
    it "0–5 完全一致（4/5 は 2-5 撤回・予約を宣言）" do
      expect(ApprovalTestRecord.approval_statuses).to eq(
        "applying" => 0, "approved" => 1, "rejected" => 2, "canceled" => 3,
        "withdrawal_requested" => 4, "withdrawn" => 5
      )
    end
  end

  describe "active_purpose / awaiting_decision?（2-5）" do
    it "applying は approval 世代・awaiting_decision? true" do
      expect(host.active_purpose).to eq(:approval)
      expect(host.awaiting_decision?).to be true
    end

    it "current_approval_position は active_purpose（approval）でスコープ" do
      host.approval_assignments.create!(organization: org, approver: approver1, position: 1, purpose: :approval, decision: :pending)
      expect(host.current_approval_position).to eq(1)
    end
  end
```

- [ ] **Step 2: テストが失敗するのを確認**

Run: `bundle exec rspec spec/models/concerns/approvable_spec.rb -e "enum 整数" -e "active_purpose"`
Expected: FAIL（enum はまだ 0–3・`active_purpose`/`awaiting_decision?` 未定義）。

- [ ] **Step 3: Approvable を拡張**

`app/models/concerns/approvable.rb` の `included do` 内 enum を 0–5 へ（base aasm の state/event は変更しない）:
```ruby
    # 整数 0–5 凍結。4=withdrawal_requested / 5=withdrawn は Withdrawable が状態化（§4.14 同型）。
    enum :approval_status, {
      applying: 0, approved: 1, rejected: 2, canceled: 3,
      withdrawal_requested: 4, withdrawn: 5
    }
```
`included do ... end` の外（concern のインスタンスメソッド群）に追加・既存の導出を purpose スコープへ:
```ruby
  # 現在アクティブな承認世代。withdrawal_requested? は enum 由来で全 host が応答（HWR は常に false）
  def active_purpose = withdrawal_requested? ? :withdrawal : :approval

  def current_approval_position
    approval_assignments.where(purpose: active_purpose, decision: :pending).minimum(:position)
  end

  def all_stages_approved?
    scope = approval_assignments.where(purpose: active_purpose)
    scope.exists? && !scope.where.not(decision: :approved).exists?
  end

  def single_stage? = approval_assignments.where(purpose: active_purpose).count == 1

  def pending_approver
    position = current_approval_position
    position && approval_assignments.find_by(purpose: active_purpose, position:)&.approver
  end

  # 承認・撤回承認の両方を「決定待ち」として扱う（Policy/エンジン guard 一般化）
  def awaiting_decision? = applying? || withdrawal_requested?

  # 撤回副作用 hook（既定 no-op・Withdrawable host が override）
  def apply_withdrawal_effects!(acting_user:) = nil
```
（既存の `current_approval_position`/`all_stages_approved?`/`single_stage?`/`pending_approver` 定義は上記で置換する。）

- [ ] **Step 4: 概念回帰 — 既存エンジンが緑か確認**

Run: `bundle exec rspec spec/models/concerns/approvable_spec.rb spec/services/approvals`
Expected: PASS（applying 経路は不変ゆえ既存 approve/reject/start spec も緑）。

- [ ] **Step 5: コミット**

```bash
git add app/models/concerns/approvable.rb spec/models/concerns/approvable_spec.rb
git commit -m "feat(2-5): Approvable に enum 0–5 + purpose スコープ導出 + awaiting_decision?"
```

---

## Task 3: Withdrawable concern（AASM 再オープン）+ LR/CCR 差し替え + HWR 隔離

撤回状態機械の中核。`respond_to?` 構造分離（D7）と whiny/enum 継承（R-whiny）を TDD で固定。

**Files:**
- Create: `app/models/concerns/withdrawable.rb`
- Modify: `app/models/leave_request.rb`（`include Approvable` → `include Withdrawable`）
- Modify: `app/models/clock_change_request.rb`（同上）
- Modify: `spec/support/approvable_test_model.rb`（`WithdrawalTestRecord` + テーブル追加）
- Create: `spec/models/concerns/withdrawable_spec.rb`

**Interfaces:**
- Produces: `Withdrawable` を include した host に AASM event `request_withdrawal`（approved→withdrawal_requested・guard `no_prior_withdrawal_round?`）/ `approve_withdrawal`（→withdrawn・guard `all_stages_approved?`）/ `reject_withdrawal`（→approved）。`#no_prior_withdrawal_round?`。`withdrawal_reason` 条件付き presence。

- [ ] **Step 1: テスト用 host を support に追加**

`spec/support/approvable_test_model.rb` に追記（既存 ApprovalTestRecord はそのまま）:
```ruby
# Withdrawable（撤回つき）検証用のテスト専用ホスト。
class WithdrawalTestRecord < ApplicationRecord
  acts_as_tenant(:organization)
  belongs_to :requester, class_name: "User"
  include Withdrawable
end
```
`before(:suite)` の中に追加:
```ruby
    conn.create_table(:withdrawal_test_records, if_not_exists: true) do |t|
      t.references :organization, null: false
      t.references :requester, null: false
      t.integer :approval_status, null: false, default: 0
      t.text :withdrawal_reason
      t.timestamps
    end
```

- [ ] **Step 2: withdrawable_spec を書く（失敗させる）**

`spec/models/concerns/withdrawable_spec.rb`:
```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Withdrawable do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:requester) { create(:user, organization: org) }
  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:host) { WithdrawalTestRecord.create!(requester:, approval_status: :approved) }

  def withdrawal_assignment(decision: :approved)
    host.approval_assignments.create!(organization: org, approver:, position: 1,
                                      purpose: :withdrawal, decision:, acted_at: (decision == :pending ? nil : Time.current))
  end

  describe "AASM 撤回遷移（§13.2）" do
    it "approved → request_withdrawal で withdrawal_requested・DB 整数 4（R-whiny ③）" do
      host.withdrawal_reason = "誤申請のため"
      host.request_withdrawal!
      expect(host.reload.approval_status).to eq("withdrawal_requested")
      expect(host).to be_withdrawal_requested
    end

    it "withdrawal_requested → approve_withdrawal（全段 approved）で withdrawn" do
      host.update!(approval_status: :withdrawal_requested, withdrawal_reason: "x")
      withdrawal_assignment(decision: :approved)
      expect(host.all_stages_approved?).to be true
      host.approve_withdrawal!
      expect(host).to be_withdrawn
    end

    it "withdrawal_requested → reject_withdrawal で approved 復帰" do
      host.update!(approval_status: :withdrawal_requested, withdrawal_reason: "x")
      host.reject_withdrawal!
      expect(host).to be_approved
    end

    it "withdrawal_requested では approve/reject が未定義＝InvalidTransition（§7.6 構造防御）" do
      host.update!(approval_status: :withdrawal_requested, withdrawal_reason: "x")
      expect { host.approve! }.to raise_error(AASM::InvalidTransition)
      expect { host.reject! }.to raise_error(AASM::InvalidTransition)
    end

    it "撤回世代が既にあれば再撤回不可（D6・no_prior_withdrawal_round? guard）" do
      withdrawal_assignment(decision: :rejected)
      host.update!(approval_status: :approved)
      expect { host.request_withdrawal! }.to raise_error(AASM::InvalidTransition)
    end
  end

  describe "whiny_persistence 継承（R-whiny ④）" do
    it "save 失敗時に false でなく例外を上げる" do
      host.update!(approval_status: :withdrawal_requested, withdrawal_reason: nil)  # presence 違反を仕込む
      # reject_withdrawal! は approved へ戻すが withdrawal_reason presence は withdrawal_requested? のみ ゆえ通る
      # ここでは presence 違反を保てる approve_withdrawal を使い save 失敗を誘発
      withdrawal_assignment(decision: :approved)
      host.withdrawal_reason = nil
      expect { host.approve_withdrawal! }.to raise_error(ActiveRecord::RecordInvalid).or raise_error(AASM::InvalidTransition)
    end
  end

  describe "withdrawal_reason presence（R-presence）" do
    it "withdrawal_requested では withdrawal_reason 必須" do
      host.approval_status = :withdrawal_requested
      host.withdrawal_reason = nil
      expect(host).not_to be_valid
      expect(host.errors[:withdrawal_reason]).to be_present
    end
  end

  describe "HWR 隔離（D7・R 回帰）" do
    it "HolidayWorkRequest は撤回イベントを獲得しない（respond_to? false）" do
      expect(HolidayWorkRequest.new.respond_to?(:request_withdrawal)).to be false
    end

    it "HolidayWorkRequest は states 0–3 のみで正常ロード（enum 0–5 許容）" do
      hwr = build(:holiday_work_request)
      expect(hwr).to be_applying
      expect(HolidayWorkRequest.approval_statuses.keys).to include("withdrawal_requested")  # enum は持つ
    end
  end
end
```

- [ ] **Step 3: テストが失敗するのを確認**

Run: `bundle exec rspec spec/models/concerns/withdrawable_spec.rb`
Expected: FAIL（`Withdrawable` 未定義・`WithdrawalTestRecord` 未ロード）。

- [ ] **Step 4: Withdrawable concern を実装**

`app/models/concerns/withdrawable.rb`:
```ruby
# frozen_string_literal: true

# 撤回フロー（SPEC §7.6・§13.2）を Approvable host に付与する。LR/CCR のみ include。
# HWR は撤回フローを持たない（§4.12/§13.3）ため本 concern を include しない＝撤回イベント非獲得（D7）。
# 実装注記: include Approvable により AS::Concern は Approvable の included（enum + 基底 aasm）を
# 先に評価し、その後 Withdrawable の included（aasm 再オープン）が同一機械へ撤回 state/event を足す。
module Withdrawable
  extend ActiveSupport::Concern
  include Approvable

  included do
    validates :withdrawal_reason, presence: true, if: :withdrawal_requested?

    aasm do  # 基底 Approvable の機械（enum: true, whiny_persistence: true）を再オープン
      state :withdrawal_requested
      state :withdrawn

      event :request_withdrawal do
        transitions from: :approved, to: :withdrawal_requested, guard: :no_prior_withdrawal_round?
      end
      event :approve_withdrawal do
        transitions from: :withdrawal_requested, to: :withdrawn, guard: :all_stages_approved?
      end
      event :reject_withdrawal do
        transitions from: :withdrawal_requested, to: :approved   # 副作用なし（§13.6）
      end
    end
  end

  # D6: 撤回世代の assignment が皆無か（再撤回防止）
  def no_prior_withdrawal_round? = !approval_assignments.where(purpose: :withdrawal).exists?
end
```

- [ ] **Step 5: LR/CCR の include を差し替え**

`app/models/leave_request.rb`: `include Approvable` を `include Withdrawable` に変更。
`app/models/clock_change_request.rb`: 同様に変更。
（他の行は変更しない。`withdrawal_reason` カラムは LR=Task1 で追加・CCR=既存。）

- [ ] **Step 6: テストが通るのを確認**

Run: `bundle exec rspec spec/models/concerns/withdrawable_spec.rb spec/models/leave_request_spec.rb spec/models/clock_change_request_spec.rb spec/models/holiday_work_request_spec.rb`
Expected: PASS（HWR 既存 spec も緑＝隔離成功）。

- [ ] **Step 7: コミット**

```bash
git add app/models/concerns/withdrawable.rb app/models/leave_request.rb app/models/clock_change_request.rb spec/support/approvable_test_model.rb spec/models/concerns/withdrawable_spec.rb
git commit -m "feat(2-5): Withdrawable concern（撤回 AASM）+ LR/CCR 差し替え + HWR 隔離（D7）"
```

---

## Task 4: エンジン汎用化（Start purpose / Approve・Reject 撃ち分け）

`Approvals::Start/Approve/Reject` を承認/撤回両用に。applying 経路は不変、withdrawal_requested 経路を追加。

**Files:**
- Modify: `app/services/approvals/start.rb`
- Modify: `app/services/approvals/approve.rb`
- Modify: `app/services/approvals/reject.rb`
- Test: `spec/services/approvals/approve_spec.rb` / `reject_spec.rb` / `start_spec.rb`（撤回ケース追加）

**Interfaces:**
- Consumes: `Withdrawable`（Task 3）の `approve_withdrawal`/`reject_withdrawal`、`Approvable#active_purpose`/`awaiting_decision?`/`apply_withdrawal_effects!`（Task 2）。
- Produces: `Approvals::Start.call(approvable, purpose: :approval)`。`Approvals::Approve`/`Reject` が host 状態で承認/撤回イベントを撃ち分け。

- [ ] **Step 1: Start に purpose ケースのテスト（失敗）**

`spec/services/approvals/start_spec.rb` に追加（既存 setup の org/host/approver を流用）:
```ruby
  describe "purpose: :withdrawal（2-5）" do
    it "withdrawal 世代の assignment を生成（approval 世代と共存）" do
      described_class.call(host)                                 # approval 世代
      described_class.call(host, purpose: :withdrawal)           # 撤回世代
      expect(host.approval_assignments.where(purpose: :approval)).to be_present
      expect(host.approval_assignments.where(purpose: :withdrawal)).to be_present
    end

    it "撤回世代が既存なら冪等（再生成しない）" do
      described_class.call(host, purpose: :withdrawal)
      expect { described_class.call(host, purpose: :withdrawal) }
        .not_to change { host.approval_assignments.where(purpose: :withdrawal).count }
    end
  end
```
（`host` が approval ルートを解決できるよう、start_spec 既存の requester/manager 設定に倣う。WithdrawalTestRecord でなく既存 ApprovalTestRecord で可＝Start は purpose を付けるだけ。）

- [ ] **Step 2: 失敗確認 → Start 実装**

Run: `bundle exec rspec spec/services/approvals/start_spec.rb -e "purpose"` → FAIL。

`app/services/approvals/start.rb`:
```ruby
    def self.call(approvable, purpose: :approval) = new(approvable, purpose:).call

    def initialize(approvable, purpose: :approval)
      @approvable = approvable
      @purpose = purpose
    end

    def call
      return @approvable if @approvable.approval_assignments.where(purpose: @purpose).exists?  # 冪等（purpose 毎）

      approvers = RouteResolver.call(requester: @approvable.requester)
      ApprovalAssignment.transaction do
        approvers.each_with_index do |approver, idx|
          @approvable.approval_assignments.create!(
            organization: @approvable.organization, approver:,
            position: idx + 1, purpose: @purpose, decision: :pending
          )
        end
      end
      @approvable
    end
```

Run: `bundle exec rspec spec/services/approvals/start_spec.rb` → PASS。

- [ ] **Step 3: Approve/Reject の撤回撃ち分けテスト（失敗）**

`spec/services/approvals/approve_spec.rb` に追加（撤回は Withdrawable host が要るので WithdrawalTestRecord を使う）:
```ruby
  describe "撤回承認の撃ち分け（2-5）" do
    let(:wh) { WithdrawalTestRecord.create!(requester:, approval_status: :withdrawal_requested, withdrawal_reason: "誤申請") }

    it "撤回世代を全段 approve すると withdrawn（approve_withdrawal を撃つ）" do
      wh.approval_assignments.create!(organization: org, approver: approver1, position: 1, purpose: :withdrawal, decision: :pending)
      described_class.call(approvable: wh, approver: approver1)
      expect(wh.reload).to be_withdrawn
    end
  end
```
`spec/services/approvals/reject_spec.rb` に追加:
```ruby
  describe "撤回却下の撃ち分け（2-5・副作用なし）" do
    let(:wh) { WithdrawalTestRecord.create!(requester:, approval_status: :withdrawal_requested, withdrawal_reason: "誤申請") }

    it "撤回世代を reject すると approved へ復帰（reject_withdrawal）" do
      wh.approval_assignments.create!(organization: org, approver: approver1, position: 1, purpose: :withdrawal, decision: :pending)
      described_class.call(approvable: wh, approver: approver1, comment: "却下理由")
      expect(wh.reload).to be_approved
    end
  end
```
（approve_spec/reject_spec の既存 `requester`/`approver1`/`org` let を流用。WithdrawalTestRecord は `apply_withdrawal_effects!` が Approvable 既定 no-op ゆえ副作用は走らない＝エンジン経路のみ検証。）

- [ ] **Step 4: 失敗確認 → Approve/Reject 実装**

Run: `bundle exec rspec spec/services/approvals/approve_spec.rb -e "撤回" spec/services/approvals/reject_spec.rb -e "撤回"` → FAIL。

`app/services/approvals/approve.rb` の `call` と `guard!`/`current_assignment!`:
```ruby
    def call
      @approvable.with_lock do
        guard!
        assignment = current_assignment!
        assignment.update!(decision: :approved, acted_at: Time.current, comment: @comment)
        finalize! if @approvable.all_stages_approved?
      end
      @approvable
    end

    private

    def guard!
      raise AASM::InvalidTransition.new(@approvable, :approve, :default) unless @approvable.awaiting_decision?
      raise ProxyNotSupported unless @acting_user.id == @approver.id

      return unless SelfApproval.violated?(
        requester_id: @approvable.requester_id, approver_id: @approver.id, acting_user_id: @acting_user.id
      )
      raise SelfApprovalError
    end

    # host 状態で確定イベント + 副作用を撃ち分け（§13.6）。判定は遷移前に行う
    def finalize!
      if @approvable.withdrawal_requested?
        @approvable.approve_withdrawal!
        @approvable.apply_withdrawal_effects!(acting_user: @acting_user)
      else
        @approvable.approve!
        @approvable.apply_approval_effects!(acting_user: @acting_user)
      end
    end

    def current_assignment!
      position = @approvable.current_approval_position
      assignment = @approvable.approval_assignments.find_by(
        purpose: @approvable.active_purpose, position:, decision: :pending
      )
      raise NotCurrentApprover unless assignment && assignment.approver_id == @approver.id
      assignment
    end
```

`app/services/approvals/reject.rb` の `call`・`guard!`・`current_assignment!`:
```ruby
    def call
      raise ArgumentError, "却下理由が必要です" if @comment.blank?

      @approvable.with_lock do
        guard!
        assignment = current_assignment!
        assignment.update!(decision: :rejected, acted_at: Time.current, comment: @comment)
        @approvable.withdrawal_requested? ? @approvable.reject_withdrawal! : @approvable.reject!
      end
      @approvable
    end

    private

    def guard!
      raise AASM::InvalidTransition.new(@approvable, :reject, :default) unless @approvable.awaiting_decision?
      raise ProxyNotSupported unless @acting_user.id == @approver.id

      return unless SelfApproval.violated?(
        requester_id: @approvable.requester_id, approver_id: @approver.id, acting_user_id: @acting_user.id
      )
      raise SelfApprovalError
    end

    def current_assignment!
      position = @approvable.current_approval_position
      assignment = @approvable.approval_assignments.find_by(
        purpose: @approvable.active_purpose, position:, decision: :pending
      )
      raise NotCurrentApprover unless assignment && assignment.approver_id == @approver.id
      assignment
    end
```

- [ ] **Step 5: 全エンジン spec 緑を確認**

Run: `bundle exec rspec spec/services/approvals`
Expected: PASS（applying 経路の既存 + 撤回ケース）。

- [ ] **Step 6: コミット**

```bash
git add app/services/approvals/start.rb app/services/approvals/approve.rb app/services/approvals/reject.rb spec/services/approvals
git commit -m "feat(2-5): 承認エンジンを承認/撤回両用に汎用化（Start purpose・finalize 撃ち分け）"
```

---

## Task 5: Approvals::RequestWithdrawal サービス

撤回申請の起票。本人性・reason・再撤回ガードを gate し、撤回世代 assignment を生成。

**Files:**
- Modify: `app/services/approvals.rb`（`NotRequester` エラー追加）
- Create: `app/services/approvals/request_withdrawal.rb`
- Create: `spec/services/approvals/request_withdrawal_spec.rb`

**Interfaces:**
- Consumes: `Withdrawable#request_withdrawal!`、`Approvals::Start.call(.., purpose: :withdrawal)`。
- Produces: `Approvals::RequestWithdrawal.call(approvable:, requester:, reason:)` → host を withdrawal_requested に遷移し撤回世代生成。`Approvals::NotRequester < Approvals::Error`。

- [ ] **Step 1: NotRequester エラーを追加**

`app/services/approvals.rb` のエラー群に追加:
```ruby
  class NotRequester < Error; end         # 撤回申請者が元 requester でない（§7.6）
```

- [ ] **Step 2: spec を書く（失敗）**

`spec/services/approvals/request_withdrawal_spec.rb`:
```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::RequestWithdrawal do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:hr)   { create(:user, :hr_admin, organization: org) }
  let(:boss) { create(:user, :manager_role, manager: hr, organization: org) }
  let(:requester) { create(:user, manager: boss, organization: org) }
  let(:host) { WithdrawalTestRecord.create!(requester:, approval_status: :approved) }

  it "approved を withdrawal_requested にし撤回世代を生成" do
    described_class.call(approvable: host, requester:, reason: "誤申請のため")
    expect(host.reload).to be_withdrawal_requested
    expect(host.withdrawal_reason).to eq("誤申請のため")
    expect(host.approval_assignments.where(purpose: :withdrawal)).to be_present
  end

  it "reason が空なら ArgumentError（二層の片側）" do
    expect { described_class.call(approvable: host, requester:, reason: " ") }
      .to raise_error(ArgumentError)
    expect(host.reload).to be_approved
  end

  it "申請者本人でなければ NotRequester" do
    other = create(:user, organization: org)
    expect { described_class.call(approvable: host, requester: other, reason: "x") }
      .to raise_error(Approvals::NotRequester)
  end

  it "撤回世代が既にあれば InvalidTransition（再撤回不可・D6）" do
    host.approval_assignments.create!(organization: org, approver: boss, position: 1, purpose: :withdrawal, decision: :rejected, acted_at: Time.current)
    expect { described_class.call(approvable: host, requester:, reason: "x") }
      .to raise_error(AASM::InvalidTransition)
  end
end
```

- [ ] **Step 3: 失敗確認 → 実装**

Run: `bundle exec rspec spec/services/approvals/request_withdrawal_spec.rb` → FAIL。

`app/services/approvals/request_withdrawal.rb`:
```ruby
# frozen_string_literal: true

module Approvals
  # 撤回申請の起票（SPEC §7.6）。本人性 + 状態 + 再撤回ガードを gate し撤回世代を生成。
  # with_lock 内・request_withdrawal! の guard（approved? + no_prior_withdrawal_round?）が
  # AASM::InvalidTransition を構造的に発火（terminal/再撤回防御）。
  class RequestWithdrawal
    def self.call(approvable:, requester:, reason:) = new(approvable:, requester:, reason:).call

    def initialize(approvable:, requester:, reason:)
      @approvable = approvable
      @requester = requester
      @reason = reason
    end

    def call
      raise ArgumentError, "撤回理由が必要です" if @reason.blank?

      @approvable.with_lock do
        raise NotRequester unless @requester.id == @approvable.requester_id
        @approvable.withdrawal_reason = @reason
        @approvable.request_withdrawal!                          # approved → withdrawal_requested（reason 同時 save）
        Approvals::Start.call(@approvable, purpose: :withdrawal) # 撤回世代の assignment 生成
      end
      @approvable
    end
  end
end
```

Run: `bundle exec rspec spec/services/approvals/request_withdrawal_spec.rb` → PASS。

- [ ] **Step 4: コミット**

```bash
git add app/services/approvals.rb app/services/approvals/request_withdrawal.rb spec/services/approvals/request_withdrawal_spec.rb
git commit -m "feat(2-5): Approvals::RequestWithdrawal（撤回申請起票・本人/reason/再撤回ガード）"
```

---

## Task 6: AttendanceHistory に clock_change_withdrawn + actor 検証 + SPEC §4.14 同期（R8）

**Files:**
- Modify: `app/models/attendance_history.rb`（enum + actor 検証 + コメント）
- Modify: `docs/SPEC.md`（§4.14 列挙へ追記）
- Test: `spec/models/attendance_history_spec.rb`

**Interfaces:**
- Produces: `AttendanceHistory.event_types["clock_change_withdrawn"] == 9`。`leave_withdrawn`/`clock_change_withdrawn` で actor 必須。

- [ ] **Step 1: テスト（失敗）**

`spec/models/attendance_history_spec.rb` に追加:
```ruby
  describe "撤回 event_type（2-5）" do
    it "clock_change_withdrawn は整数 9（append-only 末尾）" do
      expect(AttendanceHistory.event_types["clock_change_withdrawn"]).to eq(9)
    end

    it "leave_withdrawn / clock_change_withdrawn は actor 必須" do
      h = build(:attendance_history, event_type: :leave_withdrawn, actor: nil)
      expect(h).not_to be_valid
      expect(h.errors[:actor_id]).to be_present
    end
  end
```

- [ ] **Step 2: 失敗確認 → 実装**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb -e "撤回 event_type"` → FAIL。

`app/models/attendance_history.rb` の enum を末尾拡張（リオーダ禁止・コメントを「全 10 値」へ）:
```ruby
  # §4.14 が全 10 値を順序固定する taxonomy。整数マッピングは append-only/凍結（リオーダ禁止）
  enum :event_type, {
    clock_in: 0, clock_out: 1, leave_approved: 2, leave_withdrawn: 3,
    clock_change_approved: 4, absence_confirmed: 5, absence_to_paid: 6,
    proxy_clock: 7, interval_shortage: 8, clock_change_withdrawn: 9
  }, validate: true
```
actor 必須検証を追加:
```ruby
  validates :actor_id, presence: true, if: :leave_withdrawn?          # 2-5
  validates :actor_id, presence: true, if: :clock_change_withdrawn?   # 2-5
```

- [ ] **Step 3: SPEC §4.14 を同期**

`docs/SPEC.md` の event_type 列挙行（`clock_in / clock_out / leave_approved / leave_withdrawn / clock_change_approved / absence_confirmed / absence_to_paid / proxy_clock / interval_shortage`）の末尾に `/ clock_change_withdrawn` を追記。

- [ ] **Step 4: 緑を確認**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb`
Expected: PASS。

- [ ] **Step 5: コミット**

```bash
git add app/models/attendance_history.rb docs/SPEC.md spec/models/attendance_history_spec.rb
git commit -m "feat(2-5): AttendanceHistory に clock_change_withdrawn(9) + actor 検証 + SPEC §4.14 同期（R8）"
```

---

## Task 7: LeaveRequests::Withdraw（休暇撤回の逆操作）

`apply_withdrawal_effects!` の LR 実体。残高減算（balance_tracked?・R2）+ AR 復元（leave-status 由来・R3/R4）+ leave_withdrawn 履歴。

**Files:**
- Create: `app/services/leave_requests/withdraw.rb`
- Modify: `app/models/leave_request.rb`（`apply_withdrawal_effects!` override）
- Create: `spec/services/leave_requests/withdraw_spec.rb`

**Interfaces:**
- Consumes: `LeaveRequest`（status withdrawal_requested）・`Clockings::Recalculate`・`LeaveType#balance_tracked?`。
- Produces: `LeaveRequests::Withdraw.call(leave_request:, acting_user:)`。`LeaveRequest#apply_withdrawal_effects!(acting_user:)`。

- [ ] **Step 1: spec を書く（失敗）**

`spec/services/leave_requests/withdraw_spec.rb`:
```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::Withdraw do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org) }
  let(:paid_type) { create(:leave_type, system_type: :annual, paid_leave: true) }
  let(:comp_type) { create(:leave_type, system_type: :compensatory_leave, paid_leave: false) }
  let(:start_date) { Date.new(2026, 5, 1) }   # 金曜
  let(:fiscal_year) { org.fiscal_year_for(start_date) }

  def leave(type:, half: :none, days: 1)
    create(:leave_request, requester: user, leave_type: type, start_date:, end_date: start_date,
           half_day_type: half, days_requested: days, approval_status: :withdrawal_requested, withdrawal_reason: "誤申請")
  end
  def withdraw(lr) = described_class.call(leave_request: lr, acting_user: approver)

  it "paid 撤回で used_days を減算（往復で 0 復帰）" do
    bal = create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, granted_days: 20, used_days: 1)
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    withdraw(leave(type: paid_type, days: 1))
    expect(bal.reload.used_days).to eq(BigDecimal("0"))
  end

  it "代休（compensatory・paid_leave=false）撤回でも減算（R2・balance_tracked?）" do
    bal = create(:leave_balance, user:, leave_type: comp_type, fiscal_year:, granted_days: 5, used_days: 1)
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    withdraw(leave(type: comp_type, days: 1))
    expect(bal.reload.used_days).to eq(BigDecimal("0"))
  end

  it "無打刻 on_leave 日は AR を destroy" do
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    withdraw(leave(type: paid_type, days: 1).tap { create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1) })
    expect(AttendanceRecord.find_by(user:, work_date: start_date)).to be_nil
  end

  it "打刻が残る半休日は clocked_out へ戻し destroy しない（R3）" do
    create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
    rec = create(:attendance_record, :done, user:, work_date: start_date, status: :afternoon_half)
    withdraw(create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                    half_day_type: :afternoon, days_requested: BigDecimal("0.5"),
                    approval_status: :withdrawal_requested, withdrawal_reason: "x"))
    expect(rec.reload.status).to eq("clocked_out")
    expect(rec.clock_in).to be_present
  end

  it "leave_withdrawn 履歴を 1 行記録" do
    create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    expect { withdraw(leave(type: paid_type, days: 1)) }
      .to change { AttendanceHistory.where(event_type: :leave_withdrawn).count }.by(1)
  end
end
```

- [ ] **Step 2: 失敗確認 → 実装**

Run: `bundle exec rspec spec/services/leave_requests/withdraw_spec.rb` → FAIL。

`app/services/leave_requests/withdraw.rb`:
```ruby
# frozen_string_literal: true

module LeaveRequests
  # 休暇撤回の逆操作（SPEC §7.6・§13.6・2-5 設計 §4.1）。
  # 呼び出し元: LeaveRequest#apply_withdrawal_effects!（Approvals::Approve の with_lock 内・同一 tx）。
  # 内側で rescue しない — raise 伝播で撤回承認ごと atomic rollback。
  # 処理順: ① 残高減算（balance_tracked? のみ・lock!）→ ② 範囲内 leave-status AR を復元/destroy → ③ leave_withdrawn 履歴。
  class Withdraw
    def self.call(leave_request:, acting_user:) = new(leave_request:, acting_user:).call

    def initialize(leave_request:, acting_user:)
      @leave_request = leave_request
      @acting_user = acting_user
    end

    def call
      ActsAsTenant.with_tenant(@leave_request.organization) do
        remove_from_balance
        restore_attendance_records
        record_history
      end
      @leave_request
    end

    private

    # 正方向 add_to_balance と同一述語（paid_leave? || compensatory_leave?）。R2 残高リーク防止
    def remove_from_balance
      return unless @leave_request.leave_type.balance_tracked?

      fiscal_year = @leave_request.organization.fiscal_year_for(@leave_request.start_date)
      balance = LeaveBalance
                .where(user_id: @leave_request.requester_id,
                       leave_type_id: @leave_request.leave_type_id, fiscal_year:)
                .lock.first
      return if balance.nil?

      new_used = balance.used_days - @leave_request.days_requested
      Rails.error.report(ApplicationError.new("withdraw underflow"), handled: true) if new_used.negative?
      balance.update!(used_days: [ new_used, BigDecimal("0") ].max)
    end

    # counted_dates を再計算せず、範囲内で leave-status を持つ AR を直接巻き戻す（R3/R4）。
    # 1 日 1 AR（unique [user, work_date]）ゆえ範囲内 leave-status AR = この休暇の日。
    def restore_attendance_records
      AttendanceRecord
        .where(user_id: @leave_request.requester_id,
               work_date: @leave_request.start_date..@leave_request.end_date,
               status: %i[on_leave morning_half afternoon_half])
        .find_each do |record|
          if record.clock_in.blank?
            record.destroy!
          else
            record.update!(status: record.clock_out.present? ? :clocked_out : :working)
            Clockings::Recalculate.call(record:) if record.clock_out.present?
          end
        end
    end

    def record_history
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id, actor: @acting_user, source: @leave_request,
        event_type: :leave_withdrawn, event_date: @leave_request.start_date
      )
    end
  end
end
```

`app/models/leave_request.rb` に override 追加（既存 `apply_approval_effects!` の下）:
```ruby
  def apply_withdrawal_effects!(acting_user:)
    LeaveRequests::Withdraw.call(leave_request: self, acting_user:)
  end
```

> 注: `Rails.error.report` の第 1 引数に汎用例外が必要。プロジェクトに `ApplicationError` が無ければ `StandardError.new(...)` でよい（実装時に既存の error 規約を確認）。

- [ ] **Step 3: 緑を確認**

Run: `bundle exec rspec spec/services/leave_requests/withdraw_spec.rb`
Expected: PASS。

- [ ] **Step 4: コミット**

```bash
git add app/services/leave_requests/withdraw.rb app/models/leave_request.rb spec/services/leave_requests/withdraw_spec.rb
git commit -m "feat(2-5): LeaveRequests::Withdraw（残高 balance_tracked? 減算・leave-status AR 復元・R2/R3/R4）"
```

---

## Task 8: ClockChangeRequests::Withdraw（打刻変更撤回の逆操作）

**Files:**
- Create: `app/services/clock_change_requests/withdraw.rb`
- Modify: `app/models/clock_change_request.rb`（`apply_withdrawal_effects!` override）
- Create: `spec/services/clock_change_requests/withdraw_spec.rb`

**Interfaces:**
- Consumes: `ClockChangeRequest`（original_*/new_*/change_type）・`Clockings::Recalculate`・`AttendanceHistory(clock_change_withdrawn)`（Task 6）。
- Produces: `ClockChangeRequests::Withdraw.call(clock_change_request:, acting_user:)`。`ClockChangeRequest#apply_withdrawal_effects!`。

- [ ] **Step 1: spec を書く（失敗）**

`spec/services/clock_change_requests/withdraw_spec.rb`:
```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClockChangeRequests::Withdraw do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org) }
  let(:work_date) { Date.new(2026, 6, 1) }
  let(:orig_in)  { Time.utc(2026, 6, 1, 0) }   # 09:00 JST
  let(:orig_out) { Time.utc(2026, 6, 1, 9) }   # 18:00 JST
  let(:new_out)  { Time.utc(2026, 6, 1, 10) }  # 19:00 JST（承認で適用済の現値）

  # 承認適用後の状態を再現: AR は new_out、CCR は original_out/new_out を保持し withdrawal_requested
  let(:record) { create(:attendance_record, :done, user:, work_date:, clock_in: orig_in, clock_out: new_out) }
  let(:ccr) do
    create(:clock_change_request, requester: user, attendance_record: record, change_type: :clock_out,
           original_clock_in: orig_in, original_clock_out: orig_out, new_clock_out: new_out,
           approval_status: :withdrawal_requested, withdrawal_reason: "誤申請")
  end
  def withdraw = described_class.call(clock_change_request: ccr, acting_user: approver)

  it "original_clock_out へ復元する" do
    withdraw
    expect(record.reload.clock_out).to eq(orig_out)
  end

  it "現値が new_* と一致しなければ ConflictError（別変更が割り込み）" do
    record.update!(clock_out: Time.utc(2026, 6, 1, 11))
    expect { withdraw }.to raise_error(Approvals::ConflictError)
  end

  it "clock_change_withdrawn 履歴を前後値つきで 1 行記録" do
    expect { withdraw }.to change { AttendanceHistory.where(event_type: :clock_change_withdrawn).count }.by(1)
    h = AttendanceHistory.find_by(event_type: :clock_change_withdrawn)
    expect(h.previous_clock_out).to eq(new_out)
    expect(h.new_clock_out).to eq(orig_out)
  end
end
```

- [ ] **Step 2: 失敗確認 → 実装**

Run: `bundle exec rspec spec/services/clock_change_requests/withdraw_spec.rb` → FAIL。

`app/services/clock_change_requests/withdraw.rb`:
```ruby
# frozen_string_literal: true

module ClockChangeRequests
  # 打刻変更撤回の逆操作（SPEC §7.6・§13.6・2-5 設計 §4.2）。ApplyApproval の鏡像。
  # 呼び出し元: ClockChangeRequest#apply_withdrawal_effects!（Approve の with_lock 内・同一 tx）。
  # 処理順: ① FOR UPDATE ② 競合チェック（現値 == new_*）③ original_* へ復元 ④ §5 再計算 ⑤ 前後値 history。
  class Withdraw
    def self.call(clock_change_request:, acting_user:) = new(clock_change_request:, acting_user:).call

    def initialize(clock_change_request:, acting_user:)
      @ccr = clock_change_request
      @acting_user = acting_user
    end

    def call
      ActsAsTenant.with_tenant(@ccr.organization) do
        record = AttendanceRecord.lock.find(@ccr.attendance_record_id)
        check_conflict!(record)
        before = snapshot(record)
        restore_times!(record)
        record.save!
        Clockings::Recalculate.call(record:) if record.clock_out.present?
        record_history(record, before)
      end
      @ccr
    end

    private

    # 承認で適用した new_* が現値と一致するか（間に別変更が無いか）。正方向 check の鏡像
    def check_conflict!(record)
      ok = true
      ok &&= (record.clock_in == @ccr.new_clock_in)   if @ccr.change_clock_in? || @ccr.change_both?
      ok &&= (record.clock_out == @ccr.new_clock_out)  if @ccr.change_clock_out? || @ccr.change_both?
      raise Approvals::ConflictError unless ok
    end

    def restore_times!(record)
      record.clock_in  = @ccr.original_clock_in  if @ccr.change_clock_in? || @ccr.change_both?
      record.clock_out = @ccr.original_clock_out if @ccr.change_clock_out? || @ccr.change_both?
    end

    def snapshot(record)
      record.slice("clock_in", "clock_out", "status",
                   "is_late", "late_minutes", "is_early_leave", "early_leave_minutes")
    end

    def record_history(record, before)
      record.reload
      AttendanceHistory.create!(
        user_id: record.user_id, actor: @acting_user, source: @ccr,
        event_type: :clock_change_withdrawn, event_date: record.work_date,
        previous_clock_in: before["clock_in"], new_clock_in: record.clock_in,
        previous_clock_out: before["clock_out"], new_clock_out: record.clock_out,
        previous_status: before["status"], new_status: record.status,
        previous_is_late: before["is_late"], new_is_late: record.is_late,
        previous_late_minutes: before["late_minutes"], new_late_minutes: record.late_minutes,
        previous_is_early_leave: before["is_early_leave"], new_is_early_leave: record.is_early_leave,
        previous_early_leave_minutes: before["early_leave_minutes"], new_early_leave_minutes: record.early_leave_minutes
      )
    end
  end
end
```

`app/models/clock_change_request.rb` に override 追加:
```ruby
  def apply_withdrawal_effects!(acting_user:)
    ClockChangeRequests::Withdraw.call(clock_change_request: self, acting_user:)
  end
```

- [ ] **Step 3: 緑を確認**

Run: `bundle exec rspec spec/services/clock_change_requests/withdraw_spec.rb`
Expected: PASS。

- [ ] **Step 4: コミット**

```bash
git add app/services/clock_change_requests/withdraw.rb app/models/clock_change_request.rb spec/services/clock_change_requests/withdraw_spec.rb
git commit -m "feat(2-5): ClockChangeRequests::Withdraw（original_* 復元・競合・clock_change_withdrawn 履歴）"
```

---

## Task 9: 認可（request_withdrawal? + actionable? 一般化）

**Files:**
- Modify: `app/policies/leave_request_policy.rb`
- Modify: `app/policies/clock_change_request_policy.rb`
- Modify: `app/policies/approval_assignment_policy.rb`
- Test: `spec/policies/leave_request_policy_spec.rb` / `clock_change_request_policy_spec.rb` / `approval_assignment_policy_spec.rb`

**Interfaces:**
- Produces: `LeaveRequestPolicy#request_withdrawal?` / `ClockChangeRequestPolicy#request_withdrawal?`（本人 && approved && 撤回世代なし）。`ApprovalAssignmentPolicy#actionable?` が `awaiting_decision?` + purpose 照合へ一般化。

- [ ] **Step 1: policy spec（失敗）**

`spec/policies/leave_request_policy_spec.rb` に追加（既存 setup を流用）:
```ruby
  describe "request_withdrawal?" do
    let(:lr) { create(:leave_request, requester: user, approval_status: :approved) }
    it "本人 && approved && 撤回世代なし で許可" do
      expect(described_class.new(user, lr).request_withdrawal?).to be true
    end
    it "他人は不可" do
      expect(described_class.new(create(:user, organization: org), lr).request_withdrawal?).to be false
    end
    it "applying は不可" do
      lr.update!(approval_status: :applying)
      expect(described_class.new(user, lr).request_withdrawal?).to be false
    end
  end
```
`approval_assignment_policy_spec.rb` に撤回 actionable ケース（既存 ApprovalTestRecord ベースの setup を WithdrawalTestRecord に置換 or 併設）:
```ruby
  describe "actionable?（撤回承認・2-5）" do
    let(:wh) { WithdrawalTestRecord.create!(requester:, approval_status: :withdrawal_requested, withdrawal_reason: "x") }
    let!(:asg) { wh.approval_assignments.create!(organization: org, approver: approver1, position: 1, purpose: :withdrawal, decision: :pending) }
    it "撤回世代の現段階担当者は actionable" do
      expect(described_class.new(approver1, asg).approve?).to be true
    end
    it "host が approved（awaiting でない）なら non-actionable" do
      wh.update!(approval_status: :approved)
      expect(described_class.new(approver1, asg.reload).approve?).to be false
    end
  end
```

- [ ] **Step 2: 失敗確認 → 実装**

Run: `bundle exec rspec spec/policies` → FAIL。

`app/policies/leave_request_policy.rb` と `app/policies/clock_change_request_policy.rb` に追加:
```ruby
  def request_withdrawal?
    record.requester_id == user.id && record.approved? && record.no_prior_withdrawal_round?
  end
```

`app/policies/approval_assignment_policy.rb#actionable?` を差し替え:
```ruby
  def actionable?
    record.pending? &&
      record.approvable.awaiting_decision? &&
      record.purpose == record.approvable.active_purpose.to_s &&
      record.approver_id == user.id &&
      record.position == record.approvable.current_approval_position &&
      !Approvals::SelfApproval.violated?(
        requester_id: record.approvable.requester_id,
        approver_id: record.approver_id, acting_user_id: user.id
      )
  end
```

- [ ] **Step 3: 緑を確認**

Run: `bundle exec rspec spec/policies`
Expected: PASS。

- [ ] **Step 4: コミット**

```bash
git add app/policies spec/policies
git commit -m "feat(2-5): 認可 — request_withdrawal? + actionable? 一般化（R7 purpose 照合）"
```

---

## Task 10: ルート + Controller（request_withdrawal）+ ConflictError 文言（R9）+ request spec

**Files:**
- Modify: `config/routes.rb`
- Modify: `app/controllers/leave_requests_controller.rb`
- Modify: `app/controllers/clock_change_requests_controller.rb`
- Modify: `app/controllers/approval_assignments_controller.rb`（ConflictError 文言分岐）
- Create: `spec/requests/withdrawal_flow_spec.rb`

**Interfaces:**
- Consumes: `Approvals::RequestWithdrawal`（Task 5）・既存 inbox approve/reject（Task 4 で撤回対応済）。
- Produces: `PATCH /leave_requests/:id/request_withdrawal`・`PATCH /clock_change_requests/:id/request_withdrawal`。

- [ ] **Step 1: ルート追加**

`config/routes.rb` の該当 resources の member に追加:
```ruby
  resources :leave_requests, only: %i[index new create] do
    collection { get :preview }
    member { patch :cancel; patch :request_withdrawal }
  end

  resources :clock_change_requests, only: %i[index new create] do
    member { patch :cancel; patch :request_withdrawal }
  end
```

- [ ] **Step 2: request spec を書く（失敗）**

`spec/requests/withdrawal_flow_spec.rb`:
```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "撤回フロー", type: :request do
  let!(:org) { create(:organization, subdomain: "acme") }
  let!(:hr)   { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:dept) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: hr) } }
  let!(:boss) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: dept) } }
  let!(:emp)  { ActsAsTenant.with_tenant(org) { create(:user, manager: boss) } }   # route: [boss, dept]
  let!(:leave_type) { ActsAsTenant.with_tenant(org) { create(:leave_type, paid_leave: false) } }

  # 承認済の休暇を用意（申請 → boss approve → dept approve）
  let!(:leave) do
    ActsAsTenant.with_tenant(org) do
      lr = LeaveRequests::Create.call(requester: emp, leave_type:, start_date: Date.new(2026, 5, 1),
                                      end_date: Date.new(2026, 5, 1), half_day_type: "none", reason: "私用")
      Approvals::Approve.call(approvable: lr, approver: boss)
      Approvals::Approve.call(approvable: lr, approver: dept)
      lr.reload
    end
  end

  it "撤回申請 → 2 段承認 → withdrawn + AR 復元（一周）" do
    sign_in emp
    patch request_withdrawal_leave_request_path(leave, host: tenant_host(org)),
          params: { leave_request: { withdrawal_reason: "誤申請" } }
    expect(ActsAsTenant.with_tenant(org) { leave.reload }).to be_withdrawal_requested

    w1 = ActsAsTenant.with_tenant(org) { leave.approval_assignments.find_by(purpose: :withdrawal, position: 1) }
    sign_in w1.approver
    patch approve_approval_assignment_path(w1, host: tenant_host(org))
    w2 = ActsAsTenant.with_tenant(org) { leave.approval_assignments.find_by(purpose: :withdrawal, position: 2) }
    sign_in w2.approver
    patch approve_approval_assignment_path(w2, host: tenant_host(org))

    expect(ActsAsTenant.with_tenant(org) { leave.reload }).to be_withdrawn
    expect(ActsAsTenant.with_tenant(org) { AttendanceRecord.find_by(user: emp, work_date: Date.new(2026, 5, 1)) }).to be_nil
  end

  it "撤回却下 → approved 復帰で履歴が二重化しない" do
    sign_in emp
    patch request_withdrawal_leave_request_path(leave, host: tenant_host(org)),
          params: { leave_request: { withdrawal_reason: "誤申請" } }
    w1 = ActsAsTenant.with_tenant(org) { leave.approval_assignments.find_by(purpose: :withdrawal, position: 1) }
    sign_in w1.approver
    expect {
      patch reject_approval_assignment_path(w1, host: tenant_host(org)), params: { comment: "却下理由" }
    }.not_to change { ActsAsTenant.with_tenant(org) { AttendanceHistory.count } }
    expect(ActsAsTenant.with_tenant(org) { leave.reload }).to be_approved
  end

  it "他人の撤回申請は 404" do
    other = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in other
    patch request_withdrawal_leave_request_path(leave, host: tenant_host(org)),
          params: { leave_request: { withdrawal_reason: "x" } }
    expect(response).to have_http_status(:not_found)
  end
end
```

- [ ] **Step 3: 失敗確認 → Controller 実装**

Run: `bundle exec rspec spec/requests/withdrawal_flow_spec.rb` → FAIL。

`app/controllers/leave_requests_controller.rb`:
- `before_action :set_leave_request, only: :cancel` を `only: %i[cancel request_withdrawal]` に変更。
- アクション追加:
```ruby
  def request_withdrawal
    authorize @leave_request, :request_withdrawal?
    Approvals::RequestWithdrawal.call(approvable: @leave_request, requester: current_user,
                                      reason: withdrawal_params[:withdrawal_reason])
    redirect_to leave_requests_path, status: :see_other, notice: "撤回を申請しました。承認をお待ちください。"
  rescue AASM::InvalidTransition, Approvals::NotRequester
    redirect_to leave_requests_path, status: :see_other, alert: "この申請は撤回できません。"
  rescue Approvals::RouteError
    redirect_to leave_requests_path, status: :see_other, alert: "承認経路を解決できません。管理者にご連絡ください。"
  rescue ArgumentError, ActiveRecord::RecordInvalid => e
    redirect_to leave_requests_path, status: :see_other, alert: e.message
  end
```
- private に追加:
```ruby
  def withdrawal_params = params.require(:leave_request).permit(:withdrawal_reason)
```
（`set_leave_request` は既存の `policy_scope(LeaveRequest).find(params[:id])` 前提。無ければ追加。）

`app/controllers/clock_change_requests_controller.rb` に同型の `request_withdrawal` + `before_action only: %i[cancel request_withdrawal]` + `params.require(:clock_change_request).permit(:withdrawal_reason)`。redirect は `clock_change_requests_path`。

`app/controllers/approval_assignments_controller.rb#approve` の ConflictError rescue を purpose で文言分岐（R9）:
```ruby
  rescue Approvals::ConflictError
    msg = @assignment.purpose_withdrawal? ? "対象記録が変更されているため撤回できません" :
                                            "変更前時刻が現在の記録と一致しません（申請者へ再申請をご依頼ください）"
    redirect_to approval_assignments_path, status: :see_other, alert: msg
```

- [ ] **Step 4: 緑を確認**

Run: `bundle exec rspec spec/requests/withdrawal_flow_spec.rb spec/requests/approval_assignments_spec.rb`
Expected: PASS（既存承認 request spec も緑）。

- [ ] **Step 5: コミット**

```bash
git add config/routes.rb app/controllers spec/requests/withdrawal_flow_spec.rb
git commit -m "feat(2-5): 撤回 controller/route（request_withdrawal・R5/R6 rescue・R9 文言）"
```

---

## Task 11: View — 撤回ボタン（index）+ インボックス撤回バッジ

`show` が無いため撤回導線は一覧（index）に置く。インボックス行は型別 ViewComponent。

**Files:**
- Modify: `app/views/leave_requests/index.html.erb`
- Modify: `app/views/clock_change_requests/index.html.erb`
- Modify: `app/components/approvals/leave_request_row_component.*`（撤回バッジ）
- Modify: `app/components/approvals/clock_change_request_row_component.*`
- Test: `spec/system/withdrawal_flow_spec.rb`（任意・主要動線）

**Interfaces:**
- Consumes: `policy(record).request_withdrawal?`・`assignment.purpose_withdrawal?`。

- [ ] **Step 1: leave_requests/index に撤回フォームを追加**

`app/views/leave_requests/index.html.erb` の各行（cancel ボタンの隣）に追加:
```erb
<% if policy(r).request_withdrawal? %>
  <%= form_with url: request_withdrawal_leave_request_path(r), method: :patch, class: "inline-flex gap-1" do |f| %>
    <%= f.text_field "leave_request[withdrawal_reason]", placeholder: "撤回理由", required: true, class: "border text-sm" %>
    <%= f.submit "撤回申請", class: "text-orange-600" %>
  <% end %>
<% end %>
<% if r.withdrawal_requested? %>
  <span class="text-orange-500 text-sm">撤回承認待ち</span>
<% end %>
```

- [ ] **Step 2: clock_change_requests/index に同型を追加**

`app/views/clock_change_requests/index.html.erb` に `request_withdrawal_clock_change_request_path(r)` + `clock_change_request[withdrawal_reason]` で同型のフォーム + 「撤回承認待ち」表示。

- [ ] **Step 3: インボックス行コンポーネントに撤回バッジ**

`app/components/approvals/leave_request_row_component`（html）と `clock_change_request_row_component`（html）に、`assignment.purpose_withdrawal?` のとき「**撤回承認**」バッジを表示する分岐を追加（既存テンプレートの見出し付近）:
```erb
<% if assignment.purpose_withdrawal? %>
  <span class="rounded bg-orange-100 text-orange-700 px-1 text-xs">撤回承認</span>
<% end %>
```
（コンポーネントが `assignment` を受け取る前提。受け取らない場合は initializer 経由で渡す。）

- [ ] **Step 4: 手動 or system spec で動線確認**

Run（任意）: `bundle exec rspec spec/system/withdrawal_flow_spec.rb`
最低限、`bundle exec rspec spec/requests/withdrawal_flow_spec.rb` が緑のままを確認（view レンダリングで 500 が出ないこと）。

- [ ] **Step 5: コミット**

```bash
git add app/views/leave_requests app/views/clock_change_requests app/components/approvals
git commit -m "feat(2-5): 撤回 UI（index 撤回フォーム + インボックス撤回バッジ）"
```

---

## Task 12: ROADMAP 更新 + 全体検証 + レビュー

**Files:**
- Modify: `docs/ROADMAP.md`（2-5 行にチェック + PR 番号）

- [ ] **Step 1: ROADMAP の 2-5 行を更新**

`docs/ROADMAP.md` の `- [ ] **2-5 撤回フロー**: ...` を `- [x]` にし、PR 番号リンクを付す（PR 作成後に番号確定）。

- [ ] **Step 2: 全 spec を実行**

Run: `bundle exec rspec`
Expected: 全 PASS（0 failures）。失敗があれば該当 Task に戻る。

- [ ] **Step 3: rubocop**

Run: `bundle exec rubocop`
Expected: no offenses（ファイル明示時は `--force-exclusion`）。

- [ ] **Step 4: brakeman（app/ に触れたため必須）**

Run: `bin/brakeman --no-pager`
Expected: no new warnings。

- [ ] **Step 5: 専門レビュー（merge 前 PROACTIVELY）**

`approval-engine-reviewer`（撤回 AASM・自己承認・副作用 atomicity・purpose 世代分離）と `tenant-isolation-reviewer`（purpose 列・Withdraw の with_tenant・複合 index）を起動。指摘があれば修正コミット。

- [ ] **Step 6: コミット + PR**

```bash
git add docs/ROADMAP.md
git commit -m "docs(2-5): ROADMAP 撤回フロー完了に更新"
```
`/preflight` 後に PR 作成（squash・CI 必須・ROADMAP 該当行更新を含む）。

---

## Self-Review（計画 → 設計の突合）

**Spec coverage（設計 §→Task）:**
- §1.1 A-1 purpose migration + index → Task 1 ✓ / §1.1 A-2 withdrawal_reason → Task 1 ✓ / clock_change_withdrawn(9) + SPEC §4.14（R8）→ Task 6 ✓
- §1.2 ApprovalAssignment uniqueness（R1）→ Task 1 ✓
- §2.1 Approvable enum 0–5 + 導出（purpose スコープ）+ awaiting_decision? → Task 2 ✓
- §2.2 Withdrawable + aasm 再オープン + HWR 隔離 + TDD ①②③④ → Task 3 ✓
- §3.1 Start purpose → Task 4 ✓ / §3.2 Approve finalize 撃ち分け → Task 4 ✓ / §3.3 Reject → Task 4 ✓ / §3.4 RequestWithdrawal → Task 5 ✓
- §4.1 LeaveRequests::Withdraw（balance_tracked? R2・leave-status 復元 R3/R4）→ Task 7 ✓ / §4.2 CCR::Withdraw → Task 8 ✓ / §4.3 host override → Task 7/8 ✓ / §4.4 actor 検証 → Task 6 ✓
- §5.1 Policy（request_withdrawal? + actionable? R7）→ Task 9 ✓ / §5.2 controller（R5/R6）→ Task 10 ✓ / §5.3 view + R9 → Task 10/11 ✓
- §6 締め月前方フック → 各モデル/サービスに TODO コメント（Task 1/5/7 実装時に挿入・本計画では §6 の挿入点を実装注記で踏襲）
- §7 テスト計画 → 各 Task の spec ✓ / §8 ハンドオフ → Task 12 レビュー ✓

**Placeholder scan:** 「TODO」は §6 締め月の前方フック（意図的・設計準拠）のみ。各 step に実コード・実コマンド・期待結果あり。`ApplicationError` は Task 7 注記で `StandardError` フォールバックを明示。

**Type consistency:** `purpose`（enum prefix `purpose_`）・`active_purpose`（symbol・policy で `.to_s` 比較）・`apply_withdrawal_effects!(acting_user:)`・`Approvals::RequestWithdrawal.call(approvable:, requester:, reason:)`・`balance_tracked?`・`no_prior_withdrawal_round?` は Task 間で一貫。`WithdrawalTestRecord`（support）は Task 3 で定義し Task 4/9 で参照。

**補足 — §6 前方フックの挿入:** 設計 §6 の TODO コメント（LR/CCR の `not_in_locked_month` 挿入点・RequestWithdrawal の締め制限挿入点）は、該当ファイルを触る Task（1/5/7/8）の実装時にコメントとして残す（実装はしない・Phase 3-2）。
