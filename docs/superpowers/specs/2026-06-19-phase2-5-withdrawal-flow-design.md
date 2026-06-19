# Phase 2-5 撤回フロー（承認済の取消・復元）— 設計

- 日付: 2026-06-19
- スライス: ROADMAP Phase 2-5（1 スライス = 1 ブランチ = 1 PR・`feat/phase2-5-withdrawal-flow`）
- 典拠: SPEC §7.6（撤回フロー）・§7.3（自己承認防止・撤回承認にも適用）・§13.2（approval_status AASM・withdrawal 遷移）・§13.6（イベント × `after` 副作用）・§4.14（AttendanceHistory 前後値・追記専用）・§6.7（締め月の申請/撤回制限）・§3.4–3.6（認可・テナント分離）・§14（after_commit 継ぎ目）
- 前提エンジン: Phase 2-1（承認エンジン）+ 2-2a/2-2b（`Approvable` hook・`Approvals::Approve/Reject/Start/Cancel`・`ApplyApproval` パターン・承認インボックス・`Clockings::Recalculate`）+ 2-3（CCR・前後値充填）+ 2-4（HolidayWorkRequest）はすべて据付・merge 済（**main = 2-4 完了**）
- **2-4 が効く前提**: HWR も `include Approvable`（`approval_status` AASM 共有）。だが §4.12/§13.3 は HWR を**撤回フロー無し・approved 終端**と定める。よって撤回 state/event を共有 `Approvable` に足すと HWR に漏れる → **撤回を別 concern `Withdrawable` へ分離**（D7）
- **本設計のブレスト確定事項（2026-06-19・`superpowers:brainstorming`）**: 下記 D1–D6 をユーザー承認済み

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

> create-migration スキルの規約（複合 FK は本変更で新設なし・`purpose` は既存テーブルへの列追加・partial index 不要）に従い、`bin/rails g migration` 後に手で index 差し替えを記述。schema.rb は migration 経由でのみ更新（手編集禁止フック）。

### 1.2 `ApprovalAssignment`（purpose 追加）

```ruby
class ApprovalAssignment < ApplicationRecord
  # 既存: acts_as_tenant, belongs_to approvable/approver, decision enum, 一方向検証, 同一テナント検証
  enum :purpose, { approval: 0, withdrawal: 1 }, validate: true, prefix: :purpose
  # uniqueness: [org, approvable, purpose, position] は DB index が最終防衛（モデル検証は据置 or 追補）
end
```

- `purpose` は `Approvals::Start` が生成時に付与（既定 approval）。表示（インボックス行のバッジ）に使用。

---

## 2. AASM 状態機械（`Approvable` 基底 + `Withdrawable` 分離・D7）

### 2.0 concern 分割の全体像

| concern | 含む host | 役割 |
|---|---|---|
| `Approvable`（既存・拡張） | LR / CCR / **HWR** | enum 0–5（taxonomy 単一ソース）・基底 4 状態 + `approve`/`reject`/`cancel`・purpose スコープ導出・`awaiting_decision?`・`apply_withdrawal_effects!` 既定 no-op |
| `Withdrawable`（**新設**） | LR / CCR のみ | aasm 再オープンで撤回 2 状態 + 3 イベント・`no_prior_withdrawal_round?` |

- **HWR は `Approvable` のみ**ゆえ撤回イベントを持たない（§4.12/§13.3 構造的遵守）。
- enum 4/5 は `Approvable` が宣言するが、HWR は撤回 `state` を持たず到達不能（AASM は宣言 state のみ状態化）。

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

> **TDD 検証点**: ①`HolidayWorkRequest.new.respond_to?(:request_withdrawal)` が false（撤回イベント非獲得）②enum 0–5 宣言下で HWR が states 0–3 のみで正常ロード（AASM が未使用 enum 値を許容）。①②は model spec の最初に置く。

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

- `withdrawal_reason` を set してから bang（`whiny_persistence` で同一 save に乗る・presence 検証は model 側）。

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

def remove_from_balance
  return unless @leave_request.leave_type.paid_leave?
  fiscal_year = @leave_request.organization.fiscal_year_for(@leave_request.start_date)  # §6.2 統一
  balance = LeaveBalance.where(user_id: @leave_request.requester_id,
                               leave_type_id: @leave_request.leave_type_id, fiscal_year:).lock.first
  return if balance.nil?                                  # 防御（承認時に加算済が正・無ければ no-op）
  new_used = balance.used_days - @leave_request.days_requested
  balance.update!(used_days: [new_used, BigDecimal("0")].max)  # 負値ガード
end

def restore_attendance_records
  classifications = CompanyCalendarResolver.new(organization: @leave_request.organization)
                                           .day_classifications(@leave_request.start_date, @leave_request.end_date)
  LeaveDaysCalculator.counted_dates(classifications).each do |date|
    record = AttendanceRecord.find_by(user_id: @leave_request.requester_id, work_date: date)
    next if record.nil?
    if record.clock_in.present? && record.clock_out.present?
      record.update!(status: :clocked_out)             # 半休（打刻済）→ 打刻日へ戻す
      Clockings::Recalculate.call(record:)             # 半休免除を解除し LateEarly 再計算
    else
      record.destroy!                                  # 休暇が新規作成した日 → 消す
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

> **逆算の妥当性（D3）**: 正方向 `ApplyApproval` は counted_dates に `status=leave_status` を置き、半休×打刻済日だけ `Recalculate` した。逆は「打刻時刻が残る日＝半休だった日（clocked_out 復帰 + recalc）／打刻なし＝休暇が作った日（destroy）」。v1 は `on_leave` 日への打刻付与が構造上起きない（半々の後続打刻はバックログ）ため、現 AR 状態 = 承認前状態の逆像が成立。`§14` の after_commit 継ぎ目は本 `record_history`（leave_withdrawn）が兼ねる。

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
    record.approver_id == user.id &&
    record.position == record.approvable.current_approval_position &&
    !Approvals::SelfApproval.violated?(
      requester_id: record.approvable.requester_id,
      approver_id: record.approver_id, acting_user_id: user.id
    )
end
```

- インボックス Scope（`approver_id == user && pending`）は無変更。撤回世代の pending も自然に拾われ、`approve?`（actionable?）で現段階のみ通る。

### 5.2 Controller

```ruby
# LeaveRequestsController / ClockChangeRequestsController に member PATCH
def request_withdrawal
  authorize @leave_request, :request_withdrawal?
  Approvals::RequestWithdrawal.call(approvable: @leave_request, requester: current_user,
                                    reason: params.require(:leave_request).permit(:withdrawal_reason)[:withdrawal_reason])
  redirect_to @leave_request, notice: "撤回を申請しました。承認をお待ちください。"
rescue AASM::InvalidTransition, Approvals::NotRequester
  redirect_to @leave_request, alert: "この申請は撤回できません。"
rescue ArgumentError => e
  redirect_to @leave_request, alert: e.message   # 撤回理由 blank
end
```

- **インボックスの approve/reject は既存アクションがそのまま撤回承認/却下に振る舞う**（3.2/3.3 の状態分岐が吸収）。撤回専用の承認アクションは作らない。
- ルート: `resources :leave_requests do member { patch :request_withdrawal } end`（CCR 同型）。

### 5.3 View

- **申請 show**: `policy(@req).request_withdrawal?` のとき「撤回申請」セクション（`withdrawal_reason` textarea 必須 + PATCH ボタン）。`withdrawal_requested` 中は「撤回承認待ち」バッジ + reason 表示。`withdrawn` は終端表示。
- **インボックス行**: `assignment.purpose_withdrawal?` で「**撤回承認**」バッジを出し、通常承認と視覚区別（行の approve/reject ボタンは共通）。撤回承認時は「この申請を撤回（取消）します」の確認文言。
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
| service | `Approvals::RequestWithdrawal`（本人/reason/再撤回ガード）・`LeaveRequests::Withdraw`（残高減算・clocked_out 復帰 + recalc・destroy 分岐・leave_withdrawn 履歴）・`ClockChangeRequests::Withdraw`（original 復元・競合・clock_change_withdrawn 前後値）・**`reject_withdrawal` で副作用非発火** | atomic rollback（Withdraw 内 raise → 撤回承認ごと巻き戻し）。テナント分離（`with_tenant`） |
| request | 撤回申請 → 2 段承認 → `withdrawn` + 復元の一周（LR/CCR）・撤回却下 → `approved` 復帰で**残高/履歴が二重化しない**・他人/他テナントの撤回申請は 404・撤回承認の自己承認防止 | エンジン全経路の統合 |
| policy | `request_withdrawal?`（本人 && approved && 撤回世代なし）・`actionable?` 一般化（撤回承認が actionable・terminal 不可） | 認可二層 |
| system（任意） | 申請 show の撤回ボタン → インボックス撤回承認 → 復元の UI 一周 | 主要動線 |

- spec 雛形は `/gen-spec`（テナント文脈ラップ）。残高/履歴の二重化検出は count assertion で。

---

## 8. ハンドオフ / 既知の限界

1. **再撤回 v1 不可（D6）**: 撤回却下後は原承認確定。`round` カウンタ導入は将来テーマ。
2. **§6.7 締め月制限は前方フックのみ**（§6）。Phase 3-2 で `MonthlyAttendanceSummary.status` 参照のバリデーションを LR/CCR + `RequestWithdrawal` に実装。
3. **通知送信は Phase 4-1**（撤回申請通知・却下理由通知）。本スライスは flash + `comment` 記録。
4. **LR 復元は逆算（D3）**: `on_leave` 日への打刻付与（半々の後続打刻・バックログ）が将来入ると逆像の前提が崩れる。その連携を実装する際は本逆算の前提を再訪（バックログにクロスリンク）。
   - **counted_dates 再計算のドリフト**: 復元は承認時の counted_dates を保存せず `CompanyCalendarResolver` で再計算する。承認〜撤回間に CompanyCalendar（祝日/法定休日）が変わると counted_dates がずれ、もはや counted でない日の `on_leave` AR が `find_by ... next if nil` で取り残され得る。v1 は締め済/過去日のカレンダー編集制限（Phase 3-2 バックログ）で実害が出にくいが、§6.7 締め制限の実装時に「承認時 counted_dates の保存 or AR 由来の復元対象抽出」を再判断。
5. **clocked 済 AR への全休承認（2-2b バックログ・stale 列）**: 本逆算は「打刻あり→clocked_out + recalc」ゆえ撤回時にむしろ stale を癒すが、根治は当該バックログ側。
6. **after_commit 継ぎ目（§14）**: `leave_withdrawn` / `clock_change_withdrawn` 履歴記録が将来 Gatcha Work 連携の publish 点を兼ねる（`leave_approved` と対称）。
7. **レビュー**: `approval-engine-reviewer`（撤回 AASM・自己承認・副作用 atomicity・イベント束縛）+ `tenant-isolation-reviewer`（purpose 列・Withdraw の `with_tenant`・複合 index）を merge 前に PROACTIVELY。`/spec-check` は Phase 2 完了確認で。
8. **検証コマンド**: `bundle exec rspec` / `bundle exec rubocop --force-exclusion` / `bin/brakeman --no-pager`。

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
