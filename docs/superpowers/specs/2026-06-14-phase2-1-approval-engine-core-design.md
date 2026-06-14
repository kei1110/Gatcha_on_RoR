# Phase 2-1 承認エンジン core — 設計

- 日付: 2026-06-14
- スライス: ROADMAP Phase 2-1（`- [ ] 2-1 承認エンジン core`）
- 1 スライス = 1 ブランチ = 1 PR（`feat/phase2-1-approval-engine-core`）
- 典拠: SPEC §7（承認エンジン）・§13.2 / §13.6（AASM・イベント副作用）・§4.9–4.13（申請モデル）・§3.6（テナント分離）・§2.2（アーキ 6 原則）
- **多視点レビュー反映済**（2026-06-14・原則整合 / 実用主義 / YAGNI / セキュリティ / テスト網羅）

## 0. スコープと前提

承認される**対象モデル（LeaveRequest / ClockChangeRequest / HolidayWorkRequest）は 2-2 以降**で登場する。本スライスは SPEC §7.1 の polymorphic 設計に従い、**対象非依存の承認エンジン中核**を構築する。具体的には:

- `ApprovalAssignment`（実行時状態・polymorphic）
- `Approvable` concern（AASM 業務ステータス + 段階導出）
- `Approvals::RouteResolver`（固定 2 段ルート解決・単段縮約）
- `Approvals::Start / Approve / Reject`（コマンドサービス）
- `Approvals::SelfApproval`（自己承認規則の**単一ソース**・サービスと Pundit が共有）
- `ApprovalAssignmentPolicy`（自己承認防止の認可層・サービス層と二層）
- テスト専用 approvable ホストによる end-to-end 検証

### 設計判断ログ（本設計の前提となる決定）

| # | 論点 | 決定 |
|---|------|------|
| Q1 | エンジンの動作検証・スライス境界 | **純エンジン + テスト専用 approvable**（本番申請モデル 0・UI なし）。2-2 が実モデルを `include Approvable` |
| Q2 | 承認ルート stage2 の算出 | **role 分岐 + チェーン上の hr_admin**。stage1 = `requester.manager` 共通 |
| Q3 | 自己承認防止のスコープ | **#1 直接 / #2 代理 / #3 段階独立 + AASM 限定**。#4 撤回は 2-5 |
| C（MPR） | #2 代理ガード（acting_user）の 2-1 扱い | **pin する**。`acting_user` 引数は残すが 2-1 では `acting_user == approver` を強制（不一致は `ProxyNotSupported`）。「delegate 着地まで任意 actor 注入を受理しない」をテストで固定し、休眠シームの誤用・空テストを防ぐ。§7.5 で delegate 認可に置換 |
| 起動（MPR） | `Approvals::Start` の起動方式 | **明示サービス起動**（after_create を使わない）。2-2 の申請作成サービスが `save! → Approvals::Start.call` を 1 tx で実行。2-1 では spec が明示的に `Start.call` を呼ぶ。原則 §2.2-2（callback は軽微値セットのみ）に整合 |
| YAGNI（MPR） | 2-1 に呼び出し元の無い部品 | **Scope・`Approvals::Cancel` サービス・ヘルパ `single_stage?`/`pending_approver` を 2-2 へ後置**。`cancel!` AASM イベント自体は基底 4 状態・terminal テストのため 2-1 に残す |
| — | 内部構造 | **Approach 1: サービス編成**（既存 `Clockings::Recalculate` = `app/services/<ns>/<verb>` 規約に一致） |

### 本スライスに含めない（明示的後置）

- 撤回フロー（`withdrawal_requested` / `withdrawn` 状態・イベント）→ **2-5**（§7.6・§13.6）
- 申請モデル本体と承認副作用（LeaveBalance 加算・AttendanceRecord 更新・AttendanceHistory 追記）→ **2-2 / 2-3 / 2-4**
- delegate 基盤（`User.delegate_approver_id` 列・委任 UI）・委任循環検出の実体・滞留アラート → **§7.5（後続スライス）**。本スライスは `acting_user` 引数を pin して seam のみ用意
- `Approvals::Cancel` サービス + cancel 認可（`cancel?` Pundit）・取消 UI → **2-2**（取消アクション/controller が現れる時）
- Pundit `ApprovalAssignmentPolicy::Scope`（承認インボックス）・導出ヘルパ `single_stage?` / `pending_approver` → **2-2**（インボックス UI と同時）
- 承認 UI（承認画面）・controller → **2-2+**
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
- **INDEX** `[organization_id, approver_id, decision]` — 「自分宛の pending 承認」検索（Scope は 2-2 だが index は今張る）
- **複合 FK** `(organization_id, approver_id) → users(organization_id, id)` — 承認者のクロステナント参照を DB レベルで排除（既存 `users.manager_id` / `user_work_patterns` と同型。users に `[organization_id, id]` unique index 既存。実装は `db/migrate/*_create_user_work_patterns.rb` を参照実装に踏襲）
- approvable は polymorphic ゆえ実 FK 不可 → **唯一の越境シーム**。`organization_id` 明示 + `acts_as_tenant` スコープ + **モデル検証**で同一テナントを担保（下記 `approvable_must_belong_to_same_organization` が第一かつ唯一の防御）

### モデル `ApprovalAssignment`

```ruby
acts_as_tenant(:organization)
belongs_to :approvable, polymorphic: true
belongs_to :approver, class_name: "User"

enum :decision, { pending: 0, approved: 1, rejected: 2 }, validate: true

validates :position, inclusion: { in: [1, 2] }
validates :position, uniqueness: { scope: [:organization_id, :approvable_type, :approvable_id] }
validate  :approver_must_belong_to_same_organization     # users.rb と同型（検証層）
validate  :approvable_must_belong_to_same_organization   # ★MPR-A: polymorphic 越境の唯一の能動防御
validate  :acted_at_consistency_with_decision            # pending⇔acted_at NULL の不変条件
validate  :decision_is_one_way, on: :update              # pending→approved/rejected の片道（取消不可）
```

- **`approvable_must_belong_to_same_organization`**（★MPR-A・高）: `approvable&.organization_id == organization_id`。**nil（スコープ外）も明示エラー化**（user.rb の `manager_must_belong_to_same_organization` と同型 — acts_as_tenant の read スコープが越境 approvable を nil 化するため、能動検証で fail-closed にする）。
- **decision は片道**（pending → approved/rejected。逆遷移・再決裁を `decision_is_one_way` で拒否）。
- **mass-assignment 封じ**（★MPR-B）: `decision` / `acted_at` は **strong params に載せない**（2-2+ controller の契約）。`decision` の唯一の writer は `Approvals::Approve` / `Reject` サービス。汎用 update アクションを作らない。`update?` は Pundit 既定 deny のまま。
- `approver` は §7.3 #3（段階独立）の照合対象。ルート解決が単段縮約するため stage1/stage2 が同一人物になる 2 行は作られない。

---

## 2. AASM 業務ステータス — `Approvable` concern

`app/models/concerns/approvable.rb`。`approval_status` を AASM で**業務ステータスのみ**保持し、段階情報は持たない（§7.1・§13.2）。申請モデル（2-2+）とテスト専用 approvable が `include` する。host 側は `belongs_to :requester, class_name: "User"` を持つ契約。

concern が宣言するもの:
```ruby
included do
  has_many :approval_assignments, as: :approvable, dependent: :destroy

  enum :approval_status, { applying: 0, approved: 1, rejected: 2, canceled: 3 }   # ★宣言順: enum を先に
  aasm column: :approval_status, enum: true, whiny_persistence: true do            # ★MPR-F: whiny で偽 success 化を防ぐ
    state :applying, initial: true
    state :approved, :rejected, :canceled
    event(:approve) { transitions from: :applying, to: :approved, guard: :all_stages_approved? }  # ★最終のみ
    event(:reject)  { transitions from: :applying, to: :rejected }
    event(:cancel)  { transitions from: :applying, to: :canceled }
  end
end
```

### 状態機械（2-1 スコープ = 基底 4 状態）

```
[*] --> applying : 新規作成（AASM 初期状態＝§7.7 を充足）
applying --> approved  : approve（最終段階の承認時のみ・guard: all_stages_approved?）
applying --> rejected  : reject （いずれかの段階で却下）
applying --> canceled  : cancel （申請者の取消）
終端: approved / rejected / canceled
```

撤回（withdrawal_requested / withdrawn）は **2-5** で追加。本スライスでは遷移を定義しない（§7.6 の「イベント未定義で構造防止」と整合）。

### enum 整数マッピング（凍結）

`applying:0 / approved:1 / rejected:2 / canceled:3`。**整数 4=withdrawal_requested・5=withdrawn は 2-5 用に予約・凍結**（AttendanceHistory §4.14 の append-only 規律と同型）。HWR は §4.12 どおり 4 値のまま（撤回 concern を include しない）。

> 2-5 での撤回追加方式（Leave/CCR のみに enum 値 4/5 と撤回イベントを足す `Withdrawable` concern 等）は 2-5 で確定する。本スライスは整数 0–3 を確定し、4/5 を凍結予約するのみ。enum 値集合が `{0,1,2,3}` 完全一致である assert を spec に持つ。

### 起動（§7.7・★MPR: 明示サービス起動）

**after_create は使わない**（原則 §2.2-2: callback は軽微値セットのみ）。初期状態 applying は AASM 初期状態が in-memory で設定し create 時に永続化されるため §7.7（before_create で applying）を AASM 流で充足する。承認エンジンの**起動は明示**:

- 2-2+: 申請作成サービス（例 `LeaveRequests::Create`）が **1 tx 内で `record.save! → Approvals::Start.call(record)`**。`RouteError` は同 tx でロールバックされ「申請不可（セットアップ要）」を構造表現。
- 2-1: 申請作成サービスは無いので、spec が明示的に `Approvals::Start.call(host)` を呼ぶ。`RouteError`（manager 未設定等）は `Start.call` 直叩きで raise を検証。

### 段階進行とイベントの関係（重要）

- 段階ごとの承認は `ApprovalAssignment.decision` の更新であり、status の AASM イベントではない。途中段階の承認中も status は `applying` を維持（§13.2）。
- **最終段階が承認された時のみ**サービスが host の AASM `approve!` を発火。AASM イベントにも `guard: :all_stages_approved?` を付け、「最終承認のみ approved」を**宣言的に state machine 内**へ（サービスの判定と二重化）。却下はどの段階でも `reject!` で全体却下。
- **副作用は 2-1 では一切付けない**（§13.6・イベント単位副作用は対象モデルが現れる 2-2+ で `approve` イベントに紐付け）。

### §7.3 #5 — AASM 限定の徹底（★MPR-B: 迂回経路の網羅）

status は AASM イベント（bang メソッド）経由でのみ変更。**迂回経路を網羅的に封じる**:

1. `update_column` / `update_all` での直接代入を禁止（規約・レビュー）
2. **Rails enum が生成する `approved!`（bang）・`approval_status=`（writer）・mass-assignment** も承認エンジン外から呼ばない。**`approval_status` を strong params に恒久ブロック**（2-2+ controller 契約）。status を動かすのは services が発火する AASM `approve!`/`reject!`/`cancel!` のみ
3. DB トリガ不変化は施さない（status は本来可変ゆえ AttendanceHistory のような不変化は過剰）

> **検証**: 「mass-assignment / 直 update で遷移しない」ことを assert する guard spec を持つ（規約のみに頼らず最小限の回帰検出を置く）。完全な構造強制は行わない旨を明記（trade-off）。

### 導出ヘルパ（status は段階を持たない・2-1 スコープ）

- `current_approval_position` — 最小の pending 段階 position（なければ nil）
- `all_stages_approved?` — 全 assignment が approved（最終 approve のガード）

> `single_stage?` / `pending_approver`（縮約表示・通知向け）は **2-2 へ後置**（YAGNI・呼び出し元が 2-1 に無い）。

### AASM 初導入の留意（★MPR-F・実装で先行検証）

本スライスが repo 初の AASM。**最小 PoC で先に通す**: (a) `Gemfile` に `aasm` 追加（bundle 経由・`block-gemfile-lock-edit` フック）、(b) `enum` を `aasm` より**テキスト上先**に宣言（class ロード時に enum マッピングを読むため）、(c) `whiny_persistence: true` で bang の永続化失敗を例外化、(d) 初期 applying と全遷移を spec で exercise。

---

## 3. ルート解決 — `Approvals::RouteResolver`

`app/services/approvals/route_resolver.rb`（**stateless query service** — `User#manager` を遡る AR 依存ゆえ §2.2-1 の計算 PORO（calculators/）とは区別）。`requester`（User）→ **順序付き承認者配列**（長さ 1 or 2）を返す。長さ 1 = 単段縮約。テナント文脈下で動作（`User#manager` は `acts_as_tenant` でスコープ済 → クロステナントは nil 化 + User 既存検証で二重防御・§3.6）。

### アルゴリズム（共通: `stage1 = requester.manager`）

```
stage1 = requester.manager
raise RouteError(:manager_unset) if stage1.nil?      # manager_id 未設定 → 申請不可（§7.2）

stage2 =
  employee → stage1.manager                          # 部門長（上上長）
  manager  → first_hr_admin_up_chain(requester)      # requester から .manager を遡る最初の hr_admin
  hr_admin → first_hr_admin_up_chain(requester)      # エッジ（自分は始点に含めず自動除外）

approvers = [stage1, stage2].compact.uniq(&:id)      # nil / 同一 → 縮約（★uniq(&:id) で意図明示）
```

`first_hr_admin_up_chain(requester)`: `requester.manager` から `.manager` を上昇し、最初に `hr_admin?` の User を返す。requester 自身は始点に含めないため自動除外。循環は User 既存ガードで不可ゆえ有界。

### 縮約・エラーの分岐（role で挙動が非対称）

| ケース | 結果 |
|---|---|
| employee で stage2 = nil（上長に上長なし） | **[stage1] へ縮約**（許容・「独立性なし」を表示・§7.2） |
| employee/manager で stage2 == stage1（部門長が既に hr_admin 等） | **[stage1] へ縮約**（`.uniq(&:id)`） |
| **manager で hr_admin 不在**（チェーンに hr_admin なし） | **RouteError(:hr_admin_unset)**（Q2 の決定・申請不可） |
| 全 role で manager_id 未設定 | **RouteError(:manager_unset)** |

### §7.3 #3（段階独立）はデータ構造で担保

2 要素ルートでは `.uniq(&:id)` により stage1 ≠ stage2 が保証される（同一人物なら 1 段に縮約され 2 行は作られない）。**これが段階独立の単一ソース**。サービス / ポリシーの #3 は「現段階の担当者本人か（段階順序）」に責務を限定する（独立性の runtime 再検査は冗長ゆえ持たない）。

### エッジ: hr_admin 申請者

§7.2 表は employee/manager のみ定義。hr_admin 申請者は **manager ルートに準拠**（stage1=自分の manager、stage2=チェーン上の*別の* hr_admin）。stage2 が自分しかいなければ縮約で [stage1]、manager も無ければ RouteError。決定論的に処理し spec で固定する（2 sub-branch: 自分のみ hr_admin→縮約 / チェーン上に別 hr_admin→2 段）。

### エラー

`Approvals::RouteError`（理由: `:manager_unset` / `:hr_admin_unset`）。実申請フロー（2-2+）が「申請不可・セットアップ要」として捕捉。2-1 では `Start.call` 直叩きで raise を spec 検証。

---

## 4. 承認サービス + 自己承認防止 — `Approvals::*`

`app/services/approvals/` にコマンドサービス。**既存 idiom に統一**（`def self.call(...) = new(...).call` — `clockings/recalculate.rb` と同型）。全て transaction 内で実行し、決裁時は `approvable.with_lock`（行ロック）で段階進行を直列化（同時承認・二重クリックの競合防止）。

### `Approvals::Start.call(approvable)`

- **明示起動**（after_create は使わない）。2-2 の申請作成サービスが `save!` と同 tx で呼ぶ。2-1 は spec が呼ぶ。
- `RouteResolver` でルート算出 → `position 1..N` の **pending な ApprovalAssignment** を作成。
- **transaction 内実行**。`RouteError` は呼び出し側 tx をロールバック（作成失敗＝申請不可）。
- 冪等: 既に assignment があればスキップ（TOCTOU は UNIQUE `[org,type,id,position]` が一次防御。`RecordNotUnique` で敗者を止める）。

### `Approvals::Approve.call(approvable:, approver:, acting_user: approver, comment: nil)`

**事前ガード（状態変更前に raise）:**

1. **terminal ガード（★MPR-D）**: `approvable.applying?` でなければ AASM `InvalidTransition` 相当で拒否（policy と対称。却下後の残 pending を approve しても黙って更新しない）
2. **acting_user pin（★MPR-C）**: `acting_user.id == approver.id` でなければ `ProxyNotSupported`（2-1 は代理未対応。§7.5 で delegate 認可に置換）
3. **自己承認防止（★MPR-H: 単一ソース `Approvals::SelfApproval`）**:
   - #1 直接: `approver.id != approvable.requester_id`
   - #2 代理: `acting_user.id != approvable.requester_id`（pin により #1 と同値だが規則は明示）
   - 違反は `SelfApprovalError`
4. **段階順序 / 現段階担当**: 現在の pending 段階（`current_approval_position`）の assignment の approver と一致を必須。不一致・段階順序違反（stage2 を stage1 前に）は `NotCurrentApprover`

**処理:** 現段階 assignment を `decision: :approved, acted_at: Time.current, comment:` に更新 → `all_stages_approved?` なら **最終承認として `approvable.approve!`（AASM・guard 二重）発火**（2-1 は副作用なし）。未了なら applying 維持で次段階へ。

### `Approvals::Reject.call(approvable:, approver:, acting_user: approver, comment:)`

- 同じ事前ガード（terminal / pin / 自己承認 / 現段階担当）。`comment`（却下理由）必須（欠落は検証エラー）。
- 現段階 assignment を rejected 記録 → **どの段階でも `approvable.reject!` で全体却下**（残 pending は履歴として残置・行は消さない）。

### 自己承認の単一ソース — `Approvals::SelfApproval`（★MPR-H）

```ruby
module Approvals::SelfApproval
  # 定義は 1 か所。enforce はサービス層と Pundit の二層（§7.3）
  def self.violated?(requester_id:, approver_id:, acting_user_id:)
    approver_id == requester_id || acting_user_id == requester_id   # #1 / #2
  end
end
```
サービスは `(requester_id, approver, acting_user)` で、Pundit は `(requester_id, record.approver_id, user.id)` で**同じ predicate** を呼ぶ。規則の真実源は 1 つ、enforce は二層（drift 防止）。

### 例外

`Approvals::RouteError` / `SelfApprovalError` / `NotCurrentApprover` / `ProxyNotSupported` / AASM `InvalidTransition`（terminal への決裁）。いずれも上位（2-2+ の controller）が握って表示。

### Cancel について（★MPR YAGNI: サービスは後置）

`cancel!` AASM イベント（applying→canceled）は 2-1 の状態機械に存在し、テストホストで直接検証する。**`Approvals::Cancel` サービス + cancel 認可は 2-2 へ後置**（取消アクション/controller が現れる時。`by.id == requester_id` 認可と `cancel?` Pundit を同時に追加）。

### 並行・副作用の前置（★MPR-I: RAILS_GOTCHAS）

§8 参照。`with_lock` 内 tx で SQL 例外を rescue すると偽 success + 更新消失（1-2 で仕留めた罠）。2-2 で `approve` に副作用（残高加算等）を足す時に**真上に着地**するため、本スライスで seam を前置: 失敗し得る後続副作用は **savepoint 隔離 or commit 後**（ClockOut→Recalculate と同構造）に置く設計を 2-2 へ申し送る。

---

## 5. 認可 — `ApprovalAssignmentPolicy`（Pundit・二層防御の片側）

§7.3 は「サービス冒頭 + Pundit」の二重を要求。両者は独立に enforce するが、**自己承認規則の定義は `Approvals::SelfApproval` に一元化**（§4・MPR-H）。対象は **ApprovalAssignment**（承認者が「自分宛の現段階」に対し action する）。

```ruby
class ApprovalAssignmentPolicy < ApplicationPolicy
  def approve? = actionable?
  def reject?  = actionable?

  private

  def actionable?
    record.pending? &&
      record.approvable.applying? &&                                    # terminal は不可
      record.approver_id == user.id &&                                  # 現段階の担当者本人（段階）
      record.position == record.approvable.current_approval_position && # 段階順序
      !Approvals::SelfApproval.violated?(                              # ★#1/#2 を単一 predicate で
        requester_id:  record.approvable.requester_id,
        approver_id:   record.approver_id,
        acting_user_id: user.id
      )
  end
end
```

- **#2 代理の認可側**: Pundit の `user` は実行ユーザ（= acting_user 相当）。`SelfApproval.violated?` が `user.id != requester_id` を内包するため、代理人が requester 本人の場合もここで二重に塞がる。
- **`record.approver_id == user.id`** は 2-1 では正しい（delegate 不在ゆえ厳格）。**§7.5 着地時にここを「user は approver or approver の正規 delegate」へ緩める改修が必須**（前方注記）。
- **Scope は 2-2 へ後置**（YAGNI・インボックス UI と同時）。後置時、terminal approvable 配下の残 pending を返さない絞り（`approvable.applying?` 相当）も同時に入れる。
- **cancel は別系統**: 申請者本人のみ・対象は approvable。`cancel?` Pundit は具体 approvable のポリシーが現れる 2-2 で追加（`Approvals::Cancel` サービスと同時。2-2 controller は `authorize ..., :cancel?` を必ず通し `verify_authorized` を backstop に）。
- controller は 2-1 に無い（UI なし）。ポリシーは pundit-matchers で直接 spec。

---

## 6. テスト戦略

### 検証土台: テスト専用ホスト（`spec/support/approvable_test_model.rb`・★MPR-E）

本番申請モデル不在ゆえ、`Approvable` concern を使い捨てモデルで動かす（concern テストの定石）:

```ruby
class ApprovalTestRecord < ApplicationRecord
  acts_as_tenant(:organization)
  belongs_to :requester, class_name: "User"
  include Approvable
end
```

- **load-order 罠を回避**（★MPR-E・実機裏取り済）: `create_table` は require 時に走らせず、`maintain_test_schema!`（rails_helper の `RSpec.configure` 内）**より後**＝`before(:suite)` で生成する。require 時生成だと、本スライスの `approval_assignments` migration で schema が pending な初回 run に `maintain_test_schema!` が test DB を purge → 一時テーブルが drop（schema.rb 非記載）→ spec 一斉崩壊。完了条件に `bin/rails db:test:prepare` 実行も明記。
- after_create を持たない（明示起動）ので、spec は `Approvals::Start.call(host)` を明示的に呼ぶ。
- `ApprovalTestRecord` 定数が他 spec（`ApplicationRecord.descendants` 等を舐める箇所）へ漏れないか確認。

### spec カバレッジ（テナント文脈下・`gen-spec` 準拠・負例と二層を重視）

| 種別 | ファイル | 主眼（★は MPR 追加の負例・敵対ケース） |
|---|---|---|
| model | `spec/models/approval_assignment_spec.rb` | position(1,2)・一意(org,approvable,position)・decision enum・approver 同一テナント拒否・**★approvable クロステナント拒否（association + 整数 ID 直接代入の fail-closed、`attendance_history_spec` の source 2 本を写経）**・acted_at 整合（両方向）・decision 片道（全逆遷移）・**★毒入力 enum=422（ArgumentError でない）**・**★DB 最終防衛（save(validate:false)→RecordNotUnique / ForeignKeyViolation）** |
| concern | `spec/models/concerns/approvable_spec.rb`（テストホスト） | 初期 applying(§7.7)・approve/reject/cancel 遷移・terminal から InvalidTransition・撤回イベント未定義・**★mass-assignment / 直 update で遷移しない（#5 最小回帰）**・enum 値集合 `{0,1,2,3}` 完全一致・`all_stages_approved?`/`current_approval_position` 正例+負例（rejected 段含み時 false） |
| service | `spec/services/approvals/route_resolver_spec.rb` | employee 2 段 / 浅い縮約・manager+hr_admin / 部門長=hr_admin 縮約・**manager で hr_admin 不在=RouteError**・manager_unset・hr_admin 申請者エッジ（2 sub-branch）・**★クロステナント manager は `validate:false` で越境 manager_id を植え、Resolver が解決せず `:manager_unset`（漏れない）** |
| service | `spec/services/approvals/start_spec.rb` | route 長に応じた assignment 件数・position・approver の正しさ・冪等（再呼出で増えない）・**★RouteError 時に呼び出し側 tx ロールバック（host 未永続・count 不変）** |
| service | `spec/services/approvals/approve_spec.rb` | 単段 final→approved・2 段の段階進行（**★stage1 後に applying 維持の中間 assert**・最終のみ approve! ＝ premature approve! 検出）・**★#1 直接拒否**・**★#2 pin: acting_user≠approver→ProxyNotSupported / acting_user=requester→SelfApprovalError（#1 が通り #2 だけ落ちる敵対 setup）**・段階順序違反→NotCurrentApprover・**★terminal/再決裁→拒否（service 層でも）**・**★rejected 後の残 pending を approve→applying? ガードで拒否** |
| service | `spec/services/approvals/reject_spec.rb` | どの段階でも全体却下・**★comment 欠落拒否**・**★残 pending 残置（行が消えない）**・**★却下後に他段階 approve 不可（terminal）** |
| policy | `spec/policies/approval_assignment_policy_spec.rb` | pundit-matchers で承認者 permit／申請者・第三者・誤段階・terminal・決裁済 forbid・**★`SelfApproval` 経由で #1/#2 を service と同一規則で検証** |
| concurrency | （注記） | **★`with_lock` 直列化は DB 行ロック依存ゆえ transactional fixtures 下で単体困難**。最低限「同一 assignment 二重 approve→2 回目 NotCurrentApprover/InvalidTransition」の冪等 example を置く。真の並行は `use_transactional_tests=false` 隔離 example を検討（or 非テストを明記） |

### 完了条件（CLAUDE.md サブエージェント 3 か条）

- `bin/rails db:test:prepare`（テストホスト一時テーブルの前提）／ `bundle exec rspec` 緑 ／ `bundle exec rubocop --force-exclusion <files>` ／ app/ 変更ゆえ `bin/brakeman --no-pager`
- PR 前に `/preflight`、**ROADMAP の 2-1 行を更新（チェック + PR 番号）して PR に含める**

---

## 7. 新規ファイル一覧（manifest）

| ファイル | 役割 |
|---|---|
| `Gemfile` / `Gemfile.lock` | **`aasm` 追加（bundle 経由）**。repo 初の AASM（★MPR-F） |
| `db/migrate/*_create_approval_assignments.rb` | テーブル + 複合 FK + index（`user_work_patterns` migration を参照実装に） |
| `app/models/approval_assignment.rb` | 実行時状態モデル（テナント検証 2 種・decision 片道・acted_at 整合） |
| `app/models/concerns/approvable.rb` | AASM 業務ステータス（whiny・enum 先宣言）+ `has_many :approval_assignments` + 段階導出（current_approval_position / all_stages_approved?） |
| `app/services/approvals/route_resolver.rb` | 固定 2 段ルート解決・縮約 |
| `app/services/approvals/start.rb` | route → pending assignment 生成（明示起動・tx 内） |
| `app/services/approvals/approve.rb` | 承認（terminal/pin/自己承認/段階順序・最終 AASM） |
| `app/services/approvals/reject.rb` | 却下（全体却下） |
| `app/services/approvals/self_approval.rb` | 自己承認規則の単一ソース（★MPR-H） |
| `app/services/approvals/errors.rb`（任意） | `RouteError` / `SelfApprovalError` / `NotCurrentApprover` / `ProxyNotSupported` |
| `app/policies/approval_assignment_policy.rb` | 自己承認防止の認可層（approve?/reject?。Scope は 2-2） |
| `spec/support/approvable_test_model.rb` | テスト専用ホスト（before(:suite) で一時テーブル生成） |
| `spec/**/*_spec.rb` | 上表のカバレッジ |

**2-2 へ後置（本スライスで作らない）:** `Approvals::Cancel` サービス・`ApprovalAssignmentPolicy::Scope`・ヘルパ `single_stage?`/`pending_approver`・approvable 別 `cancel?` Pundit・承認/取消 controller・UI。

## 8. RAILS_GOTCHAS の留意（実装・レビュー時に注入）

- **with_lock 内 tx で SQL 例外を rescue → 偽 success + 更新消失**（1-2 で仕留めた罠・★MPR-I）。本サービス群は `with_lock` 前提。2-2 で `approve` に副作用を足す時に着地するため、**失敗し得る後続副作用は savepoint 隔離 or commit 後**（ClockOut→Recalculate 構造）に置く seam を前置。
- **AASM bang の偽 success**: `whiny_persistence: true` を必須化（save 失敗を例外化）。Rails enum 生成の `approved!`/writer/mass-assignment は AASM 迂回経路ゆえ strong params で恒久ブロック（§2・★MPR-B）。
- console/rake は `ActsAsTenant.current_tenant` を先に設定（スコープ付きクエリの `NoTenantSet` 回避）。
- rubocop はファイル明示渡し時 `--force-exclusion` 必須（schema.rb 等の Exclude 無視回避）。
- AASM 初導入: `enum` を `aasm` より先に宣言（class ロード時マッピング解決）。最小 PoC で enum 連携を先に通す（★MPR-F）。
- SolidQueue 等のリクエスト無し経路は `ActsAsTenant.with_tenant` ラップ必須（本スライスはバッチ無しだが §7.5 滞留アラート時に該当）。
