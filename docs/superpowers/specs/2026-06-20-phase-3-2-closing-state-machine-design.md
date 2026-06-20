# Phase 3-2 締め状態機械 + 申請制限 — 設計

- 日付: 2026-06-20
- スライス: ROADMAP Phase 3-2（1 スライス = 1 ブランチ = 1 PR・`feat/phase3-2-closing-state-machine`）
- 典拠: SPEC §6.6（勤怠締めフロー・月次サマリ状態機械）・§6.7（締めステータスによる申請制限・横断ルール）・§13.4（`MonthlyAttendanceSummary.status` AASM）・§13.6（イベント × `after` 副作用）・§7.6（撤回の締め制限・L910）・§4.13（MonthlyAttendanceSummary）・§3.3（一括は scope で固定・IDOR）・§3.6（テナント分離・ジョブの `with_tenant`）・§16.2（一括確定の非同期化）
- 前提エンジン: Phase 2-1〜2-5（`Approvable`/`Withdrawable`/`Approvals::Approve`・固定 2 段・撤回フロー）+ Phase 3-1（`MonthlyAttendanceSummary`・`AttendancePeriod`・`MonthlySummaries::Aggregate`）はすべて据付・merge 済（main = 3-1 完了）
- **本設計のブレスト確定事項（2026-06-20・`superpowers:brainstorming`）**: スコープ＝コアのみ（D1）／提出前チェック＝SPEC 通り厳密（D6）／承認再チェック＝Approach A（D3）をユーザー承認済み。設計全体（§1〜§4）もユーザー承認済み

## 0. スコープと前提

Phase 3-1 が「`(user, year_month)` の締め期間 AR 群を横断集計して `MonthlyAttendanceSummary`（永久保持）へ冪等 upsert する純関数 `Aggregate`」を据えた。ただし 3-1 は**素材保存のみ**で、`Aggregate` 自身が「status は見ない純関数。**submitted/finalized を上書きしないゲートは呼び出し側責務（3-2/4-2）**」とバトンを残している（`aggregate.rb:9`）。

3-2 はその素材の上に**状態機械（背骨）**を載せ、状態に応じて「申請を制限し・締めを回す」層を投入する。完了条件:

> 社員が自分の締め期間を**提出**でき（全件再集計 → submitted）、管理者が**確定**（finalized）・**差戻し**（deferred・理由必須）でき、deferred から**再提出**でループする。submitted/finalized の月に属する日付への申請（LR/CCR/HWR 新規）と撤回（LR/CCR）は制限され、申請作成後に締まった場合は**承認操作時にも fail-closed で弾かれる**。複数社員分の確定は SolidQueue ジョブで非同期化される。

### 設計判断ログ

| # | 論点 | 決定 | 根拠 |
|---|------|------|------|
| D1 | スライス境界 | **コアのみ**＝AASM 5 遷移・§6.7 申請制限（新規）・LR/CCR 撤回制限・承認時の締め再チェック・一括確定 SolidQueue ジョブ（+ dev Active Job 設定）・最小の提出/確定/差戻し UI。**範囲外**: CompanyCalendar destroy 制限（backlog・3-3 以降）／§6.4 月次レポート画面の作り込み + CSV 2 種（3-3）／通知送信（4-1） | ブレスト確定。状態機械を確実に一周させ PR を肥大させない。CompanyCalendar destroy 制限は backlog が「Phase 3-2 に合わせて」と名指しするが本 PR では見送り（横断ルールが整ってから） |
| D2 | 提出/再提出のイベント設計 | **1 AASM event `submit`**（`from: [:aggregating, :deferred], to: :submitted`）に統合。UI ラベルのみ「提出/再提出」で出し分け | §13.4 図は別アローだが副作用（全件再集計 → ロック）が同一。AASM は from 複数で素直に表現でき、副作用フックも 1 箇所に集約できる（§13.6 イベント束縛） |
| D3 | 承認時の締め再チェックの注入点 | **Approach A**＝`Approvable#closing_locked?`（既定 `false`）を `ClosingRestricted` が override し、`Approvals::Approve#guard!` で `raise Approvals::ConflictError if @approvable.closing_locked?`。単一チョークポイントで全 3 型 fail-closed by construction | ブレスト確定。`apply_approval_effects!` と同型の overridable フック思想に一貫。入口で弾く（assignment を approved にしてから tx 巻き戻すより監査・ロック保持時間が健全）。`ConflictError` は §7.4/2-3 で既存ゆえ再利用（新エラー不要） |
| D4 | date → 締め期間の逆写像 + ロック述語 | **`AttendancePeriod.containing(organization:, date:)`**（候補＝date の暦月期・`range.cover?` で当否、外れたら `.next`。下限は常に満たすため `.prev` 不要）+ **`MonthlySummaries::ClosingLock.locked?(user:, dates:)`**（dates の `containing(min)..containing(max)` を walk → distinct labels → その user の summary を `status IN (submitted, finalized)` で 1 クエリ存在判定） | 3-1 `AttendancePeriod` は順写像（year_month→range）のみ。申請制限・再チェックは逆向き（date→status）が要る。行なし＝aggregating＝**unlocked**（締めていないものは締まっていない＝この向きは fail-open が正） |
| D5 | 申請制限の実装層 | **新規作成**＝concern `ClosingRestricted`（LR/CCR/HWR が include・`validate :target_dates_not_in_closed_period, on: :create`）。**撤回**（LR/CCR のみ）＝`Withdrawable` の `request_withdrawal` event に guard `closing_unlocked?` を追加 | §6.7「実装は各申請モデルのバリデーション」に忠実。撤回は AASM event 経由ゆえ on:create バリデーションが効かない → `no_prior_withdrawal_round?` と並ぶ**構造ガード**で fail-closed（`InvalidTransition`） |
| D6 | 提出前チェック（§6.6）の忠実度 | **SPEC 通り厳密**。`MonthlySummaries::PendingRequests`（query object）が期間に重なる in-flight 申請を横断収集し**起動済み（acted assignment あり→「待機」）/未起動（全 pending→「キャンセル可」）に二分**。Submit サービスは in-flight があれば `ConflictError`（fail-closed）、UI は一覧 + 提出ボタン非活性 | ブレスト確定。承認時の締め再チェックがハードな backstop ゆえ提出前チェックは UX 上の事前ガードだが、SPEC 記述に忠実に作り spec-check の乖離を残さない |
| D7 | 「locked 行を再集計しない」ゲートの担保 | **経路構造で自動充足**。`Aggregate` を呼ぶのは submit/resubmit 経路のみ、その from-state（aggregating/deferred）は必ず unlocked。finalize はロックのみで `Aggregate` を呼ばない | 3-1 が呼び出し側へ残したゲートを、明示的な status 判定でなく**遷移経路の不変条件**で満たす。「確定値が確定後に動く」事故が原理的に起きない |
| D8 | 単一 vs 一括の確定 | **単一 finalize は同期サービス、一括は `MonthlySummaries::BulkFinalizeJob`**（初の SolidQueue）。controller が `policy_scope` で対象 summary を解決（IDOR 防御・§3.3）→ ID 群 + org を渡す。ジョブは `ActsAsTenant.with_tenant(org)` ラップ（§3.6）し、各 summary が submitted なら `finalize!`（非 submitted は skip＝冪等） | §6.6「月次一括確定: 複数社員分は SolidQueue で分割」・§16.2「一括確定は非同期化」。job 内ループの finalize 失敗は 1 件単位で隔離（1 社員の失敗が他社員を巻き込まない） |
| D9 | dev/test の queue adapter（**OPEN・要計画段確認**） | production のみ `:solid_queue` + 専用 queue DB（実態確認済）。dev は単一 DB `gatcha_development`。**推奨**: dev=`:solid_queue`（primary DB に queue スキーマを載せる・`connects_to` 分離なし）/ test=`:test`（`assert_enqueued_with`/`perform_enqueued_jobs`）。正確な DB 配線（`db/queue_schema.rb` を primary に取り込むか・dev 専用 queue DB を足すか）は plan 段で `database.yml`/`queue.yml` と実機照合 | ROADMAP「初の SolidQueue 利用 → dev 用 Active Job 設定もここで」。実際に enqueue→処理が dev で回る設定を入れる。worker 起動（`bin/jobs`）手順も docs 化 |
| D10 | 通知 | **全て Phase 4-1 後置**。defer/finalize の社員通知は送らず、**in-app バナー + `deferral_reason` 永続**のみ | ROADMAP 横断ルール「通知に触れる機能は Phase 4-1 まで通知送信を持たない（送信コードを 1 箇所に集める意図的後送り）」 |

### 本スライスに含めない（明示的後置）

- **CompanyCalendar destroy の締め済み月制限**（backlog）→ 横断ルールが整ってから（3-3 以降）。本 PR では着手しない
- **月次レポート画面（§6.4 サマリ/日別明細 ViewComponent）・CSV 2 種**→ **3-3**。3-2 の社員 UI は「締めページ（status + 集計値 + 提出ボタン）」の最小に留める
- **通知送信（defer/finalize/未提出者）**→ **4-1**。3-2 は in-app バナーのみ
- **日次積み上げバッチ・SolidQueue recurring・月初/初回打刻の summary 自動生成**（§13.4「月初 or 初回打刻で自動作成」）→ **4-2**。3-2 は submit が `Aggregate` の `find_or_initialize` で lazy 生成すれば足りる（提出経路に summary 行が無くても動く）

---

## 1. データモデル + 状態機械

### 1.1 マイグレーション（`monthly_attendance_summaries` へカラム追加）

§4.13 が既に予約記載済み（`status` enum aggregating/submitted/finalized/deferred・`deferral_reason`）。3-1 の D4「status/AASM は 3-2 で追加」を回収する。

| カラム | 型 | 制約 | 説明 |
|---|---|---|---|
| `status` | integer | NOT NULL, default 0 | aggregating(0)/submitted(1)/finalized(2)/deferred(3) |
| `deferral_reason` | text | NULL | 差戻し理由（deferred 時必須・§6.6） |

- 既存テーブルへのカラム追加（複合 FK `[organization_id, id]`・unique index は 3-1 で設置済）。`/create-migration` 規約に沿うが本 migration は**新テーブル/FK でなくカラム追加**ゆえ複合 FK の新設はない
- **補助 index**（任意・計測で要否判断）: 管理者ダッシュボードの「submitted 抽出」用に `(organization_id, status)` partial（`WHERE status = 1`）を検討。v1 規模（§16.1）では full scan でも許容の可能性 → plan で判断、デフォルトは**入れない**（YAGNI）

### 1.2 `MonthlyAttendanceSummary` の AASM

`Approvable` と同型の宣言（`column: :status, enum: true, whiny_persistence: true`）。enum は AASM より先に宣言（class ロード時マッピング解決）。

```ruby
enum :status, { aggregating: 0, submitted: 1, finalized: 2, deferred: 3 }

include AASM
aasm column: :status, enum: true, whiny_persistence: true do
  state :aggregating, initial: true
  state :submitted
  state :finalized
  state :deferred

  event :submit do      # 提出 / 再提出（D2 統合・副作用 = §1.3 Submit サービス側）
    transitions from: [:aggregating, :deferred], to: :submitted
  end
  event :finalize do    # 確定（管理者・ロックのみ）
    transitions from: :submitted, to: :finalized
  end
  event :defer do       # 差戻し（管理者・deferral_reason 必須）
    transitions from: [:submitted, :finalized], to: :deferred
  end
end
```

- `validates :deferral_reason, presence: true, if: :deferred?` — Defer サービスが `reason` を代入してから `defer!`（whiny_persistence で save 失敗は例外化）
- `deferral_reason` は resubmit（deferred→submitted）後も**保持**（直近差戻し理由の監査痕）。検証は deferred の間だけ強制
- AASM の遷移自体に副作用フックは付けず、**tx 境界を握るサービス**（§1.3）が「副作用 → 遷移」を順序づける（§13.6 のイベント束縛を service 層で実現する既存方針＝`Approvals::Approve#finalize!` と同型）

### 1.3 締めサービス（tx 境界）

| サービス | 役割 | tx 内の順序 |
|---|---|---|
| `MonthlySummaries::Submit` | 提出 / 再提出 | ① 提出前チェック（§3.1 `PendingRequests` で in-flight があれば `ConflictError`）→ ② `Aggregate.call`（全件再集計・既存純関数）→ ③ `summary.submit!` |
| `MonthlySummaries::Finalize` | 単一確定（同期） | `summary.finalize!`（submitted 以外は AASM `InvalidTransition`） |
| `MonthlySummaries::Defer` | 差戻し | `summary.deferral_reason = reason; summary.defer!` |

- いずれも `with_lock`（または `transaction`）で直列化。Submit は再集計と遷移を同一 tx に閉じ込め、in-flight 承認との read-skew を最小化（ハード backstop は承認側 re-check）
- 一括確定は §3.2 のジョブが `Finalize` 相当を loop（ジョブ内で直接 `finalize!`）

---

## 2. 横断制限（申請制限 + 撤回制限 + 承認再チェック）

### 2.1 共通土台

**`AttendancePeriod.containing(organization:, date:)`**（逆写像・D4）:

```ruby
def self.containing(organization:, date:)
  candidate = new(organization:, year_month: date.strftime("%Y-%m"))
  candidate.range.cover?(date) ? candidate : candidate.next
end
```

> 正当性: 期 M の range = `(closing_date(M-1)+1 .. closing_date(M))`。任意の日 d は自暦月内ゆえ `range.first <= 月初 <= d` が常に成り立つ（下限は必ず満たす）。上限 `closing_date(M)` を超える日のみ翌期へ送られる → `candidate` か `candidate.next` の二択で `.prev` は不要。`closing_day` 任意値（月末 31 含む）で正しい。

**`MonthlySummaries::ClosingLock`**（PORO 述語・D4）:

```ruby
module MonthlySummaries
  class ClosingLock
    LOCKED = %w[submitted finalized].freeze

    def self.locked?(user:, dates:) = new(user:, dates:).locked?
    # dates: Date / Range<Date> / Array<Date>

    def locked?
      ActsAsTenant.with_tenant(@user.organization) do
        MonthlyAttendanceSummary
          .where(user: @user, year_month: period_labels, status: LOCKED)
          .exists?
      end
    end

    # containing(min)..containing(max) を walk して distinct labels
    private def period_labels
      ds = Array(@dates).flatten
      org = @user.organization
      first = AttendancePeriod.containing(organization: org, date: ds.min)
      last  = AttendancePeriod.containing(organization: org, date: ds.max)
      labels, p = [], first
      loop do
        labels << p.label
        break if p.label == last.label
        p = p.next
      end
      labels
    end
  end
end
```

- 行なし＝aggregating＝unlocked（D4）。`status IN (submitted, finalized)` の存在のみが locked
- LR の最大 366 日範囲でも walk は ~13 期で収束（典型 1〜2 期）

### 2.2 新規作成制限（§6.7）— `ClosingRestricted` concern

```ruby
module ClosingRestricted
  extend ActiveSupport::Concern
  included do
    validate :target_dates_not_in_closed_period, on: :create
  end

  # host が実装する: 締め判定の対象日（複数可）
  # LR: start_date..end_date / CCR: [attendance_record&.work_date].compact / HWR: [work_date]
  def closing_target_dates = raise NotImplementedError

  # 承認時の締め再チェック（§2.4）。既定 false（Approvable）を上書き
  def closing_locked?
    dates = closing_target_dates
    dates.present? && MonthlySummaries::ClosingLock.locked?(user: requester, dates:)
  end
  def closing_unlocked? = !closing_locked?

  private

  def target_dates_not_in_closed_period
    return unless closing_locked?
    errors.add(:base, "締め済みの月（提出済 / 確定）の日付は申請できません")
  end
end
```

- LR / CCR / HWR が `include ClosingRestricted` し `closing_target_dates` を実装
- `requester` は 3 型とも `belongs_to :requester`（`Approvable` 契約）で共通
- **月跨ぎ LR**: range 内に 1 日でも locked 期があれば作成を弾く（申請レコードは atomic ゆえ部分作成不可・§6.7「その月の日付のみブロックし差戻しを促す」は「他月とまとめて出し直すなら差戻し依頼」の運用導線で、レコード単位は all-or-nothing）

### 2.3 撤回制限（§6.7・§7.6 L910）— `Withdrawable` の event guard

```ruby
event :request_withdrawal do
  transitions from: :approved, to: :withdrawal_requested,
              guard: [:no_prior_withdrawal_round?, :closing_unlocked?]
end
```

- LR/CCR のみ（`Withdrawable` を include する 2 型）。HWR は撤回フロー非保有ゆえ対象外（§4.12）
- `closing_unlocked?` は `ClosingRestricted` 由来（LR/CCR は両 concern を include）。locked なら `InvalidTransition`（fail-closed・構造ガード）→ controller は flash で「締め済みのため撤回できません」

### 2.4 承認時の締め再チェック（§6.6）— Approach A

```ruby
# Approvable（既定・テスト専用 approvable や非日付 host は安全 no-op）
def closing_locked? = false

# Approvals::Approve#guard! に 1 行追加
raise Approvals::ConflictError if @approvable.closing_locked?
```

- `ClosingRestricted` を include する LR/CCR/HWR は §2.2 の `closing_locked?` で override 済 → guard! が自動的に全 3 型を fail-closed で弾く
- **既定 false の silent-gap 対策**: 「`Approvable` を include する申請モデルは `ClosingRestricted` も include する」を**ガード spec** で機械的に検証（将来型の漏れを CI で塞ぐ）
- 弾かれた承認は `applying` のまま。解決は「管理者が summary を differ（submitted/finalized→deferred）→ 期がほどける → 再承認」の通常フロー

---

## 3. 提出前チェック + 一括確定ジョブ

### 3.1 提出前チェック（§6.6・D6）— `MonthlySummaries::PendingRequests`

```ruby
# (user, period) → 期間 range に重なる in-flight 申請を横断収集
# LR: start_date..end_date が period.range と overlap / CCR: attendance_record.work_date ∈ range / HWR: work_date ∈ range
# status ∈ {applying, withdrawal_requested}
#   started?   = active purpose に decision != pending の assignment あり（「承認進行中」→ 待機）
#   not_started = 全 assignment pending（「申請中・未起動」→ キャンセル可）
```

- `Submit` サービスが冒頭で呼び、in-flight が 1 件でもあれば `Approvals::ConflictError`（fail-closed）
- UI は started/not_started に分けて一覧表示し、started があれば提出ボタン非活性・not_started はキャンセル導線（§6.6 忠実）
- ※ overlap 判定はテナントスコープ下で各型を別クエリ（polymorphic 結合は避ける・2-2b の汎用インボックス N+1 教訓と同方針）

### 3.2 一括確定ジョブ（初の SolidQueue・D8）

```ruby
class MonthlySummaries::BulkFinalizeJob < ApplicationJob
  def perform(organization_id:, summary_ids:)
    org = Organization.find(organization_id)
    ActsAsTenant.with_tenant(org) do        # §3.6 必須（リクエスト文脈なし）
      MonthlyAttendanceSummary.where(id: summary_ids).find_each do |s|
        s.finalize! if s.submitted?          # 冪等・非 submitted は skip
      rescue AASM::InvalidTransition, ActiveRecord::RecordInvalid => e
        # 1 件の失敗を隔離（他社員を巻き込まない）。4-1 で通知接続
        Rails.logger.warn("[BulkFinalize] skip ##{s.id}: #{e.class}")
      end
    end
  end
end
```

- controller（管理者）が `policy_scope(MonthlyAttendanceSummary)` で対象を解決（IDOR 防御・§3.3「一括は scope で固定」）→ id 群 + organization_id を渡す
- `find_each` で 1 件ずつ確定。`with_tenant` ラップは `check-job-tenant-wrap` フックの対象（§3.6）
- **dev/test 設定（D9・OPEN）**: dev で実際に enqueue→処理が回るよう `:solid_queue`（DB 配線は plan 確認）、test は `:test` で `assert_enqueued_with` / `perform_enqueued_jobs`

---

## 4. Policy / UI / テスト / レビュー

### 4.1 Pundit `MonthlyAttendanceSummaryPolicy`

| アクション | 許可 |
|---|---|
| `submit?` | record.user == user（本人）or hr_admin |
| `finalize?` / `defer?` / `bulk_finalize?` | record.user の manager（上長）or hr_admin |
| `Scope` | 自分 + 部下（§3.3・manager 階層）。一括・一覧の対象集合をここで固定 |

### 4.2 UI（最小・§12.1 トーン）

- **社員**: 締め期間別「締めページ」— status バッジ・集計値（summary から表示）・提出/再提出ボタン（in-flight で非活性 + §3.1 一覧）・deferred バナー（`deferral_reason` 表示）
- **管理者**: 部下の submitted 一覧（`policy_scope`）— 確定 / 差戻し（reason 入力）/ 複数選択 → 一括確定（`BulkFinalizeJob` enqueue）
- 編集制御は**サーバー側バリデーション + UI（Turbo で disable）の二重**（§6.6）
- §6.4 のレポート作り込み・CSV は範囲外（3-3）

### 4.3 テスト（雛形 `/gen-spec`）

- **model**: AASM 5 遷移（正常 + terminal/不正遷移の `InvalidTransition`）・`deferral_reason` 必須・`ClosingRestricted` の on:create 検証（locked/unlocked・月跨ぎ）・`Withdrawable` の `closing_unlocked?` guard・`AttendancePeriod.containing`（closing_day=31/20 の境界）・`ClosingLock`（行なし=unlocked・複数期 walk）
- **service**: `Submit`（提出前チェック→集計→遷移の順序・in-flight で `ConflictError`）・`Finalize`/`Defer`・`BulkFinalizeJob`（`with_tenant` ラップ・冪等・1 件失敗の隔離）
- **request**: policy（本人/上長/hr_admin）・IDOR（scope 外 404）・承認 re-check の `ConflictError` path（作成後に締めた → approve がエラー）
- **ガード spec**: `Approvable` を include する申請モデルが `ClosingRestricted` も include する（D3 silent-gap 塞ぎ）

### 4.4 レビュー / 検証

- `tenant-isolation-reviewer`（models / job / migration・`with_tenant` ラップ・`ClosingLock` のテナントスコープ）
- `approval-engine-reviewer`（`Approve#guard!` への締め注入・AASM 状態機械・`Withdrawable` guard・副作用 atomicity）
- `/preflight`（rspec・rubocop・brakeman）→ 完了時 `/spec-check`（§6.6/§6.7/§13.4 の追従確認）
- 大物ゆえ実装計画前に `/multi-perspective-review` を本 spec に通す

---

## 5. 既知の限界 / handoff

- **submit と approve の read-skew**: `Submit` の tx（再集計 + 遷移）と `Approve` の `with_lock` tx が並走した場合、提出が先にコミットすれば approve の re-check（§2.4）が submitted を見て `ConflictError`。approve が先なら submit の再集計が反映を取り込む。ハード backstop は §2.4 ゆえ「締め済み月の AR が裏で書き換わる」事故は構造的に防がれる（提出前チェック §3.1 は UX 上の事前ガード）
- **§13.4「月初 or 初回打刻で自動作成」**: 3-2 は submit 経路の lazy 生成（`Aggregate` の `find_or_initialize`）で足りる。日次バッチによる自動作成は 4-2
- **通知**: defer/finalize/未提出者の通知は 4-1（in-app バナーのみで出荷）
- **dev queue 配線（D9）**: SolidQueue を dev で動かす DB 配線（primary 取り込み vs dev 専用 queue DB）は plan 段で `database.yml`/`queue.yml`/`db/queue_schema.rb` と実機照合して確定
- **CompanyCalendar destroy 制限（backlog）**: finalized 期間の day_type 根拠（35%/60h）の遡及書き換え防止。本 PR では見送り・横断ルール整備後に別スライス
