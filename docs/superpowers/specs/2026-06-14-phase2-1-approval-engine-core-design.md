# Phase 2-1 承認エンジン core — 設計

- 日付: 2026-06-14
- スライス: ROADMAP Phase 2-1（`- [ ] 2-1 承認エンジン core`）
- 1 スライス = 1 ブランチ = 1 PR（`feat/phase2-1-approval-engine-core`）
- 典拠: SPEC §7（承認エンジン）・§13.2 / §13.6（AASM・イベント副作用）・§4.9–4.13（申請モデル）・§3.6（テナント分離）

## 0. スコープと前提

承認される**対象モデル（LeaveRequest / ClockChangeRequest / HolidayWorkRequest）は 2-2 以降**で登場する。本スライスは SPEC §7.1 の polymorphic 設計に従い、**対象非依存の承認エンジン中核**を構築する。具体的には:

- `ApprovalAssignment`（実行時状態・polymorphic）
- `Approvable` concern（AASM 業務ステータス + 段階導出）
- `Approvals::RouteResolver`（固定 2 段ルート解決・単段縮約）
- `Approvals::Start / Approve / Reject / Cancel`（コマンドサービス）
- `ApprovalAssignmentPolicy`（自己承認防止の認可層・サービス層と二層）
- テスト専用 approvable ホストによる end-to-end 検証

### 設計判断ログ（本設計の前提となる決定）

| # | 論点 | 決定 |
|---|------|------|
| Q1 | エンジンの動作検証・スライス境界 | **純エンジン + テスト専用 approvable**（本番申請モデル 0・UI なし）。2-2 が実モデルを `include Approvable` |
| Q2 | 承認ルート stage2 の算出 | **role 分岐 + チェーン上の hr_admin**。stage1 = `requester.manager` 共通 |
| Q3 | 自己承認防止のスコープ | **#1 直接 / #2 代理(acting_user・delegate 列は §7.5 後置) / #3 段階独立 + AASM 限定**。#4 撤回は 2-5 |
| — | 内部構造 | **Approach 1: サービス編成**（既存 `Clockings::Recalculate` = `app/services/<ns>/<verb>` 規約に一致） |

### 本スライスに含めない（明示的後置）

- 撤回フロー（`withdrawal_requested` / `withdrawn` 状態・イベント）→ **2-5**（§7.6・§13.6）
- 申請モデル本体と承認副作用（LeaveBalance 加算・AttendanceRecord 更新・AttendanceHistory 追記）→ **2-2 / 2-3 / 2-4**
- delegate 基盤（`User.delegate_approver_id` 列・委任 UI）・委任循環検出の実体・滞留アラート → **§7.5（後続スライス）**。本スライスは `acting_user` 引数の seam のみ用意
- 承認 UI（インボックス・承認画面）・controller → **2-2+**
- 競合チェック（§7.4・CCR 固有）→ **2-3**

---

## 1. モデル / スキーマ — `ApprovalAssignment`

承認の**実行時状態**を 1 テーブルに記録する（§7.1）。段階情報（第 1/第 2 待ち）は status に持たず、本テーブル群から導出する。

### マイグレーション `approval_assignments`

| カラム | 型 | 制約 | 説明 |
|---|---|---|---|
| `organization_id` | bigint | NOT NULL | テナント（付随テーブルにも明示・§3.6） |
| `approvable_type` / `approvable_id` | string / bigint | NOT NULL | 承認対象（polymorphic） |
| `position` | integer | NOT NULL | 段階 1 / 2 |
| `approver_id` | bigint | NOT NULL | 承認者（User） |
| `decision` | integer (enum) | NOT NULL default 0 | pending(0) / approved(1) / rejected(2) |
| `acted_at` | timestamptz | NULL | 決裁時刻（pending 中は NULL） |
| `comment` | text | NULL | 承認 / 却下コメント |
| `created_at` / `updated_at` | timestamptz | NOT NULL | |

### インデックス & 参照整合（§3.6 二層防御）

- **UNIQUE** `[organization_id, approvable_type, approvable_id, position]` — 1 対象 1 段階 1 行
- **INDEX** `[organization_id, approver_id, decision]` — 「自分宛の pending 承認」検索
- **複合 FK** `(organization_id, approver_id) → users(organization_id, id)` — 承認者のクロステナント参照を DB レベルで排除（既存 `users.manager_id` と同型。users に `[organization_id, id]` unique index 既存）
- approvable は polymorphic ゆえ実 FK 不可 → `organization_id` 明示 + `acts_as_tenant` スコープ + モデル検証で同一テナントを担保

### モデル `ApprovalAssignment`

```ruby
acts_as_tenant(:organization)
belongs_to :approvable, polymorphic: true
belongs_to :approver, class_name: "User"

enum :decision, { pending: 0, approved: 1, rejected: 2 }, validate: true

validates :position, inclusion: { in: [1, 2] }
validates :position, uniqueness: { scope: [:organization_id, :approvable_type, :approvable_id] }
validate  :approver_must_belong_to_same_organization   # users.rb と同型（検証層）
validate  :acted_at_consistency_with_decision          # pending⇔acted_at NULL の不変条件
validate  :decision_is_one_way, on: :update            # pending→approved/rejected の片道（取消不可）
```

- `decision` は pending → approved/rejected の**片道**（決裁の取消不可）。
- `approver` は §7.3 #3（段階独立）の照合対象。ルート解決が単段縮約するため stage1/stage2 が同一人物になる 2 行は作られない。

---

## 2. AASM 業務ステータス — `Approvable` concern

`app/models/concerns/approvable.rb`。`approval_status` を AASM で**業務ステータスのみ**保持し、段階情報は持たない（§7.1・§13.2）。申請モデル（2-2+）とテスト専用 approvable が `include` する。host 側は `belongs_to :requester, class_name: "User"` を持つ契約。

### 状態機械（2-1 スコープ = 基底 4 状態）

```
[*] --> applying : 新規作成（AASM 初期状態＝§7.7 を充足）
applying --> approved  : approve（最終段階の承認時のみ）
applying --> rejected  : reject （いずれかの段階で却下）
applying --> canceled  : cancel （申請者の取消）
終端: approved / rejected / canceled
```

撤回（withdrawal_requested / withdrawn）は **2-5** で追加。本スライスでは遷移を定義しない（§7.6 の「イベント未定義で構造防止」と整合）。

### enum 整数マッピング（凍結）

`applying:0 / approved:1 / rejected:2 / canceled:3`。**整数 4=withdrawal_requested・5=withdrawn は 2-5 用に予約・凍結**（AttendanceHistory §4.14 の append-only 規律と同型）。HWR は §4.12 どおり 4 値のまま（撤回 concern を include しない）。AASM は `column: :approval_status, enum: true` で Rails enum に接続する。

> 2-5 での撤回追加方式（Leave/CCR のみに enum 値 4/5 と撤回イベントを足す `Withdrawable` concern 等）は 2-5 で確定する。本スライスは整数 0–3 を確定し、4/5 を凍結予約するのみ。

### 段階進行とイベントの関係（重要）

- 段階ごとの承認は `ApprovalAssignment.decision` の更新であり、status の AASM イベントではない。途中段階の承認中も status は `applying` を維持（§13.2）。
- **最終段階が承認された時のみ**サービスが host の AASM `approve` を発火。却下はどの段階でも `reject` で全体却下。
- **副作用は 2-1 では一切付けない**（§13.6・イベント単位副作用は対象モデルが現れる 2-2+ で `approve` イベントに紐付け）。

### §7.3 #5 — AASM 限定の徹底

status は AASM イベント（bang メソッド）経由でのみ変更。concern は直接セッターを公開せず、全書き込みはサービスが transaction 内で実施する。`update_column` / `update_all` による直接代入は規約で禁止（状態機械の迂回防止）。AttendanceHistory のような DB トリガ不変化は施さない（status は本来変化する値ゆえ過剰）。

### 導出ヘルパ（status は段階を持たない）

- `current_approval_position` — 最小の pending 段階 position（なければ nil）
- `single_stage?` — assignment が 1 件（縮約済み）
- `all_stages_approved?` — 全 assignment が approved（最終 approve のガード）
- `pending_approver` — 現段階の承認者

### 起動（§7.7）

concern が **`after_create :start_approval_route!`** で `Approvals::Start.call(self)` を起動する（§7.7「初期 applying をセット → 起動はその後」）。`after_create`（after_create_commit ではない）に置くことで、`RouteError` 時に tx ロールバックで作成自体を失敗させ「申請不可」を構造的に表現する。

---

## 3. ルート解決 — `Approvals::RouteResolver`

`app/services/approvals/route_resolver.rb`（PORO）。`requester`（User）→ **順序付き承認者配列**（長さ 1 or 2）を返す。長さ 1 = 単段縮約。テナント文脈下で動作（`User#manager` は `acts_as_tenant` でスコープ済 → クロステナントは nil 化 + User 既存検証で二重防御・§3.6）。

### アルゴリズム（共通: `stage1 = requester.manager`）

```
stage1 = requester.manager
raise RouteError(:manager_unset) if stage1.nil?      # manager_id 未設定 → 申請不可（§7.2）

stage2 =
  employee → stage1.manager                          # 部門長（上上長）
  manager  → first_hr_admin_up_chain(requester)      # requester から .manager を遡る最初の hr_admin
  hr_admin → first_hr_admin_up_chain(requester)      # エッジ（自分は始点に含めず自動除外）

approvers = [stage1, stage2].compact.uniq            # nil / 同一 → 縮約
```

`first_hr_admin_up_chain(requester)`: `requester.manager` から `.manager` を上昇し、最初に `hr_admin?` の User を返す。requester 自身は始点に含めないため自動除外。循環は User 既存ガードで不可ゆえ有界。

### 縮約・エラーの分岐（role で挙動が非対称）

| ケース | 結果 |
|---|---|
| employee で stage2 = nil（上長に上長なし） | **[stage1] へ縮約**（許容・「独立性なし」を表示・§7.2） |
| employee/manager で stage2 == stage1（部門長が既に hr_admin 等） | **[stage1] へ縮約**（`.uniq`） |
| **manager で hr_admin 不在**（チェーンに hr_admin なし） | **RouteError(:hr_admin_unset)**（Q2 の決定・申請不可） |
| 全 role で manager_id 未設定 | **RouteError(:manager_unset)** |

### §7.3 #3（段階独立）はデータ構造で担保

2 要素ルートでは `.uniq` により stage1 ≠ stage2 が保証される（同一人物なら 1 段に縮約され 2 行は作られない）。サービス / ポリシーの実行時チェックは二重化として残す。

### エッジ: hr_admin 申請者

§7.2 表は employee/manager のみ定義。hr_admin 申請者は **manager ルートに準拠**（stage1=自分の manager、stage2=チェーン上の*別の* hr_admin）。stage2 が自分しかいなければ縮約で [stage1]、manager も無ければ RouteError。決定論的に処理し spec で固定する。

### エラー

`Approvals::RouteError`（理由: `:manager_unset` / `:hr_admin_unset`）。実申請フロー（2-2+）が「申請不可・セットアップ要」として捕捉。2-1 では raise を spec で検証。

---

## 4. 承認サービス + 自己承認防止 — `Approvals::*`

`app/services/approvals/` にコマンドサービス 4 つ。全て transaction 内で実行し、決裁時は `approvable.with_lock`（行ロック）で段階進行を直列化（同時承認・二重クリックの競合防止）。

### `Approvals::Start.call(approvable)`

- `Approvable` concern が `after_create :start_approval_route!` で自動起動（§7.7）。
- `RouteResolver` でルート算出 → `position 1..N` の **pending な ApprovalAssignment** を作成。
- `RouteError` は after_create 内 raise → tx ロールバックで作成失敗＝「申請不可」。
- 冪等: 既に assignment があればスキップ。

### `Approvals::Approve.call(approvable:, approver:, acting_user: approver, comment: nil)`

**自己承認防止ガード（状態変更前に raise）:**

1. **#1 直接**: `approver.id != approvable.requester_id` → 違反は `SelfApprovalError`
2. **#2 代理**: `acting_user.id != approvable.requester_id`（+ 委任循環拒否の seam）。2-1 は `acting_user` 既定 = approver。**引数を初日から用意**し §7.5 の delegate 導入を非破壊に。循環検出は delegate_approver_id 着地時に実装
3. **#3 段階独立 / 段階順序**: 現在の pending 段階（`current_approval_position`）の assignment の approver と一致を必須。段階順序違反（stage2 を stage1 前に）は `NotCurrentApprover`

**処理:** 現段階 assignment を `decision: :approved, acted_at: Time.current, comment:` に更新 → `all_stages_approved?` なら **最終承認として `approvable.approve!`（AASM）発火**（2-1 は副作用なし）。未了なら applying 維持で次段階へ。`applying?` 以外は AASM `InvalidTransition`（構造ガード）。

### `Approvals::Reject.call(approvable:, approver:, acting_user: approver, comment:)`

- 同じ 3 ガード + 現段階認可。`comment`（却下理由）必須。
- 現段階 assignment を rejected 記録 → **どの段階でも `approvable.reject!` で全体却下**（残 pending は履歴として残置）。

### `Approvals::Cancel.call(approvable:, by:)`

- **申請者のみ**（`by.id == approvable.requester_id`）。承認者は関与しない。`approvable.cancel!`（applying→canceled）。

### 例外

`Approvals::SelfApprovalError` / `NotCurrentApprover` / `RouteError` / AASM `InvalidTransition`（terminal への決裁）。いずれも上位（2-2+ の controller）が握って表示。

### 二層防御の片側

ここはサービス層で自己完結（Pundit に依存しない）。認可層（Pundit）でも同じ #1/#2/#3 を独立に二重化（§7.3「サービス冒頭 + Pundit」）→ §5。

---

## 5. 認可 — `ApprovalAssignmentPolicy`（Pundit・二層防御の片側）

§7.3 は「サービス冒頭 + Pundit」の二重を要求。両者は独立に同じ #1/#2/#3 を encode し、controller 迂回（API・直接呼び出し）でも controller 経路でも自己承認を塞ぐ。対象は **ApprovalAssignment**（承認者が「自分宛の現段階」に対し action する）。

```ruby
class ApprovalAssignmentPolicy < ApplicationPolicy
  def approve? = actionable?
  def reject?  = actionable?

  private

  def actionable?
    record.pending? &&
      record.approvable.applying? &&                                    # terminal は不可
      record.approver_id == user.id &&                                  # #3 現段階の担当者本人
      record.position == record.approvable.current_approval_position && # 段階順序
      record.approver_id != record.approvable.requester_id             # #1 直接の自己承認禁止
  end

  class Scope < ApplicationPolicy::Scope
    def resolve                                                         # 自分宛の pending 承認（インボックス）
      scope.where(approver_id: user.id, decision: :pending)
    end
  end
end
```

- **#2 代理の認可側**: Pundit の `user` は実行ユーザ（= acting_user 相当）。`user.id != requester_id` が成立するため、代理人が requester 本人の場合もここで二重に塞がる。委任循環の検出は delegate グラフ依存ゆえサービス層（§7.5 seam）。
- **cancel は別系統**: 申請者本人のみ・対象は approvable。2-1 ではサービス層（`by.id == requester_id`）で担保し、Pundit の `cancel?` は具体 approvable のポリシーが現れる 2-2 で追加（自己承認とは別概念ゆえ本ポリシーには載せない）。
- controller は 2-1 に無い（UI なし）。ポリシーは pundit-matchers で直接 spec。

---

## 6. テスト戦略

### 検証土台: テスト専用ホスト（`spec/support/approvable_test_model.rb`）

本番申請モデル不在ゆえ、`Approvable` concern を使い捨てモデルで動かす（concern テストの定石）:

```ruby
# test env のみ。schema.rb を汚さず一時テーブルを生成
ActiveRecord::Base.connection.create_table(:approval_test_records, force: true) do |t|
  t.references :organization, null: false
  t.references :requester,    null: false   # User
  t.integer    :approval_status, null: false, default: 0
  t.timestamps
end

class ApprovalTestRecord < ApplicationRecord
  acts_as_tenant(:organization)
  belongs_to :requester, class_name: "User"
  include Approvable
end
```

- 各部品（concern / service / policy）をこのホストで end-to-end に exercise。2-2 で本物の LeaveRequest が `include Approvable` した時、同じ契約がそのまま効く。
- 留意: 一時テーブルは worker 毎に生成（並列テスト OK）。`maintain_test_schema!` は pending migration のみ検査ゆえ追加テーブルと非干渉。

### spec カバレッジ（テナント文脈下・`gen-spec` 準拠で作成）

| 種別 | ファイル | 主眼 |
|---|---|---|
| model | `spec/models/approval_assignment_spec.rb` | position(1,2)・一意(org,approvable,position)・decision enum・**approver 同一テナント（クロステナント拒否）**・acted_at 整合・decision 片道・テナント分離 |
| concern | `spec/models/concerns/approvable_spec.rb`（テストホスト） | 初期 applying(§7.7)・approve/reject/cancel 遷移・terminal から InvalidTransition・撤回イベント未定義・after_create で route 自動起動・導出ヘルパ・整数 0–3 凍結 / 4–5 予約 |
| service | `spec/services/approvals/route_resolver_spec.rb` | employee 2 段 / 浅い縮約・manager+hr_admin / 部門長=hr_admin 縮約・**manager で hr_admin 不在=RouteError**・manager 未設定=RouteError・hr_admin 申請者エッジ・クロステナント manager 安全 |
| service | `spec/services/approvals/{start,approve,reject,cancel}_spec.rb` | Start 冪等・最終段階のみ AASM approve・2 段の段階進行・**#1/#2/#3 自己承認防止**・段階順序違反・却下は全体却下・cancel は申請者限定 |
| policy | `spec/policies/approval_assignment_policy_spec.rb` | pundit-matchers で承認者 permit／申請者・第三者・誤段階・terminal・決裁済 forbid・Scope のテナント分離 |

### 完了条件（CLAUDE.md サブエージェント 3 か条）

- `bundle exec rspec` 緑 ／ `bundle exec rubocop --force-exclusion <files>` ／ app/ 変更ゆえ `bin/brakeman --no-pager`
- PR 前に `/preflight`、**ROADMAP の 2-1 行を更新（チェック + PR 番号）して PR に含める**

---

## 7. 新規ファイル一覧（manifest）

| ファイル | 役割 |
|---|---|
| `db/migrate/*_create_approval_assignments.rb` | テーブル + 複合 FK + index |
| `app/models/approval_assignment.rb` | 実行時状態モデル |
| `app/models/concerns/approvable.rb` | AASM 業務ステータス + 段階導出 + after_create 起動 |
| `app/services/approvals/route_resolver.rb` | 固定 2 段ルート解決・縮約 |
| `app/services/approvals/start.rb` | route → pending assignment 生成 |
| `app/services/approvals/approve.rb` | 承認（自己承認防止・段階進行・最終 AASM） |
| `app/services/approvals/reject.rb` | 却下（全体却下） |
| `app/services/approvals/cancel.rb` | 申請者取消 |
| `app/services/approvals/errors.rb`（任意） | `RouteError` / `SelfApprovalError` / `NotCurrentApprover` |
| `app/policies/approval_assignment_policy.rb` | 自己承認防止の認可層 + Scope |
| `spec/support/approvable_test_model.rb` | テスト専用ホスト |
| `spec/**/*_spec.rb` | 上表のカバレッジ |

## 8. RAILS_GOTCHAS の留意（実装・レビュー時に注入）

- console/rake は `ActsAsTenant.current_tenant` を先に設定（スコープ付きクエリの `NoTenantSet` 回避）
- rubocop はファイル明示渡し時 `--force-exclusion` 必須（schema.rb 等の Exclude 無視回避）
- SolidQueue 等のリクエスト無し経路は `ActsAsTenant.with_tenant` ラップ必須（本スライスはバッチ無しだが、§7.5 滞留アラート時に該当）
