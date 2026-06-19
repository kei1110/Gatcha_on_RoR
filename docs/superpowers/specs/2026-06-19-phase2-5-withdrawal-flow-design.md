# Phase 2-5 撤回フロー（承認済の取消・復元）— 設計

- 日付: 2026-06-19
- スライス: ROADMAP Phase 2-5（1 スライス = 1 ブランチ = 1 PR・`feat/phase2-5-withdrawal-flow`）
- 典拠: SPEC §7.6（撤回フロー）・§7.3（自己承認防止・撤回承認にも適用）・§13.2（approval_status AASM・withdrawal 遷移）・§13.6（イベント × `after` 副作用）・§4.14（AttendanceHistory 前後値・追記専用）・§6.7（締め月の申請/撤回制限）・§3.4–3.6（認可・テナント分離）・§14（after_commit 継ぎ目）
- 前提エンジン: Phase 2-1（承認エンジン）+ 2-2a/2-2b（`Approvable` hook・`Approvals::Approve/Reject/Start/Cancel`・`ApplyApproval` パターン・承認インボックス・`Clockings::Recalculate`）+ 2-3（CCR・前後値充填）+ 2-4（HolidayWorkRequest）はすべて据付・merge 済（**main = 2-4 完了**）
- **2-4 が効く前提**: HWR も `include Approvable`（`approval_status` AASM 共有）。だが §4.12/§13.3 は HWR を**撤回フロー無し・approved 終端**と定める。よって撤回 state/event を共有 `Approvable` に足すと HWR に漏れる → **撤回を別 concern `Withdrawable` へ分離**（D7）
- **本設計のブレスト確定事項（2026-06-19・`superpowers:brainstorming`）**: 下記 D1–D7 をユーザー承認済み
- **多視点レビュー反映（2026-06-19・`/multi-perspective-review` 5 視点並列）**: Critical 2 件（R1 purpose uniqueness・R2 残高述語）＋ Med/Low 多数を反映済（§8.1 反映ログ）。両 Critical は実コードで裏取り済

## 0. スコープと前提

2-1〜2-3 で「申請 → 固定 2 段承認 → 副作用（残高・記録・履歴）」が一周した。2-5 は最後のピース、**承認済レコードの撤回**を据える。`approved` のレコードを申請者が取り下げ、管理者が承認すると**副作用を逆操作で巻き戻す**（残高減算・記録復元・履歴記録）。承認待ち中の取り下げ（`canceled`・`Approvals::Cancel`・2-2a）とは別物。

撤回の「承認」も固定 2 段ルートを通す（**承認エンジンを全面再利用**）。型固有の新ロジックは**逆操作サービス 2 本**（`LeaveRequests::Withdraw` / `ClockChangeRequests::Withdraw`）に局所化される。エンジン本体は「現状態に応じて適切な AASM イベントを撃ち分ける」汎用化を施す（対象型・承認/撤回の双方に対称）。

完了条件: LR / CCR とも **撤回申請 → 2 段承認 → withdrawn + 復元（残高/記録/履歴）まで一周**し、かつ**撤回却下 → approved 復帰で承認副作用が再発火しない**こと。これで ROADMAP Phase 2 の完了条件「撤回で復元できる」を満たす。

### 設計判断ログ

| # | 論点 | 決定 | 根拠 |
|---|------|------|------|
| D1 | 撤回承認の経路 | **既存固定 2 段エンジンを全面再利用**。`request_withdrawal` で `Approvals::Start(purpose: :withdrawal)` を再呼び出しし、新 `ApprovalAssignment` 世代（position 1/2・同 `RouteResolver` の manager 階層）を生成。インボックス・自己承認防止・Policy::Scope・縮約をそのまま流用 | §7.6「管理者が承認/却下」は単数表現だが、§7.3 が「撤回承認にも自己承認防止を適用」＝承認者 ≠ 申請者を要求。元承認と同じ manager 階層で承認することで対称性と自己承認防止を既存機構で担保。承認/撤回で別経路を作らない（YAGNI） |
| D2 | 撤回世代の assignment 分離 | **`approval_assignments.purpose` enum `{approval, withdrawal}` を追加**し unique index を `[org, type, id, purpose, position]` へ拡張。導出（`current_approval_position` 等）は host 状態由来の `active_purpose` でスコープ | **構造的制約からの帰結**: 旧 assignment（position 1/2・全 approved）は監査として残す必要があり、`decision` は一方向（approved→pending 不可・既存検証）ゆえ再利用不可。同 approvable に position 1/2 を再作成すると現 unique index に衝突。`round` カウンタより `purpose` enum が表現に忠実（v1 は撤回 1 回・後述 D6） |
| D3 | LeaveRequest 撤回の AR 復元 | **`LeaveRequests::ApplyApproval` の逆関数**（現 AR から逆算・2-2b は無変更）。counted_dates 各日で `clock_in & clock_out` あり→`status=clocked_out` + `Recalculate`／無→`destroy`。残高は `lock!` 減算、`leave_withdrawn` 履歴 1 行 | 現 `leave_approved` 履歴は `event_date` のみで承認前 AR 状態を snapshot していない（2-2b under-fill）。承認時の正方向変換は決定的ゆえ逆算可能。承認時 snapshot 案（2-2b ApplyApproval 改修 + 履歴粒度 per-day 化）は完了済コードを触り blast radius 大ゆえ却下。v1 は `on_leave` 日への打刻付与が構造上起きず逆算が成立 |
| D4 | ClockChangeRequest 撤回の復元 | **`original_*` へ復元**。`lock.find` AR → 競合チェック（現値 == `new_*`）→ `original_clock_in/out` 復元 → save → `Recalculate` → `clock_change_withdrawn` 履歴（前後値充填） | CCR は `original_*`（Create snapshot）と `new_*`（要求値）を保持（2-3 D6・前後値充填済）。LR と異なり履歴/列から正確復元が可能。競合チェックは正方向（original 照合）の鏡像（new 照合） |
| D5 | 副作用のイベント束縛 | **撤回承認 `approve_withdrawal` に `apply_withdrawal_effects!` を、撤回却下 `reject_withdrawal`（→approved）には副作用を付けない**。エンジンは host 状態で hook を撃ち分け（同一 `with_lock`/tx・内側 rescue なし） | §13.6: 副作用は状態でなくイベントに束縛。`reject_withdrawal` で approved へ戻る際に承認副作用を再発火させると残高二重加算・履歴二重記録。2-2b/2-3 の atomic rollback パターンを撤回方向に踏襲 |
| D6 | 再撤回（撤回却下後の再申請） | **v1 は不可**。`approved? && 撤回世代の assignment なし` でのみ撤回申請を許可（ボタン非表示 + `RequestWithdrawal` ガード + AASM event guard） | 一度撤回却下されたら原承認が確定。再撤回を許すと purpose=withdrawal の position が衝突し `round` カウンタが必要になり複雑化（YAGNI）。修正は Phase 3 の管理者差戻し（deferred）へ。§13.2 図の `approved → withdrawal_requested` は一般遷移だが v1 は世代単一に絞る |
| D7 | 撤回 state/event の置き場 | **別 concern `Withdrawable`（`include Approvable` + aasm 再オープンで撤回 state/event 追加）を新設**。LR/CCR は `Withdrawable`、**HWR は `Approvable` のまま**。enum 0–5 は `Approvable` が単一ソース（HWR は 4/5 を宣言するが到達不能ゆえ無害） | 2-4 で HWR も `Approvable` 共有。撤回 3 イベントを `Approvable` に置くと HWR が `request_withdrawal`（from approved）を獲得し §4.12/§13.3（撤回フロー無し・approved 終端）に違反。AASM は宣言 `state` のみを状態化し未使用 enum 値を無視するため、enum を割らず concern 分離で隔離（最小 blast radius・HWR/2-4 のコード無変更） |

### 本スライスに含めない（明示的後置）

- **§6.7 締め月の撤回制限** → **前方フックのみ**（§6 で挿入点コメント）。`MonthlyAttendanceSummary` は Phase 3-1 まで不在ゆえ実装不可。2-2a/2-2b/2-3 の新規作成制限後置と同型
- **撤回承認/却下/滞留の通知送信**（管理者への撤回申請通知・申請者への却下理由通知）→ **Phase 4-1**（通知基盤確立まで・ROADMAP 横断ルール）。本スライスは flash + `comment` 記録で代替
- **再撤回**（撤回却下後の再申請・D6）→ v1 非対応（`round` カウンタ導入は将来）
- **HolidayWorkRequest の撤回** → 仕様上撤回フローを持たない（§4.12・§13.3・4 値）。`Withdrawable` を include しないことで構造的に排除（D7）。**HWR が撤回イベントを獲得しない回帰テストを置く**
- **型別 preload 最適化**（インボックス N+1）→ バックログ継続（§16.1 許容・撤回行が混ざるが型非依存 includes は据置）

---

## 1. モデル / スキーマ

### 1.1 マイグレーション（2 本）

#### A-1 `add_purpose_to_approval_assignments`

| 変更 | 内容 |
|---|---|
| カラム追加 | `purpose` integer NOT NULL default 0（`{approval: 0, withdrawal: 1}`） |
| index 差し替え | 既存 `index_approval_assignments_unique_stage`（`[org, type, id, position]` unique）を drop → `[org, type, id, purpose, position]` unique で再作成 |

- 既存行は default 0（approval）でバックフィルされ整合（2-1〜2-3 の assignment はすべて approval 世代）。
- `decision` 一方向検証は既存のまま（撤回世代も pending→approved/rejected）。

#### A-2 `add_withdrawal_reason_to_leave_requests`

| 変更 | 内容 |
|---|---|
| カラム追加 | `withdrawal_reason` text NULL |

- CCR は 2-3 で既に `withdrawal_reason` を予約済（schema.rb・本スライスが消費）。LR のみ未追加ゆえ本 migration で対称化。

#### `attendance_histories.event_type` に `clock_change_withdrawn` 追加 → **migration 不要**

- 既存 integer 列への**アプリ enum マッピング追加**（`clock_change_withdrawn: 9`）のみ。append-only taxonomy の末尾拡張（§4.14・リオーダ禁止）。`leave_withdrawn: 3` は既存予約を使用。
- **【R8・SSOT 同期必須】** `clock_change_withdrawn` は現 SPEC §4.14（L509）の凍結 9 値列挙に**無い新値**。同一 PR で (1) SPEC §4.14 列挙へ `clock_change_withdrawn`（10 値目・整数 9・末尾固定）を追記、(2) `app/models/attendance_history.rb` の「全 9 値を順序固定する taxonomy」コメントを「全 10 値」へ更新——を必須化（怠ると SSOT ドリフト）。

> create-migration スキルの規約（複合 FK は本変更で新設なし・`purpose` は既存テーブルへの列追加・partial index 不要）に従い、`bin/rails g migration` 後に手で index 差し替えを記述。schema.rb は migration 経由でのみ更新（手編集禁止フック）。

### 1.2 `ApprovalAssignment`（purpose 追加）

```ruby
class ApprovalAssignment < ApplicationRecord
  # 既存: acts_as_tenant, belongs_to approvable/approver, decision enum, 一方向検証, 同一テナント検証
  enum :purpose, { approval: 0, withdrawal: 1 }, validate: true, prefix: :purpose
  # 【R1・必須】既存 position uniqueness の scope に :purpose を追補（DB index と対称化）。
  #   現行: validates :position, uniqueness: { scope: [:organization_id, :approvable_type, :approvable_id] }
  #   改修: validates :position, uniqueness: { scope: [:organization_id, :approvable_type, :approvable_id, :purpose] }
  validates :position, uniqueness: { scope: [:organization_id, :approvable_type, :approvable_id, :purpose] }
  # validates :position, inclusion: { in: [1, 2] } は据置（撤回世代も 1/2）
end
```

- `purpose` は `Approvals::Start` が生成時に付与（既定 approval）。表示（インボックス行のバッジ）に使用。
- **【R1 重大】** モデル uniqueness に `:purpose` を**追補必須**。据置すると `Start(purpose: :withdrawal)` の position 1 `create!` が既存 approval 世代 position 1 と衝突し `RecordInvalid` → 撤回が起動段階で全滅する（DB index 差し替えだけでは不足・モデル検証が `create!` で手前で発火）。多視点レビュー 5 視点全一致の最優先指摘。

---

## 2. AASM 状態機械（`Approvable` 基底 + `Withdrawable` 分離・D7）

### 2.0 concern 分割の全体像

| concern | 含む host | 役割 |
|---|---|---|
| `Approvable`（既存・拡張） | LR / CCR / **HWR** | enum 0–5（taxonomy 単一ソース）・基底 4 状態 + `approve`/`reject`/`cancel`・purpose スコープ導出・`awaiting_decision?`・`apply_withdrawal_effects!` 既定 no-op |
| `Withdrawable`（**新設**） | LR / CCR のみ | aasm 再オープンで撤回 2 状態 + 3 イベント・`no_prior_withdrawal_round?` |

- **HWR は `Approvable` のみ**ゆえ撤回イベントを持たない（§4.12/§13.3 構造的遵守）。
- enum 4/5 は `Approvable` が宣言するが、HWR は撤回 `state` を持たず到達不能（AASM は宣言 state のみ状態化）。
- **guard 版（`Approvable` に撤回イベントを置き `guard: :withdrawable?` で HWR を default-false 排除）を却下した理由**: guard が false でも**イベント自体は HWR に定義される**（`request_withdrawal!` が `NoMethodError` でなく `InvalidTransition` を返す＝「存在するが今は不可」）。§13.3 が要求するのは「HWR は撤回フローを**持たない**」＝構造的非獲得（`respond_to?` false）。concern 分離はこの要件を型レベルで満たし、防御の質が高い（TDD ①で回帰固定）。代償は concern 1 つと aasm 再オープンの subtlety だが、上記 TDD ③④で担保。

### 2.1 `Approvable`（基底・enum 0–5 + 基底機械 + 導出）

```ruby
# enum を全 6 値で宣言（§15 taxonomy 単一ソース・4/5 は Withdrawable が状態化）
enum :approval_status, {
  applying: 0, approved: 1, rejected: 2, canceled: 3,
  withdrawal_requested: 4, withdrawn: 5
}

aasm column: :approval_status, enum: true, whiny_persistence: true do
  state :applying, initial: true
  state :approved
  state :rejected
  state :canceled
  # 撤回 2 状態は Withdrawable が aasm 再オープンで追加（HWR には付かない）
  event :approve do
    transitions from: :applying, to: :approved, guard: :all_stages_approved?
  end
  event :reject do
    transitions from: :applying, to: :rejected
  end
  event :cancel do
    transitions from: :applying, to: :canceled
  end
end
```

導出メソッド（purpose スコープ化・`Approvable` 本体）:

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

> `active_purpose` は enum 述語 `withdrawal_requested?`（全 host が応答・HWR は常に false）に依存するため `Approvable` に置ける。HWR では常に `:approval` を返し、既存挙動と完全互換。

### 2.2 `Withdrawable`（新設・撤回 state/event）

```ruby
module Withdrawable
  extend ActiveSupport::Concern
  include Approvable                       # 基底 + enum + 導出を継承

  included do
    aasm do                               # 同一状態機械を再オープンし撤回分を追加
      state :withdrawal_requested
      state :withdrawn

      event :request_withdrawal do
        # D6: 再撤回不可ガード（撤回世代が既にあれば遷移不可＝構造防御）
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

- LR / CCR は `include Approvable` → **`include Withdrawable`** に差し替え（`Withdrawable` が `Approvable` を内包）。
- `withdrawal_requested` では `approve`/`reject`（applying 起点）が**未定義のまま**＝承認エンジンの再起動を `InvalidTransition` で構造的に防ぐ（§7.6・§13.2）。
- `active_purpose` 1 つで全導出をスコープし、旧 approval 世代（全 approved）と新 withdrawal 世代が混ざらない。`approve_withdrawal` の `all_stages_approved?` は purpose=withdrawal の assignment のみ判定。

> **TDD 検証点（concern 再オープンが load-bearing ゆえ必須）**:
> ①`HolidayWorkRequest.new.respond_to?(:request_withdrawal)` が false（撤回イベント非獲得・D7）
> ②enum 0–5 宣言下で HWR が states 0–3 のみで正常ロード（AASM が未使用 enum 値を許容）
> ③**実遷移**: `request_withdrawal!` 後 `reload.approval_status` が DB 整数 4・`withdrawal_requested?` true（enum マッピング継承）
> ④**whiny_persistence 継承**: 故意に save を失敗させた `approve_withdrawal!` 等が **false でなく例外**を上げる（再オープン機械が基底の `whiny_persistence: true` を継承する保証・半端コミット穴の封鎖）
> ①〜④は model spec の最初に。`respond_to?`/ロードだけでは ③④の永続穴を踏まない。
>
> **実装注記**: `Withdrawable` の `include Approvable` により AS::Concern は Approvable の `included`（enum + 基底 aasm）を先に評価してから Withdrawable の `included`（aasm 再オープン）を走らせる。この順序前提をコメントで明示（順序が崩れると再オープンが基底機械を見つけられない）。

---

## 3. エンジン汎用化（`Start`/`Approve`/`Reject` + 新 `RequestWithdrawal`）

### 3.1 `Approvals::Start`（purpose パラメータ化）

```ruby
def self.call(approvable, purpose: :approval) = new(approvable, purpose:).call

def call
  return @approvable if @approvable.approval_assignments.where(purpose: @purpose).exists? # 冪等（purpose 毎）

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

- 冪等チェックを `where(purpose:)` スコープへ。approval 世代は 2-2/2-3 で既存ゆえ撤回時に再生成されない。

### 3.2 `Approvals::Approve`（状態で撃ち分け）

```ruby
def call
  @approvable.with_lock do
    guard!                                    # awaiting_decision? へ一般化
    assignment = current_assignment!          # active_purpose スコープ
    assignment.update!(decision: :approved, acted_at: Time.current, comment: @comment)
    finalize! if @approvable.all_stages_approved?
  end
  @approvable
end

private

def guard!
  raise AASM::InvalidTransition.new(@approvable, :approve, :default) unless @approvable.awaiting_decision?
  raise ProxyNotSupported unless @acting_user.id == @approver.id
  raise SelfApprovalError if SelfApproval.violated?(
    requester_id: @approvable.requester_id, approver_id: @approver.id, acting_user_id: @acting_user.id
  )
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

- 自己承認防止は既存 `SelfApproval.violated?` がそのまま撤回承認にも効く（撤回世代も `RouteResolver(requester)` 由来＝approver ≠ requester・§7.3）。

### 3.3 `Approvals::Reject`（状態で撃ち分け）

```ruby
def call
  raise ArgumentError, "却下理由が必要です" if @comment.blank?
  @approvable.with_lock do
    guard!                                    # awaiting_decision? へ一般化（applying/withdrawal_requested）
    assignment = current_assignment!
    assignment.update!(decision: :rejected, acted_at: Time.current, comment: @comment)
    @approvable.withdrawal_requested? ? @approvable.reject_withdrawal! : @approvable.reject!
  end
  @approvable
end
```

- `reject_withdrawal!` は approved へ戻すのみ（**副作用なし**・D5）。撤回世代の assignment は rejected で残置（監査）。host は approved に戻るが `awaiting_decision?` が false ゆえ残 pending assignment は inbox で actionable にならない（既存 reject と同挙動）。

### 3.4 新 `Approvals::RequestWithdrawal`

```ruby
module Approvals
  class RequestWithdrawal
    def self.call(approvable:, requester:, reason:) = new(approvable:, requester:, reason:).call

    def call
      raise ArgumentError, "撤回理由が必要です" if @reason.blank?
      @approvable.with_lock do
        raise NotRequester unless @requester.id == @approvable.requester_id      # §7.6 申請者本人
        # request_withdrawal! の guard（approved? + no_prior_withdrawal_round?）が
        # AASM::InvalidTransition を構造的に発火（D6 再撤回防止 + terminal 防御）
        @approvable.withdrawal_reason = @reason
        @approvable.request_withdrawal!                                          # approved → withdrawal_requested（reason 同時 save）
        Approvals::Start.call(@approvable, purpose: :withdrawal)                 # 撤回世代の assignment 生成
      end
      @approvable
    end
  end
end
```

- `withdrawal_reason` を set してから bang（`whiny_persistence` で同一 save に乗る）。
- **【R-presence】** LR/CCR に条件付き presence 検証を追補（service 層 `ArgumentError` と二層化）: `validates :withdrawal_reason, presence: true, if: :withdrawal_requested?`（SPEC §7.6・L422「撤回理由＝撤回申請時必須」）。`Withdrawable` concern に置けば LR/CCR 対称。

---

## 4. 副作用サービス（逆操作・`ApplyApproval` と対称）

### 4.1 `LeaveRequests::Withdraw`（`apply_withdrawal_effects!` 実体）

```ruby
# host: LeaveRequest#apply_withdrawal_effects!(acting_user:) = LeaveRequests::Withdraw.call(...)
# 呼び出し元: Approvals::Approve#finalize!（approve_withdrawal の with_lock 内・同一 tx）。
# 内側 rescue せず raise 伝播（撤回承認ごと atomic rollback）。
# 処理順: ① 残高減算（paid のみ）→ ② per-day AR 復元 → ③ leave_withdrawn 履歴。
def call
  ActsAsTenant.with_tenant(@leave_request.organization) do
    remove_from_balance
    restore_attendance_records
    record_history
  end
  @leave_request
end

private

# 【R2・必須】正方向 add_to_balance と同一述語 balance_tracked?（= paid_leave? || compensatory_leave?）。
# paid_leave? 単独だと代休（compensatory_leave・2-4）撤回で減算されず残高が永久リークする
def remove_from_balance
  return unless @leave_request.leave_type.balance_tracked?
  fiscal_year = @leave_request.organization.fiscal_year_for(@leave_request.start_date)  # §6.2 統一
  balance = LeaveBalance.where(user_id: @leave_request.requester_id,
                               leave_type_id: @leave_request.leave_type_id, fiscal_year:).lock.first
  return if balance.nil?                                  # 防御（承認時に加算済が正・無ければ no-op）
  new_used = balance.used_days - @leave_request.days_requested
  Rails.error.report(...) if new_used.negative?          # 【R6】0 clamp が異常を握り潰さないよう観測
  balance.update!(used_days: [new_used, BigDecimal("0")].max)  # 負値ガード
end

# 【R3+R4】counted_dates を再計算せず、範囲内の leave-status AR から復元対象を抽出。
# これでカレンダードリフト両方向（取り残し／無関係 AR 破壊）と working AR の打刻喪失を一掃。
# leaves は 1 日 1 AR（unique [user, work_date]）ゆえ範囲内の leave-status AR = この休暇の日。
def restore_attendance_records
  AttendanceRecord
    .where(user_id: @leave_request.requester_id,
           work_date: @leave_request.start_date..@leave_request.end_date,
           status: %i[on_leave morning_half afternoon_half])
    .find_each do |record|
      if record.clock_in.blank?
        record.destroy!                                  # 休暇が新規作成した無打刻日 → 消す
      else
        # 打刻が残る日（半休 or working 上書き）→ 打刻状態へ戻す（clock_in を喪失しない）
        record.update!(status: record.clock_out.present? ? :clocked_out : :working)
        Clockings::Recalculate.call(record:) if record.clock_out.present?  # 半休免除を解除
      end
    end
end

def record_history
  AttendanceHistory.create!(
    user_id: @leave_request.requester_id, actor: @acting_user, source: @leave_request,
    event_type: :leave_withdrawn, event_date: @leave_request.start_date
  )
end
```

> **逆算の妥当性（D3・多視点レビュー反映後）**: 正方向 `ApplyApproval` は counted_dates に `status=leave_status` を置いた。逆操作は **counted_dates を再計算せず、範囲内で leave-status を持つ AR を直接対象**にする（カレンダー変更で counted_dates がずれても、実際に休暇が触れた AR だけを正確に巻き戻す）。各日の分岐は「**打刻 `clock_in` が残る → 打刻状態（clock_out 有=clocked_out / 無=working）へ戻す + recalc**／打刻無 → 休暇が作った日ゆえ destroy」。これにより (a) カレンダードリフト両方向、(b) `working`（clock_in のみ）AR を destroy して打刻喪失、(c) 無関係 clocked AR の誤破壊——をすべて回避。`§14` の after_commit 継ぎ目は本 `record_history`（leave_withdrawn）が兼ねる。

### 4.2 `ClockChangeRequests::Withdraw`

```ruby
# 処理順: ① FOR UPDATE ② 競合チェック（現値 == new_*）③ original_* 復元 ④ §5 再計算 ⑤ 前後値 history。
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

# 承認時に適用した new_* が現値と一致するか（間に別変更が入っていないか）。正方向の鏡像
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
```

- `snapshot` は 2-3 `ApplyApproval` と同型（`record.slice(...)`）。`clock_change_withdrawn` の前後値 = 復元前（new_*）→ 復元後（original_*）。

### 4.3 host hook override（LR/CCR は `include Withdrawable` へ差し替え）

```ruby
# LeaveRequest: include Approvable → include Withdrawable
def apply_withdrawal_effects!(acting_user:) = LeaveRequests::Withdraw.call(leave_request: self, acting_user:)
# ClockChangeRequest: include Approvable → include Withdrawable
def apply_withdrawal_effects!(acting_user:) = ClockChangeRequests::Withdraw.call(clock_change_request: self, acting_user:)
# HolidayWorkRequest: include Approvable のまま（撤回 hook は基底 no-op を継承・呼ばれない）
```

### 4.4 `AttendanceHistory` 検証追補

```ruby
validates :actor_id, presence: true, if: :leave_withdrawn?          # 2-5（不変ゆえ事前防御）
validates :actor_id, presence: true, if: :clock_change_withdrawn?   # 2-5
```

---

## 5. 認可 / Controller / UI

### 5.1 Policy

```ruby
# LeaveRequestPolicy / ClockChangeRequestPolicy（対称）
def request_withdrawal?
  record.requester_id == user.id && record.approved? && record.no_prior_withdrawal_round?
end

# ApprovalAssignmentPolicy#actionable? — applying? を awaiting_decision? へ一般化
def actionable?
  record.pending? &&
    record.approvable.awaiting_decision? &&                          # applying or withdrawal_requested
    record.purpose == record.approvable.active_purpose.to_s &&       # 【R7】active 世代の assignment のみ（防御的・サービス層と対称）
    record.approver_id == user.id &&
    record.position == record.approvable.current_approval_position &&
    !Approvals::SelfApproval.violated?(
      requester_id: record.approvable.requester_id,
      approver_id: record.approver_id, acting_user_id: user.id
    )
end
```

- インボックス Scope（`approver_id == user && pending`）は無変更。撤回世代の pending も自然に拾われ、`approve?`（actionable?）で現段階のみ通る。
- **【R7】** `record.purpose == active_purpose` 照合は防御的（不変条件「pending=active 世代のみ」に暗黙依存せず明示制約化・サービス層 `current_assignment!` と対称・将来 round 導入時の回帰防止）。enum 比較は文字列同士（`active_purpose` は symbol ゆえ `.to_s` で揃える — 実装時に enum 述語 `purpose_withdrawal?` 等での表現も可）。

### 5.2 Controller

```ruby
# LeaveRequestsController / ClockChangeRequestsController に member PATCH
# 【R5】before_action を cancel と共有し policy_scope 経由で resolve（他人/他テナントは 404・テスト計画 §7 準拠）
before_action :set_leave_request, only: %i[show cancel request_withdrawal]
def set_leave_request = (@leave_request = policy_scope(LeaveRequest).find(params[:id]))

def request_withdrawal
  authorize @leave_request, :request_withdrawal?
  Approvals::RequestWithdrawal.call(approvable: @leave_request, requester: current_user,
                                    reason: params.require(:leave_request).permit(:withdrawal_reason)[:withdrawal_reason])
  redirect_to @leave_request, notice: "撤回を申請しました。承認をお待ちください。"
rescue AASM::InvalidTransition, Approvals::NotRequester
  redirect_to @leave_request, alert: "この申請は撤回できません。"
rescue Approvals::RouteError                                  # 【R6】承認者不在（manager 離脱等）
  redirect_to @leave_request, alert: "承認経路を解決できません。管理者にご連絡ください。"
rescue ArgumentError, ActiveRecord::RecordInvalid => e        # 撤回理由 blank / bang 再検証失敗
  redirect_to @leave_request, alert: e.message
end
```

- **インボックスの approve/reject は既存アクションがそのまま撤回承認/却下に振る舞う**（3.2/3.3 の状態分岐が吸収）。撤回専用の承認アクションは作らない。
- ルート: `resources :leave_requests do member { patch :request_withdrawal } end`（CCR 同型）。
- **【R6】** `Approvals::RouteError`（`RouteResolver` が承認者を解決できない・承認後に manager が組織離脱等）と、bang 再検証の `ActiveRecord::RecordInvalid` を rescue に追加（無処理だと 500）。

### 5.3 View

- **申請 show**: `policy(@req).request_withdrawal?` のとき「撤回申請」セクション（`withdrawal_reason` textarea 必須 + PATCH ボタン）。`withdrawal_requested` 中は「撤回承認待ち」バッジ + reason 表示。`withdrawn` は終端表示。
- **インボックス行**: `assignment.purpose_withdrawal?` で「**撤回承認**」バッジを出し、通常承認と視覚区別（行の approve/reject ボタンは共通）。撤回承認時は「この申請を撤回（取消）します」の確認文言。
- **【R9】** `ApprovalAssignmentsController#approve` の `ConflictError` rescue 文言は現状「変更前時刻が現在の記録と一致しません（申請者へ再申請をご依頼ください）」。撤回承認文脈で同文言は的外れゆえ、`assignment.purpose_withdrawal?` で「対象記録が変更されているため撤回できません」へ分岐（機能影響なし・UX のみ）。
- 撤回却下理由の申請者通知は Phase 4-1 まで保留（`comment` は assignment に記録済）。

---

## 6. §6.7 締め月制限（前方フックのみ・本スライス未実装）

`MonthlyAttendanceSummary` が Phase 3-1 まで不在ゆえ実装不可。挿入点をコメントで残す（2-2a/2-2b/2-3 と同方針）:

```ruby
# LeaveRequest / ClockChangeRequest
# TODO(Phase 3-2 §6.7): submitted/finalized 月の対象日への新規作成を制限（対象日の MonthlyAttendanceSummary.status 参照）

# Approvals::RequestWithdrawal
# TODO(Phase 3-2 §6.7): submitted/finalized 月への撤回申請を制限（HWR は撤回フロー無ゆえ対象外）
```

---

## 7. テスト計画

| 層 | 対象 | 主眼 |
|---|---|---|
| model | `Withdrawable`（AASM 撤回 3 イベント・`no_prior_withdrawal_round?` guard）・`Approvable`（`active_purpose` スコープ導出・`awaiting_decision?`）・enum 整数 4/5 凍結・`ApprovalAssignment.purpose` enum + unique index・**HWR 回帰**（`respond_to?(:request_withdrawal)` == false・states 0–3 で正常ロード） | `withdrawal_requested` で `approve`/`reject` が `InvalidTransition`（§7.6 構造防御）。撤回世代が approval 世代と混ざらない導出。HWR に撤回が漏れない（D7） |
| service | `Approvals::RequestWithdrawal`（本人/reason/再撤回ガード）・`LeaveRequests::Withdraw`（**代休往復で残高 0 復帰=R2**・clocked_out/working 復帰 + recalc・**working AR を destroy しない=R3**・無打刻日 destroy・leave_withdrawn 履歴）・`ClockChangeRequests::Withdraw`（original 復元・競合・clock_change_withdrawn 前後値）・**`reject_withdrawal` で副作用非発火** | atomic rollback（Withdraw 内 raise → 撤回承認ごと巻き戻し）。テナント分離（`with_tenant`）。残高/履歴の二重化は count assertion |
| request | 撤回申請 → 2 段承認 → `withdrawn` + 復元の一周（LR/CCR）・撤回却下 → `approved` 復帰で**残高/履歴が二重化しない**・他人/他テナントの撤回申請は **404**（R5）・撤回承認の自己承認防止・**`RouteError`/再撤回が alert で 500 にならない（R6）** | エンジン全経路の統合 |
| policy | `request_withdrawal?`（本人 && approved && 撤回世代なし）・`actionable?` 一般化（撤回承認が actionable・terminal 不可） | 認可二層 |
| system（任意） | 申請 show の撤回ボタン → インボックス撤回承認 → 復元の UI 一周 | 主要動線 |

- spec 雛形は `/gen-spec`（テナント文脈ラップ）。残高/履歴の二重化検出は count assertion で。

---

## 8. ハンドオフ / 既知の限界

1. **再撤回 v1 不可（D6）**: 撤回却下後は原承認確定。`round` カウンタ導入は将来テーマ。
2. **§6.7 締め月制限は前方フックのみ**（§6）。Phase 3-2 で `MonthlyAttendanceSummary.status` 参照のバリデーションを LR/CCR + `RequestWithdrawal` に実装。
3. **通知送信は Phase 4-1**（撤回申請通知・却下理由通知）。本スライスは flash + `comment` 記録。
4. **LR 復元の前提（D3・多視点レビューで堅牢化済）**: 範囲内の leave-status AR を直接対象にする方式により counted_dates ドリフト両方向を解消（§4.1）。残る前提は「同一日に複数休暇が重ならない（1 日 1 AR の unique で構造担保）」のみ。`on_leave` 日への打刻付与（半々の後続打刻・バックログ）が将来入っても、本方式は「打刻が残れば打刻状態へ戻す」ため破壊しない。
5. **clocked 済 AR への全休承認（2-2b バックログ・stale 列）**: 本逆算は「打刻あり→clocked_out/working + recalc」ゆえ撤回時にむしろ stale を癒すが、根治は当該バックログ側。
6. **撤回申請の取り下げ経路は v1 無し**（completeness gap・意図的省略）: `applying` の `cancel` に相当する `cancel_withdrawal`（withdrawal_requested→approved・副作用なし）は v1 未実装。誤った撤回申請からの脱出は管理者の `reject_withdrawal` 待ち。将来対称性のため検討項目。
7. **leave_withdrawn 履歴は申請単位 1 行**（CCR の per-day 前後値と非対称）: 複数日休暇の per-day 復元（destroy/clocked_out 復帰）の個別監査は AR 更新ログに依存。正方向 `leave_approved` 踏襲だが destroy を含む分、将来 per-day 履歴化の検討余地。
8. **`Start` のネスト tx は savepoint 無し（R11）**: `RequestWithdrawal#with_lock` 内の `Start` が `ApprovalAssignment.transaction`（savepoint なし）で `create!`。R1 修正（モデル検証で手前で弾く）後は `RecordNotUnique` が DB まで到達しないが、二重クリック競合の保険として `transaction(requires_new: true)` 適用要否を実装時に判断（RAILS_GOTCHAS savepoint idiom）。
9. **`new_entry` CCR 解禁時の FK（Phase 4-2）**: 撤回 `destroy!` 対象が無打刻 AR の場合、4-2 で `new_entry` CCR（打刻無 AR 対象）が解禁されると `InvalidForeignKey` 経路が顕在化し得る。4-2 で「撤回 destroy 前の依存 CCR チェック」を必須化（本スライスは clocked_out 限定ゆえ未発火）。
10. **after_commit 継ぎ目（§14）**: `leave_withdrawn` / `clock_change_withdrawn` 履歴記録が将来 Gatcha Work 連携の publish 点を兼ねる（`leave_approved` と対称）。
11. **エンジン非同期化時の fail-closed**: 撤回承認をジョブ化する際は dispatcher で `ActsAsTenant.with_tenant(org)` ラップ必須（エンジン本体 `Approve`/`Start` は request 文脈前提・§3.6）。逆操作 `Withdraw` は副作用層で既にラップ済。
12. **レビュー**: `approval-engine-reviewer`（撤回 AASM・自己承認・副作用 atomicity・イベント束縛）+ `tenant-isolation-reviewer`（purpose 列・Withdraw の `with_tenant`・複合 index）を merge 前に PROACTIVELY。`/spec-check` は Phase 2 完了確認で。
13. **検証コマンド**: `bundle exec rspec` / `bundle exec rubocop --force-exclusion` / `bin/brakeman --no-pager`。

### 8.1 多視点レビュー反映ログ（2026-06-19・5 視点並列 critique）

| ID | 重要度 | 指摘 | 反映 |
|---|---|---|---|
| R1 | **Critical（5 視点全一致）** | `ApprovalAssignment` uniqueness が `purpose` 非包含 → 撤回世代生成が `RecordInvalid` で全滅 | §1.2: scope に `:purpose` 追補を**必須化**（「据置」選択肢削除） |
| R2 | **Critical** | 残高減算が `paid_leave?`（正方向は `balance_tracked?`）→ 代休撤回で残高永久リーク | §4.1: `balance_tracked?` へ統一・spec で代休往復 count assertion |
| R3 | Med | `working`（clock_in のみ）AR を destroy → clock_in 喪失 | §4.1: destroy 条件を `clock_in.blank?` に限定・打刻残存日は打刻状態へ復帰 |
| R4 | Med | counted_dates 再計算ドリフトで無関係 AR を破壊/取り残し | §4.1: 範囲内 leave-status AR 由来抽出へ変更（再計算撤廃） |
| R5 | Med | `request_withdrawal` の `@req` 解決未記載 → 404/403 崩れ・NameError | §5.2: `before_action` を policy_scope 経由で共有（404 担保） |
| R6 | Med | `RouteError`/`RecordInvalid` 未 rescue → 500 | §5.2: controller rescue に追加 |
| R7 | Low | `actionable?` に purpose 明示照合なし（不変条件依存） | §5.1: `purpose == active_purpose` 追加（防御的・サービス層と対称） |
| R8 | Warning | `clock_change_withdrawn` が SPEC §4.14 凍結列挙に無い | §1.1: 同一 PR で SPEC §4.14 + model コメント更新を必須化 |
| R-whiny | Warning | concern 再オープンの `whiny_persistence`/enum 継承が未検証 | §2.2: TDD ③④（実遷移・save 失敗→例外）を必須化・load 順コメント |
| R-presence | Low | `withdrawal_reason` presence が宣言のみ | §3.4: `Withdrawable` に条件付き presence 検証（二層化） |
| R9 | Low | 撤回承認時の `ConflictError` 文言が「再申請」案内で的外れ | §5.3: purpose で文言分岐 |
| R6b | Low | 残高 0 clamp が異常を握り潰す | §4.1: `new_used.negative?` で `Rails.error.report` |

**確認済みで健全（変更不要）**: with_lock 境界が撤回全副作用を覆う／複数承認者同時撤回は host lock で直列化＋`InvalidTransition`／`reject_withdrawal` 副作用非発火（§13.6）／AASM 構造防御（未定義イベント＝InvalidTransition・terminal 終端）／自己承認防止の撤回適用（RouteResolver 再利用で approver≠requester 自動成立）／段階順序（active_purpose スコープ）／テナント分離（Withdraw の with_tenant・複合 index の org 先頭・purpose backfill 越境なし）／CCR 復元の片側変更・original null 不発・別 CCR 競合検出。

> **D1 のプロダクト確認（任意・低優先）**: §7.6 は撤回承認を「管理者」単数表現。本設計は固定 2 段フル経路を再利用（最小コード）。「撤回に 2 段承認 UX が本当に要るか（単一承認で足りないか）」は将来プロダクト判断の余地ありだが、v1 は対称性・自己承認防止の既存機構流用を優先。

---

## 付録: 撤回フロー全景

```
[approved]
   │ request_withdrawal（申請者・withdrawal_reason 必須・再撤回不可ガード）
   ▼
[withdrawal_requested] ── Start(purpose: :withdrawal) で position 1/2 生成
   │  （approve/reject は未定義＝InvalidTransition で承認エンジン再起動を構造防御）
   ├─ インボックスで 2 段承認（self-approval 防止・段階順序）
   │     └ all_stages_approved?(withdrawal) → approve_withdrawal! + apply_withdrawal_effects!
   │            ├ LeaveRequests::Withdraw（残高減算・AR 復元/destroy・leave_withdrawn）
   │            └ ClockChangeRequests::Withdraw（original_* 復元・recalc・clock_change_withdrawn）
   │     ▼
   │  [withdrawn]（終端）
   └─ いずれかの段で却下 → reject_withdrawal!（副作用なし・§13.6）
         ▼
      [approved]（復帰・原承認確定）
```
