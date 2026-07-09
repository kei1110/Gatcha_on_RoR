# Phase 4-2c-2 欠勤確定 UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 管理者が欠勤候補一覧から「1 社員 × N 日付」を欠勤確定（`AttendanceRecord(absent)` 生成 + 監査 + 本人通知）でき、偽陽性候補を却下(dismiss)できる UI とサービスを出荷し、Phase 4-2 の §1.4 到達面を成立させる。

**Architecture:** 権威源は `AbsenceCandidate`（params 日付を権威にしない）。controller が `policy_scope` で対象社員と候補を解決 → `Absences::Confirm` サービスが 5 段のガード（毒入力 → 候補不在 → 未通知 → 猶予前 → 締め済み）を順に通し、per-day savepoint で {AR create → 候補 destroy → history create} の 3 write を 1 単位に束ねる。通知は tx 確定後に controller が発火（rescue+log）。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / acts_as_tenant / Pundit / ViewComponent / RSpec。

**設計 SSOT:** `docs/superpowers/specs/2026-06-28-phase4-2-daily-batch-design.md` の **§5 + §11 + §12**（§10/§11/§12 は §2〜§9 を上書きし、§12 は §5 を上書き）。SPEC は §6.10（欠勤確定フロー）/ §6.8（猶予）/ §1.4（動線）/ §3.4（認可）/ §3.6（テナント）。

---

## Global Constraints（binding・全タスクに適用）

**設計由来（§10/§11/§12）:**

- **§12③（IDOR の唯一の壁）**: 対象社員は必ず `policy_scope(User, policy_scope_class: AbsenceConfirmationPolicy::Scope).find(params[:user_id])` で解決したオブジェクトを `AttendanceRecord.create!` に渡す。生 `params[:user_id]` を渡さない。**同一テナントの他部下は belongs_to presence も複合 FK も model 検証も塞がない — policy_scope 解決だけが塞ぐ**。
- **§11②/§12⑨**: 確定できる日付は `policy_scope(AbsenceCandidate)` に**実在する候補の日付だけ**。候補の無い日付が 1 つでも混ざれば全件 422（部分成功にしない）。却下/撤回された休暇日はここで弾かれる（v1 非対象・仕様として明記する）。
- **§12①（最重要）**: `candidate.notified_on.nil?` を**猶予計算より先**に判定して 422。`next_business_day(nil)` を計算しない。`notified_on` 非 nil ⟹ 本人通知済＝弁明機会付与済（4-2b が本人 Notifier 成功後にのみ立てる）。
- **§10⑤**: 猶予 = `notified_on` の**翌営業日 17:00（組織 TZ）**を経過してはじめて確定可。経過前は 422。
- **§12④**: 確定 AR の生成に `insert_all` / `upsert_all` を**使わない**。`create!` per-day（belongs_to presence と `absence_reason_only_on_absent` の 2 検証を live に保つ）。
- **§12⑤**: 1 日あたり {`AttendanceRecord.create!` → `AbsenceCandidate#destroy!` → `AttendanceHistory.create!`} を `transaction(requires_new: true)` の **1 savepoint に束ね**、`RecordNotUnique` / `RecordInvalid` をそのブロックのみ rescue して「skip 日」として結果に返す。savepoint rollback で候補が intact に戻ること。
- **§11⑦/§12⑩**: 締めガードは既存 `MonthlySummaries::ClosingLock`（`LOCKED = %w[submitted finalized]`）を write 前に対象全日一括で評価。**submitted も遮断する**（§5.2 の「finalized 禁止」より厳格 — 本計画で意図的に採用）。1 日でも locked なら 422。
- **§11④/§12⑧（必須・optional でない）**: 却下(dismiss)＝候補 `destroy`（監査に残さず消す・ephemeral 一貫）。確定 UI に「非所定日/シフト未把握」の注意喚起を出す。
- **§11③（4-2c-1 で条件解除）**: 確定通知文は「事後に有給休暇の申請ができます」へ**復帰させてよい**（PR #32 で `absent → on_leave` の事後有給パスが live 化）。**打刻変更申請は約束しない**（CCR `new_entry` は依然拒否・#48）。
- **§12⑦**: 4-2b の事前通知 body（`AttendanceAnomalies::Detect#notify_candidate`）から「打刻変更申請を提出してください」を削る（候補は定義上 no-AR 日ゆえ CCR が全滅）。
- **毒入力ガードの位置（本計画で確定）**: `absence_reason` の妥当性は **per-day ループの前**に検証する。後ろに置くと per-day の `rescue RecordInvalid`（並行打刻の競合吸収用）が毒入力を「skip 日」として握り潰し、422 が返らなくなる。

**本計画で確定した判断（設計が開いていた点）:**

| # | 判断 | 根拠 |
|---|------|------|
| J1 | **W1**: `absent → on_leave` の `AttendanceHistory(absence_to_paid)` に**元の `absence_reason` を `note` へ退避**する | `previous_status: absent` だけでは「どの欠勤が有給へ振り替わったか」が労基法 109 条の 5 年保存証跡から落ちる。`attendance_histories.note` 列は実在 |
| J2 | **§12⑨**: 却下/撤回 LR 日の欠勤確定は **v1 非対象**。候補ゲートを厳守し SPEC §6.10 に明記 | 「候補に無い過去日の確定捏造」を 2 層で封じる原則（§11②）を優先。手動追加経路は §11② と正面から緊張する |
| J3 | **I1**（半休 LR が全日 absent を覆うと残り半日の欠勤が消える）は **backlog + 社労士確認**へ | 正解（半日欠勤 + 半日有給の併記）はデータモデル変更を要する。4-2c-2 は現状挙動のまま出荷 |
| J4 | 確定通知の priority は **`action_required`**（ベル + メール常時） | 賃金控除に直結する不利益処分の告知で、本人に「事後の有給申請」という action がある。SPEC §9.1 の「月次差戻し」と同格。SPEC §9.1 に行を追加する |
| J5 | dismiss は専用 service を作らず controller で `candidate.destroy!` | 副作用 1 write・監査なし（ephemeral）。YAGNI |

**リポジトリ規約（鉄則）:**

- `db/schema.rb` / `Gemfile.lock` を手編集しない（本計画に migration は無い — 全て既存スキーマで足りる）。
- `rubocop` にファイルを明示渡しするときは必ず `--force-exclusion`。
- スコープ付きモデルに触れる service は `ActsAsTenant.with_tenant` で防御ラップ（`ApplyApproval` 同型）。
- `enum` 整数・`event_type` taxonomy は append-only（本計画は既存値 `absence_confirmed: 5` / `absence_to_paid: 6` を消費するのみ・追加なし）。
- 書込系 redirect は一律 `status: :see_other`（Turbo が 302 で method を保持する罠・RAILS_GOTCHAS）。
- 検証エラーの再描画は `status: :unprocessable_entity`（リポジトリ既存表記に合わせる）。

**踏んではいけない既知の罠（docs/RAILS_GOTCHAS.md より注入）:**

- `policy_scope(User)` は top-level `UserPolicy` 不在で `Pundit::NotDefinedError` → **`policy_scope_class:` を明示**する。
- `org.today` 相対ロジックの spec は `travel_to` + **当該日の `CompanyCalendar` を明示登録**して day_type を pin しないと実行日依存で flaky。
- `Date.strptime` / `Date.parse` はゴミ入力を黙認し得る → **`Date.iso8601` で厳格 parse**し `Date::Error` を rescue。
- request spec はテナント未設定ゆえ `AttendanceRecord.unscoped.count` で数える。
- `enum` の排他検証は「その status を出る遷移」で随伴列をクリアしないと `save!` が `RecordInvalid` で親 tx を巻き戻す。クリア条件の旧 status 述語は**新 status 代入前**に捕捉する（capture-before-assign）。

**マージ前レビュアー（`git diff main...HEAD --name-only` から導出）:**

- `app/models` / `app/policies` に触れる → **`tenant-isolation-reviewer`**
- `app/services/leave_requests/apply_approval.rb`（承認副作用）に触れる → **`approval-engine-reviewer`**
- 欠勤確定の労務的扱い（賃金控除・猶予・適正手続き）→ **`labor-law-compliance-reviewer`** + `/legal-citation-audit`
- 仕上げ: `/preflight`・`bundle exec rspec`・`bundle exec rubocop --force-exclusion`・`bin/brakeman --no-pager`
- **§1.4 到達性 DoD**: 「欠勤確定」が GlobalNav から到達可能・SPEC §1.4 の行が ✅ で実態一致

---

## File Structure

| ファイル | 責務 | タスク |
|----------|------|--------|
| `app/services/company_calendar_resolver.rb`（変更） | `HOLIDAY_DAY_TYPES` を SSOT 化・`#next_business_day` 追加 | 1 |
| `app/services/notifier.rb`（変更） | `HOLIDAY_DAY_TYPES` を Resolver への alias 化（重複排除） | 1 |
| `app/models/attendance_record.rb`（変更） | `user_must_belong_to_same_organization`（§11⑥ 二層化） | 2 |
| `app/policies/absence_confirmation_policy.rb`（新規） | headless role ゲート + 対象社員ロスター Scope | 3 |
| `app/policies/absence_candidate_policy.rb`（新規） | 候補の可視範囲 Scope + `destroy?` | 3 |
| `app/services/absences.rb`（新規） | エラークラス（`IneligibleError` / `ClosingLockedError`） | 4 |
| `app/services/absences/confirm.rb`（新規） | 確定の副作用本体（5 ガード + per-day savepoint） | 4 |
| `app/controllers/absence_confirmations_controller.rb`（新規） | index / create（確定）/ destroy（却下） | 5 |
| `config/routes.rb`（変更） | `resources :absence_confirmations` | 5 |
| `app/views/absence_confirmations/index.html.erb`（新規） | 候補一覧・確定フォーム・却下ボタン・注意喚起 | 5 |
| `app/components/global_nav_component.rb`（変更） | 「欠勤確定」リンク（manager\|hr_admin） | 5 |
| `config/locales/ja.yml`（変更） | `absence_reasons` ラベル | 5 |
| `app/services/attendance_anomalies/detect.rb`（変更） | 事前通知 body の虚偽 remedy 削除（§12⑦） | 6 |
| `docs/SPEC.md`（変更） | §1.4 行・§6.10 制限文言・§9.1 通知行 | 8 |

---

## Task 1: `CompanyCalendarResolver#next_business_day`（猶予期限の基盤・§12①）

**Files:**
- Modify: `app/services/company_calendar_resolver.rb`
- Modify: `app/services/notifier.rb:10`
- Test: `spec/services/company_calendar_resolver_spec.rb`

**Interfaces:**
- Consumes: 既存 `CompanyCalendarResolver#day_types(from, to)`（範囲一括 1 クエリ・未登録日は曜日 fallback）。
- Produces:
  - `CompanyCalendarResolver::HOLIDAY_DAY_TYPES` → `%i[saturday sunday holiday legal_holiday company_holiday]`（凍結・day_type 意味論の SSOT）
  - `CompanyCalendarResolver#next_business_day(date) → Date | nil` — `date` の**翌日以降**で最初の稼働日。30 日先まで見つからなければ `nil`（呼び出し側が fail-closed に倒す）
  - `Notifier::HOLIDAY_DAY_TYPES` は上記への alias（既存参照 `notifier.rb:89` / `detect.rb:10` は無改変で動く）

> **なぜ Resolver が持つか**: `day_type` の意味論はカレンダー領域の所有物。現状 `Notifier` が定数を持ち `Detect` が alias する逆流を、`next_business_day` 追加のついでに正す（実装依存の向きは Resolver ← Notifier）。

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/company_calendar_resolver_spec.rb` の末尾に describe を追加:

```ruby
  describe "#next_business_day（猶予期限の基盤・§12①）" do
    let(:org) { create(:organization) }
    let(:resolver) { described_class.new(organization: org) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "翌日が稼働日ならその日を返す（2026-05-01 金 → 2026-05-02 土は休日ゆえ次の平日）" do
      # 未登録日は曜日 fallback（土=saturday / 日=sunday / 他=weekday）
      expect(resolver.next_business_day(Date.new(2026, 5, 1))).to eq(Date.new(2026, 5, 4)) # 月曜
    end

    it "翌日が平日ならその日を返す" do
      expect(resolver.next_business_day(Date.new(2026, 5, 4))).to eq(Date.new(2026, 5, 5)) # 火曜
    end

    it "連休を吸収する（登録済 company_holiday を跨いで次の稼働日）" do
      create(:company_calendar, date: Date.new(2026, 5, 4), day_type: :company_holiday, name: "連休")
      create(:company_calendar, date: Date.new(2026, 5, 5), day_type: :company_holiday, name: "連休")
      expect(resolver.next_business_day(Date.new(2026, 5, 1))).to eq(Date.new(2026, 5, 6)) # 水曜
    end

    it "起点日自身は稼働日でも返さない（翌日以降を探す）" do
      expect(resolver.next_business_day(Date.new(2026, 5, 7))).to eq(Date.new(2026, 5, 8))
    end

    it "先読み上限内に稼働日が無ければ nil（呼び出し側が fail-closed に倒す）" do
      from = Date.new(2026, 5, 2)
      (from..(from + 30)).each_with_index do |d, i|
        create(:company_calendar, date: d, day_type: :company_holiday, name: "長期休業#{i}")
      end
      expect(resolver.next_business_day(Date.new(2026, 5, 1))).to be_nil
    end
  end

  describe "HOLIDAY_DAY_TYPES（SSOT・Notifier は alias）" do
    it "休日 day_type の集合を凍結して公開する" do
      expect(described_class::HOLIDAY_DAY_TYPES)
        .to eq(%i[saturday sunday holiday legal_holiday company_holiday])
      expect(described_class::HOLIDAY_DAY_TYPES).to be_frozen
    end

    it "Notifier::HOLIDAY_DAY_TYPES は同一オブジェクト（重複定義を排除）" do
      expect(Notifier::HOLIDAY_DAY_TYPES).to equal(described_class::HOLIDAY_DAY_TYPES)
    end
  end
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `bundle exec rspec spec/services/company_calendar_resolver_spec.rb -e "next_business_day"`
Expected: FAIL（`NoMethodError: undefined method 'next_business_day'`）

- [ ] **Step 3: Resolver に定数とメソッドを追加**

`app/services/company_calendar_resolver.rb` の `FALLBACK_DAY_TYPES` の直後に定数を追加:

```ruby
  # 休日 day_type の集合（SSOT）。稼働日 = day_type ∉ この集合。
  # Notifier / AttendanceAnomalies::Detect は本定数を参照する（day_type 意味論はカレンダー領域が所有）
  HOLIDAY_DAY_TYPES = %i[saturday sunday holiday legal_holiday company_holiday].freeze

  # next_business_day の先読み上限（日）。これを超える連休は運用ミスとみなし nil を返す
  NEXT_BUSINESS_DAY_LOOKAHEAD = 30
```

`day_classifications` の直後（`private` の手前）に メソッドを追加:

```ruby
  # date の**翌日以降**で最初の稼働日を返す（連休を吸収・4-2c 猶予期限の起算・設計 §12①）。
  # 見つからなければ nil — 例外にせず呼び出し側に fail-closed（422）を委ねる。
  # day_types で 1 クエリに畳む（per-day ループで N 回引かない）
  def next_business_day(date)
    day_types(date + 1, date + NEXT_BUSINESS_DAY_LOOKAHEAD)
      .find { |_d, type| !type.in?(HOLIDAY_DAY_TYPES) }
      &.first
  end
```

- [ ] **Step 4: Notifier の定数を alias 化**

`app/services/notifier.rb:10` を置換:

```ruby
  HOLIDAY_DAY_TYPES = CompanyCalendarResolver::HOLIDAY_DAY_TYPES # SSOT は Resolver（重複定義を排除）
```

- [ ] **Step 5: テストを通す**

Run: `bundle exec rspec spec/services/company_calendar_resolver_spec.rb spec/services/notifier_spec.rb spec/services/attendance_anomalies/detect_spec.rb`
Expected: 全 PASS（新規 7 例 + 既存回帰なし。`Detect::HOLIDAY_DAY_TYPES = Notifier::HOLIDAY_DAY_TYPES` は alias 経由で同一オブジェクトを指すため無改変で動く）

- [ ] **Step 6: rubocop**

Run: `bundle exec rubocop --force-exclusion app/services/company_calendar_resolver.rb app/services/notifier.rb spec/services/company_calendar_resolver_spec.rb`
Expected: 0 offenses

- [ ] **Step 7: Commit**

```bash
git add app/services/company_calendar_resolver.rb app/services/notifier.rb spec/services/company_calendar_resolver_spec.rb
git commit -m "feat: CompanyCalendarResolver#next_business_day と HOLIDAY_DAY_TYPES の SSOT 化（§12① 猶予期限の基盤）"
```

---

## Task 2: `AttendanceRecord` の user 同一組織検証（§11⑥ 二層化）

**Files:**
- Modify: `app/models/attendance_record.rb`
- Test: `spec/models/attendance_record_spec.rb`

**Interfaces:**
- Consumes: 既存の複合 FK `attendance_records[organization_id, user_id] → users[organization_id, id]`（`schema.rb:413`・DB 層は既に防御済）。
- Produces: 他テナント `user_id` の直接代入が **DB 500 でなくクリーンな `RecordInvalid`（422）** になる。`AttendanceHistory` / `AbsenceCandidate` と同型の ID 基点 fail-closed 検証。

> §11⑥: `AttendanceRecord` にだけ `user_must_belong_to_same_organization` が無く、二層防御が DB 複合 FK の 1 層に縮退していた。**これは同一テナント別部下の越えは塞がない**（§12③ が明言・塞ぐのは `policy_scope(User).find` のみ）。本タスクは**他テナント**の越えをクリーンに落とすためのもの。

- [ ] **Step 1: 失敗するテストを書く**

`spec/models/attendance_record_spec.rb` の末尾に追加:

```ruby
  describe "user の同一組織検証（§11⑥・二層防御の model 層）" do
    let(:org) { create(:organization) }
    let(:other_org) { create(:organization, subdomain: "other") }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "他テナントの user_id を直接代入した記録は invalid（DB FK 500 でなく 422 に落とす）" do
      stranger = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      record = build(:attendance_record, work_date: Date.new(2026, 6, 2))
      record.user_id = stranger.id

      expect(record).to be_invalid
      expect(record.errors[:user]).to be_present
    end

    it "同一組織の user なら valid" do
      record = build(:attendance_record, user: create(:user), work_date: Date.new(2026, 6, 2))
      expect(record).to be_valid
    end
  end
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb -e "user の同一組織検証"`
Expected: FAIL（1 例目。`errors[:user]` は `belongs_to` presence 由来の "must exist" が立つため `be_present` は通り得るが、`be_invalid` は通る → **もし両方通ってしまう場合は本タスクの検証追加後も緑のままなので、下の Step 3 実装後に `errors.details[:user]` が `:cross_tenant` を含むことを追加 assert して判別性を確保する**）

> **RAILS_GOTCHAS 注記**: 「必須 `belongs_to` の同一組織 validator は presence と二重発火し model テストで単体検証できない」。acts_as_tenant の default_scope が他テナント user を nil 解決するため、presence 検証が先に立つ。判別性を持たせるため、実装ではカスタムエラーに `:cross_tenant` を付ける（下記）。

- [ ] **Step 3: 検証を追加**

`app/models/attendance_record.rb` の `validate :absence_reason_only_on_absent` の直後に追加:

```ruby
  validate :user_must_belong_to_same_organization
```

`private` 配下の `absence_reason_only_on_absent` の直後に追加:

```ruby
  # ID 基点 fail-closed（§3.6・複合 FK と二層）。他テナント ID の直接代入は acts_as_tenant が
  # association を nil 解決するため、user.nil? early return では fail-open になる。
  # attendance_history.rb / absence_candidate.rb と同型。:cross_tenant で presence 由来と判別可能にする
  def user_must_belong_to_same_organization
    return if user_id.nil?
    return if user&.organization_id == organization_id

    errors.add(:user, :cross_tenant, message: "は同一組織でなければなりません")
  end
```

- [ ] **Step 4: 判別性を持つ assert を追加**

Step 1 の 1 例目に 1 行足す（実装前は `:cross_tenant` が立たないので判別テストとして機能する）:

```ruby
      expect(record.errors.details[:user]).to include(a_hash_including(error: :cross_tenant))
```

- [ ] **Step 5: テストを通す**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb`
Expected: 全 PASS（新規 2 例 + 既存回帰なし）

- [ ] **Step 6: 全 spec で回帰が無いことを確認**

Run: `bundle exec rspec spec/models spec/services`
Expected: 全 PASS（既存の AR 生成経路はすべて同一組織ゆえ非回帰）

- [ ] **Step 7: rubocop + Commit**

```bash
bundle exec rubocop --force-exclusion app/models/attendance_record.rb spec/models/attendance_record_spec.rb
git add app/models/attendance_record.rb spec/models/attendance_record_spec.rb
git commit -m "feat: AttendanceRecord に user 同一組織検証を追加（§11⑥ 二層防御の対称化）"
```

---

## Task 3: Policy 2 種（`AbsenceConfirmationPolicy` / `AbsenceCandidatePolicy`）

**Files:**
- Create: `app/policies/absence_confirmation_policy.rb`
- Create: `app/policies/absence_candidate_policy.rb`
- Test: `spec/policies/absence_confirmation_policy_spec.rb`
- Test: `spec/policies/absence_candidate_policy_spec.rb`

**Interfaces:**
- Consumes: 既存 `ApplicationPolicy` / `ApplicationPolicy::Scope`（既定 deny）。`User#manager?` / `#hr_admin?` / `#manager_id`。
- Produces:
  - `AbsenceConfirmationPolicy#index? / #create?` → `manager? || hr_admin?`（headless・`authorize :absence_confirmation, :index?`）
  - `AbsenceConfirmationPolicy::Scope`（**over `User`**）→ 確定対象社員のロスター。hr_admin = 組織全員（active・**自分を含む**）/ manager = 直属部下（active）/ employee = none
  - `AbsenceCandidatePolicy#destroy?` → `manager? || hr_admin?`
  - `AbsenceCandidatePolicy::Scope`（**over `AbsenceCandidate`**）→ hr_admin = 組織全体 / manager = 直属部下の候補のみ / employee = none

> **§12⑧**: `ProxyClockingPolicy::Scope` は `.where.not(id: user.id)` で自分を除外するが、`AbsenceConfirmationPolicy::Scope` は**除外しない**。`manager_id: nil` の候補（トップ階層・hr_admin 自身）は hr_admin のみが確定できる必要があるため。manager は部下のみ（自分の候補を自分で確定できない）。

- [ ] **Step 1: 失敗するテストを書く（AbsenceConfirmationPolicy）**

`spec/policies/absence_confirmation_policy_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbsenceConfirmationPolicy do
  let(:org) { create(:organization) }
  let(:other_org) { create(:organization, subdomain: "other") }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)      { create(:user, :hr_admin) }
  let(:manager) { create(:user, :manager_role, manager: hr) }
  let(:sub)     { create(:user, manager: manager) }
  let(:stranger) { create(:user, manager: hr) } # 同一テナント・manager の部下でない
  let(:employee) { create(:user) }

  describe "role ゲート" do
    it "hr_admin は index/create 可" do
      policy = described_class.new(hr, :absence_confirmation)
      expect(policy.index?).to be(true)
      expect(policy.create?).to be(true)
    end

    it "manager は index/create 可" do
      policy = described_class.new(manager, :absence_confirmation)
      expect(policy.index?).to be(true)
      expect(policy.create?).to be(true)
    end

    it "一般社員は index/create 不可" do
      policy = described_class.new(employee, :absence_confirmation)
      expect(policy.index?).to be(false)
      expect(policy.create?).to be(false)
    end
  end

  describe "Scope（確定対象社員のロスター）" do
    def resolve(actor) = described_class::Scope.new(actor, User).resolve

    it "manager は直属部下のみ（非部下は含まない）" do
      expect(resolve(manager)).to include(sub)
      expect(resolve(manager)).not_to include(stranger)
    end

    it "manager は自分自身を含まない（自己確定の防止）" do
      expect(resolve(manager)).not_to include(manager)
    end

    it "hr_admin は組織全員を含む（自分自身も — manager_id: nil の候補は hr_admin のみ確定可・§12⑧）" do
      expect(resolve(hr)).to include(hr, manager, sub, stranger)
    end

    it "hr_admin でも他テナントの社員は含まない" do
      outsider = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      expect(resolve(hr)).not_to include(outsider)
    end

    it "退職者（active: false）は含まない" do
      retired = create(:user, manager: manager, active: false)
      expect(resolve(manager)).not_to include(retired)
    end

    it "一般社員は空" do
      expect(resolve(employee)).to be_empty
    end
  end
end
```

- [ ] **Step 2: 失敗するテストを書く（AbsenceCandidatePolicy）**

`spec/policies/absence_candidate_policy_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbsenceCandidatePolicy do
  let(:org) { create(:organization) }
  let(:other_org) { create(:organization, subdomain: "other") }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:hr)       { create(:user, :hr_admin) }
  let(:manager)  { create(:user, :manager_role, manager: hr) }
  let(:sub)      { create(:user, manager: manager) }
  let(:stranger) { create(:user, manager: hr) }
  let(:employee) { create(:user) }

  let!(:sub_candidate)      { create(:absence_candidate, user: sub, target_date: Date.new(2026, 5, 1)) }
  let!(:stranger_candidate) { create(:absence_candidate, user: stranger, target_date: Date.new(2026, 5, 1)) }

  describe "#destroy?（却下 dismiss の role ゲート）" do
    it "manager / hr_admin は却下可・一般社員は不可" do
      expect(described_class.new(manager, sub_candidate).destroy?).to be(true)
      expect(described_class.new(hr, sub_candidate).destroy?).to be(true)
      expect(described_class.new(employee, sub_candidate).destroy?).to be(false)
    end
  end

  describe "Scope" do
    def resolve(actor) = described_class::Scope.new(actor, AbsenceCandidate).resolve

    it "manager は直属部下の候補のみ（同一テナント別部下は見えない＝IDOR 封鎖）" do
      expect(resolve(manager)).to include(sub_candidate)
      expect(resolve(manager)).not_to include(stranger_candidate)
    end

    it "hr_admin は組織全体の候補" do
      expect(resolve(hr)).to include(sub_candidate, stranger_candidate)
    end

    it "他テナントの候補は hr_admin にも見えない" do
      outsider_candidate = ActsAsTenant.with_tenant(other_org) do
        create(:absence_candidate, user: create(:user, organization: other_org),
                                   organization: other_org, target_date: Date.new(2026, 5, 1))
      end
      expect(resolve(hr)).not_to include(outsider_candidate)
    end

    it "一般社員は空（自分の候補も見えない）" do
      create(:absence_candidate, user: employee, target_date: Date.new(2026, 5, 1))
      expect(resolve(employee)).to be_empty
    end
  end
end
```

- [ ] **Step 3: テストが失敗することを確認**

Run: `bundle exec rspec spec/policies/absence_confirmation_policy_spec.rb spec/policies/absence_candidate_policy_spec.rb`
Expected: FAIL（`NameError: uninitialized constant AbsenceConfirmationPolicy`）

- [ ] **Step 4: `AbsenceConfirmationPolicy` を実装**

`app/policies/absence_confirmation_policy.rb`:

```ruby
# frozen_string_literal: true

# 欠勤確定の headless policy（`authorize :absence_confirmation, :index?` — ProxyClockingPolicy 同型）。
# 認可は二層: ① role ゲート（本 policy）② 対象ゲート（controller の policy_scope.find → 404）。
# 「対象が部下か」は Scope.find に委譲する（SPEC §3.4・設計 §12③）。
class AbsenceConfirmationPolicy < ApplicationPolicy
  def index?  = manager_or_admin?
  def create? = manager_or_admin?

  # 確定対象社員のロスター（over User）。ProxyClockingPolicy::Scope と違い **自分を除外しない** —
  # manager_id: nil の候補（トップ階層・hr_admin 自身）は hr_admin のみが確定できる必要がある（§12⑧）。
  # manager 側は「直属部下」条件が自分を自然に除外する（manager_id: 自分 ≠ 自分）。
  class Scope < ApplicationPolicy::Scope
    def resolve
      base =
        if user.hr_admin?
          scope.where(organization_id: user.organization_id)
        elsif user.manager?
          scope.where(organization_id: user.organization_id, manager_id: user.id)
        else
          scope.none
        end
      base.where(active: true) # 候補は User.active にしか生えない（4-2b）
    end
  end

  private

  def manager_or_admin? = user.manager? || user.hr_admin?
end
```

- [ ] **Step 5: `AbsenceCandidatePolicy` を実装**

`app/policies/absence_candidate_policy.rb`:

```ruby
# frozen_string_literal: true

# 欠勤候補の可視範囲と却下(dismiss)の認可（設計 §5.1・§12③）。
# MonthlyAttendanceSummaryPolicy::Scope 同型だが **manager に自分の候補は見せない**（部下のみ）。
# hr_admin は組織全体（自身の候補を含む・§12⑧）。organization_id 明示（without_tenant 耐性）。
class AbsenceCandidatePolicy < ApplicationPolicy
  # 却下＝候補 destroy（監査に残さない ephemeral・§11④）。対象ゲートは Scope.find が担う
  def destroy? = user.manager? || user.hr_admin?

  class Scope < ApplicationPolicy::Scope
    def resolve
      if user.hr_admin?
        scope.where(organization_id: user.organization_id)
      elsif user.manager?
        subordinate_ids = User.where(organization_id: user.organization_id, manager_id: user.id).select(:id)
        scope.where(organization_id: user.organization_id, user_id: subordinate_ids)
      else
        scope.none
      end
    end
  end
end
```

- [ ] **Step 6: テストを通す**

Run: `bundle exec rspec spec/policies/absence_confirmation_policy_spec.rb spec/policies/absence_candidate_policy_spec.rb`
Expected: 全 PASS（13 例）

- [ ] **Step 7: rubocop + Commit**

```bash
bundle exec rubocop --force-exclusion app/policies spec/policies
git add app/policies/absence_confirmation_policy.rb app/policies/absence_candidate_policy.rb spec/policies/absence_confirmation_policy_spec.rb spec/policies/absence_candidate_policy_spec.rb
git commit -m "feat: 欠勤確定の Policy 2 種（headless role ゲート + 候補/ロスター Scope・§12③⑧）"
```

---

## Task 4: `Absences::Confirm` サービス（5 ガード + per-day savepoint）

**Files:**
- Create: `app/services/absences.rb`
- Create: `app/services/absences/confirm.rb`
- Test: `spec/services/absences/confirm_spec.rb`

**Interfaces:**
- Consumes:
  - `CompanyCalendarResolver#next_business_day(date) → Date | nil`（Task 1）
  - `AttendanceRecord` の `absent` status / `absence_reason` enum（`prefix: true`）/ `user_must_belong_to_same_organization`（Task 2）
  - `MonthlySummaries::ClosingLock.locked?(user:, dates:) → Boolean`（既存・`LOCKED = %w[submitted finalized]`）
  - `AttendanceHistory` の `absence_confirmed`（event_type 5）・`actor_id` 必須検証（4-2c-1）
- Produces:
  - `Absences::IneligibleError < Absences::Error`（毒入力・候補不在・未通知・猶予前）
  - `Absences::ClosingLockedError < Absences::Error`（締め済み月）
  - `Absences::Confirm.call(target_user:, dates:, candidates:, absence_reason:, note:, actor:) → Absences::Confirm::Result`
  - `Result = Struct.new(:confirmed_dates, :skipped_dates, keyword_init: true)`（`Array<Date>` 2 本）

> **ガード順は意味論上固定**: ① 毒入力 reason → ② 候補不在日 → ③ `notified_on` nil → ④ 猶予前 → ⑤ 締め済み。
> ① を最初に置くのは、per-day の `rescue RecordInvalid`（並行打刻の競合吸収用）が毒入力を「skip 日」として握り潰し 422 を返さなくなるのを防ぐため。
> ③ を ④ より前に置くのは `next_business_day(nil)` を計算させないため（§12①）。

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/absences/confirm_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Absences::Confirm do
  # travel_to を決定化するため TZ 固定（RAILS_GOTCHAS「org.today 相対ロジック」）
  let(:org) { create(:organization, time_zone: "Asia/Tokyo") }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:manager) { create(:user, :manager_role) }
  let(:user)    { create(:user, manager: manager) }

  let(:target_date) { Date.new(2026, 5, 1) }   # 金曜
  let(:notified_on) { Date.new(2026, 5, 1) }   # 通知日 = 金 → 翌営業日 = 5/4(月) 17:00 が猶予期限

  # 猶予経過後（2026-05-04 17:01 JST = 08:01 UTC）
  def after_grace(&) = travel_to(Time.utc(2026, 5, 4, 8, 1), &)
  # 猶予直前（2026-05-04 16:59 JST = 07:59 UTC）
  def before_grace(&) = travel_to(Time.utc(2026, 5, 4, 7, 59), &)

  def candidate(date: target_date, notified: notified_on)
    create(:absence_candidate, user:, target_date: date, notified_on: notified)
  end

  def confirm(dates:, candidates:, reason: "unauthorized", note: nil)
    described_class.call(target_user: user, dates:, candidates:,
                         absence_reason: reason, note:, actor: manager)
  end

  describe "正常系" do
    it "候補 1 日を確定し AR(absent) / 履歴を作り候補を消す" do
      c = candidate
      result = after_grace { confirm(dates: [target_date], candidates: [c]) }

      expect(result.confirmed_dates).to eq([target_date])
      expect(result.skipped_dates).to be_empty

      record = AttendanceRecord.find_by(user_id: user.id, work_date: target_date)
      expect(record.status).to eq("absent")
      expect(record.absence_reason).to eq("unauthorized")
      expect(record.clock_in).to be_nil
      expect(AbsenceCandidate.where(id: c.id)).not_to exist

      history = AttendanceHistory.find_by(user_id: user.id, event_type: :absence_confirmed,
                                          event_date: target_date)
      expect(history.actor_id).to eq(manager.id)
      expect(history.new_status).to eq(AttendanceRecord.statuses[:absent])
    end

    it "複数日を一括確定する（1 社員 × N 日付・§6.10 step 3）" do
      d2 = Date.new(2026, 5, 7)
      cs = [candidate, candidate(date: d2)]
      result = after_grace { confirm(dates: [target_date, d2], candidates: cs) }

      expect(result.confirmed_dates).to contain_exactly(target_date, d2)
      expect(AttendanceRecord.where(user_id: user.id, status: :absent).count).to eq(2)
    end

    it "other 以外は note を保存しない（§6.10）" do
      c = candidate
      after_grace { confirm(dates: [target_date], candidates: [c], reason: "illness", note: "捨てられる") }
      expect(AttendanceRecord.find_by(work_date: target_date).note).to be_nil
    end

    it "other は note を保存する" do
      c = candidate
      after_grace { confirm(dates: [target_date], candidates: [c], reason: "other", note: "私用") }
      expect(AttendanceRecord.find_by(work_date: target_date).note).to eq("私用")
    end
  end

  describe "ガード（すべて write 前に 422）" do
    it "毒入力の absence_reason は IneligibleError（per-day rescue に握り潰させない）" do
      c = candidate
      expect { after_grace { confirm(dates: [target_date], candidates: [c], reason: "bogus") } }
        .to raise_error(Absences::IneligibleError)
      expect(AttendanceRecord.count).to eq(0)
      expect(AbsenceCandidate.where(id: c.id)).to exist # 候補は intact
    end

    it "候補の無い日付が混ざれば全件拒否（却下/撤回 LR 日・過去日の捏造・§11②/§12⑨）" do
      c = candidate
      ghost = Date.new(2026, 4, 30)
      expect { after_grace { confirm(dates: [target_date, ghost], candidates: [c]) } }
        .to raise_error(Absences::IneligibleError, /存在しない日付/)
      expect(AttendanceRecord.count).to eq(0)
    end

    it "日付が空なら IneligibleError" do
      expect { after_grace { confirm(dates: [], candidates: []) } }
        .to raise_error(Absences::IneligibleError, /選択されていません/)
    end

    it "notified_on: nil の候補は確定不可（猶予計算より先に判定・§12①）" do
      c = candidate(notified: nil)
      expect { after_grace { confirm(dates: [target_date], candidates: [c]) } }
        .to raise_error(Absences::IneligibleError, /未通知/)
      expect(AttendanceRecord.count).to eq(0)
    end

    it "猶予期限（翌営業日 17:00）前は確定不可 — 16:59 JST" do
      c = candidate
      expect { before_grace { confirm(dates: [target_date], candidates: [c]) } }
        .to raise_error(Absences::IneligibleError, /猶予期限/)
      expect(AttendanceRecord.count).to eq(0)
    end

    it "猶予期限を過ぎれば確定可 — 17:01 JST（境界の有効側）" do
      c = candidate
      expect { after_grace { confirm(dates: [target_date], candidates: [c]) } }.not_to raise_error
    end

    it "連休を跨いだ猶予期限を正しく算出する（5/4・5/5 が休業なら 5/6 17:00 が期限）" do
      create(:company_calendar, date: Date.new(2026, 5, 4), day_type: :company_holiday, name: "連休")
      create(:company_calendar, date: Date.new(2026, 5, 5), day_type: :company_holiday, name: "連休")
      c = candidate

      # 5/4 17:01 JST — 旧期限なら通るが、連休吸収後は 5/6 が期限ゆえ拒否
      expect { after_grace { confirm(dates: [target_date], candidates: [c]) } }
        .to raise_error(Absences::IneligibleError, /猶予期限/)

      # 5/6 17:01 JST（08:01 UTC）
      expect { travel_to(Time.utc(2026, 5, 6, 8, 1)) { confirm(dates: [target_date], candidates: [c]) } }
        .not_to raise_error
    end

    it "締め済み（finalized）月の日付は ClosingLockedError" do
      c = candidate
      create(:monthly_attendance_summary, user:,
             year_month: AttendancePeriod.containing(organization: org, date: target_date).label,
             status: :finalized)
      expect { after_grace { confirm(dates: [target_date], candidates: [c]) } }
        .to raise_error(Absences::ClosingLockedError)
      expect(AttendanceRecord.count).to eq(0)
    end

    it "提出済（submitted）月も遮断する（§12⑩・§5.2 より厳格・意図的）" do
      c = candidate
      create(:monthly_attendance_summary, user:,
             year_month: AttendancePeriod.containing(organization: org, date: target_date).label,
             status: :submitted)
      expect { after_grace { confirm(dates: [target_date], candidates: [c]) } }
        .to raise_error(Absences::ClosingLockedError)
    end
  end

  describe "per-day savepoint（§12⑤）" do
    it "既に AR がある日は skip し、他の日は確定される（1 日の競合が全体を殺さない）" do
      d2 = Date.new(2026, 5, 7)
      cs = [candidate, candidate(date: d2)]
      create(:attendance_record, user:, work_date: target_date, status: :working) # 並行 clock_in 相当

      result = after_grace { confirm(dates: [target_date, d2], candidates: cs) }

      expect(result.skipped_dates).to eq([target_date])
      expect(result.confirmed_dates).to eq([d2])
      expect(AttendanceRecord.find_by(work_date: target_date).status).to eq("working") # 上書きしない
      expect(AttendanceRecord.find_by(work_date: d2).status).to eq("absent")
    end

    it "skip 日の候補は savepoint rollback で intact に戻る（再確定可能）" do
      c = candidate
      create(:attendance_record, user:, work_date: target_date, status: :working)

      after_grace { confirm(dates: [target_date], candidates: [c]) }

      expect(AbsenceCandidate.where(id: c.id)).to exist
      expect(AttendanceHistory.where(event_type: :absence_confirmed).count).to eq(0)
    end
  end
end
```

- [ ] **Step 2: テストが失敗することを確認**

Run: `bundle exec rspec spec/services/absences/confirm_spec.rb`
Expected: FAIL（`NameError: uninitialized constant Absences`）

- [ ] **Step 3: エラークラスを実装**

`app/services/absences.rb`（`approvals.rb` / `clockings.rb` と同型の名前空間ファイル）:

```ruby
# frozen_string_literal: true

# 欠勤確定の service 名前空間（Approvals 同型）。controller が rescue して 422 に落とす。
module Absences
  class Error < StandardError; end

  # 確定不可（毒入力理由 / 候補不在日 / 本人未通知 / 猶予前）。適正手続きの入口ガード（§10⑤・§12①）
  class IneligibleError < Error; end

  # 締め済み（submitted / finalized）月の日付は確定不可（§11⑦・§12⑩）
  class ClosingLockedError < Error; end
end
```

- [ ] **Step 4: `Absences::Confirm` を実装**

`app/services/absences/confirm.rb`:

```ruby
# frozen_string_literal: true

module Absences
  # 欠勤確定の副作用本体（SPEC §6.10 step 4-5・設計 §5.2 / §11⑥⑦ / §12①③④⑤）。
  #
  # 権威源は AbsenceCandidate — params 日付を権威にしない（§11②）。呼び出し元 controller が
  # policy_scope で target_user と candidates を解決して渡す（IDOR は解決側で塞ぐ・§12③）。
  #
  # ガード順は意味論上固定:
  #   ① 毒入力 reason → ② 候補不在日 → ③ notified_on nil → ④ 猶予前 → ⑤ 締め済み
  #   ① を先頭に置くのは、per-day の rescue RecordInvalid（並行打刻の競合吸収）が毒入力を
  #     「skip 日」として握り潰し 422 を返さなくなるのを防ぐため（部分成功にしない）。
  #   ③ を ④ より前に置くのは next_business_day(nil) を計算させないため（§12①）。
  class Confirm
    Result = Struct.new(:confirmed_dates, :skipped_dates, keyword_init: true)

    # 猶予期限の時刻（組織 TZ）。SPEC §6.8「猶予: 翌営業日 17:00」
    GRACE_DEADLINE_HOUR = 17

    def self.call(**) = new(**).call

    def initialize(target_user:, dates:, candidates:, absence_reason:, note:, actor:)
      @target_user = target_user
      @dates = Array(dates).uniq.sort
      @candidates = candidates.to_a.sort_by(&:target_date)
      @absence_reason = absence_reason.to_s
      @note = note
      @actor = actor
    end

    def call
      guard_reason!
      guard_candidates_exist!
      guard_notified!
      guard_grace_period!
      guard_closing!
      confirm_all
    end

    private

    def organization = @target_user.organization

    # ① 毒入力（permit する enum ゆえ不正値は 422 に落とす・§11⑩ 同型）
    def guard_reason!
      return if AttendanceRecord.absence_reasons.key?(@absence_reason)

      raise IneligibleError, "欠勤理由が不正です"
    end

    # ② 候補の無い日付（却下/撤回された休暇日・過去日の捏造）は確定不可。
    #    v1 では「候補に無い日の欠勤確定」を一切認めない（§11②・§12⑨ の plan 判断）
    def guard_candidates_exist!
      raise IneligibleError, "欠勤候補が選択されていません" if @dates.empty?
      return if @candidates.map(&:target_date).sort == @dates

      raise IneligibleError, "欠勤候補に存在しない日付が含まれています"
    end

    # ③ notified_on nil = 本人へ事前通知が届いていない → 弁明機会ゼロ（労基法 24 条・§12①）。
    #    4-2b は本人宛 Notifier 成功後にのみ notified_on を立てるため presence を弁明機会の proxy にできる
    def guard_notified!
      return if @candidates.all? { |candidate| candidate.notified_on.present? }

      raise IneligibleError, "本人へ未通知の欠勤候補は確定できません（次回の日次バッチで通知されます）"
    end

    # ④ 猶予 = notified_on の翌営業日 17:00（組織 TZ）。経過前は確定不可（§10⑤ 適正手続き）
    def guard_grace_period!
      now = Time.current
      @candidates.each do |candidate|
        deadline = grace_deadline(candidate.notified_on)
        raise IneligibleError, "猶予期限を算出できません（稼働日が見つかりません）" if deadline.nil?
        next if now > deadline

        raise IneligibleError,
              "猶予期限（#{deadline.strftime('%Y-%m-%d %H:%M')}）を過ぎるまで #{candidate.target_date} は確定できません"
      end
    end

    def grace_deadline(notified_on)
      next_day = resolver.next_business_day(notified_on)
      return nil if next_day.nil?

      ActiveSupport::TimeZone[organization.time_zone]
        .local(next_day.year, next_day.month, next_day.day, GRACE_DEADLINE_HOUR)
    end

    # ⑤ 締め済み月の日付は確定不可（§11⑦）。既存 ClosingLock の LOCKED は submitted を含む＝
    #    設計 §5.2 の「finalized 禁止・deferred 許可」より厳格（§12⑩・本計画で意図的に採用）。
    #    write 前に対象全日を一括評価し、1 日でも locked なら全件拒否
    def guard_closing!
      return unless MonthlySummaries::ClosingLock.locked?(user: @target_user, dates: @dates)

      raise ClosingLockedError, "締め済みの月（提出済 / 確定）の日付は欠勤確定できません"
    end

    def confirm_all
      confirmed = []
      skipped = []
      # request 文脈前提だが ApplyApproval 同型で明示ラップ（文脈喪失・将来バッチ化に fail-closed）
      ActsAsTenant.with_tenant(organization) do
        ActiveRecord::Base.transaction do
          @candidates.each do |candidate|
            confirm_one(candidate)
            confirmed << candidate.target_date
          rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid
            # 並行 clock_in / CCR 承認が同日 AR を先に作った等。savepoint のみ rollback され
            # 親 tx は健全・候補は intact（再確定可能）。1 日の競合が確定バッチ全体を殺さない（§12⑤）
            skipped << candidate.target_date
          end
        end
      end
      Result.new(confirmed_dates: confirmed, skipped_dates: skipped)
    end

    # 1 日 = {AR create → 候補 destroy → history create} を 1 savepoint に束ねる（§12⑤）。
    # insert_all/upsert_all は使わない — belongs_to presence（IDOR 防御）と
    # absence_reason_only_on_absent（毒入力防御）の 2 検証を skip するため（§12④）
    def confirm_one(candidate)
      ActiveRecord::Base.transaction(requires_new: true) do
        AttendanceRecord.create!(
          user: @target_user, work_date: candidate.target_date,
          status: :absent, absence_reason: @absence_reason, note: note_for_reason
        )
        candidate.destroy!
        AttendanceHistory.create!(
          user: @target_user, actor: @actor,
          event_type: :absence_confirmed, event_date: candidate.target_date,
          new_status: AttendanceRecord.statuses[:absent],
          note: history_note
        )
      end
    end

    # other 選択時のみ note に理由を入れる。other 以外は note=null（SPEC §6.10）
    def note_for_reason = @absence_reason == "other" ? @note.presence : nil

    # AR.absence_reason は事後有給（absent→on_leave）でクリアされるため、確定時点の理由を監査へ焼く
    def history_note = "欠勤理由: #{reason_label}"

    def reason_label
      I18n.t("activerecord.attributes.attendance_record.absence_reasons.#{@absence_reason}")
    end

    def resolver = @resolver ||= CompanyCalendarResolver.new(organization:)
  end
end
```

- [ ] **Step 5: i18n ラベルを先行追加（`reason_label` が参照する）**

`config/locales/ja.yml` の `activerecord.attributes.attendance_record` 配下、`proxy_clock_reasons` の直前に追加:

```yaml
        absence_reasons:
          unauthorized: 無届欠勤
          illness: 疾病・傷病
          family: 家庭事情
          investigating: 打刻漏れ調査中
          other: その他
```

> インデントは既存の `proxy_clock_reasons:` と**同一階層**に合わせること。編集後に `bundle exec ruby -ryaml -e 'YAML.load_file("config/locales/ja.yml")'` で構文確認。

- [ ] **Step 6: テストを通す**

Run: `bundle exec rspec spec/services/absences/confirm_spec.rb`
Expected: 全 PASS（15 例）

> **落ちたら疑う点**: `monthly_attendance_summaries` factory の必須列（`year_month` のラベル形式は `AttendancePeriod#label`）／ `absence_candidate` factory の `notified_on` 既定は nil ゆえ明示指定が要る／ `travel_to` の UTC↔JST 換算（JST 17:01 = UTC 08:01）。

- [ ] **Step 7: rubocop + Commit**

```bash
bundle exec rubocop --force-exclusion app/services/absences.rb app/services/absences/confirm.rb spec/services/absences/confirm_spec.rb
git add app/services/absences.rb app/services/absences/confirm.rb spec/services/absences/confirm_spec.rb config/locales/ja.yml
git commit -m "feat: Absences::Confirm（5 ガード + per-day savepoint・§11⑥⑦/§12①③④⑤）"
```

---

## Task 5: `AbsenceConfirmationsController` + routes + view + GlobalNav

**Files:**
- Create: `app/controllers/absence_confirmations_controller.rb`
- Create: `app/views/absence_confirmations/index.html.erb`
- Modify: `config/routes.rb`
- Modify: `app/components/global_nav_component.rb`
- Test: `spec/requests/absence_confirmations_spec.rb`
- Test: `spec/requests/global_nav_spec.rb`（追記）

**Interfaces:**
- Consumes: `AbsenceConfirmationPolicy` / `AbsenceCandidatePolicy`（Task 3）、`Absences::Confirm` と 2 エラークラス（Task 4）。
- Produces:
  - route `absence_confirmations_path`（GET index / POST create）、`absence_confirmation_path(candidate)`（DELETE = 却下）
  - GlobalNav 項目「欠勤確定」（manager\|hr_admin）
  - controller private: `roster`（`policy_scope(User, policy_scope_class: AbsenceConfirmationPolicy::Scope)`）

> **注意**: 通知（`Notifier`）は Task 6 で足す。本タスクは確定・却下・一覧・認可までを完成させる。

- [ ] **Step 1: routes を追加**

`config/routes.rb` の `resources :monthly_attendance_summaries ... end` の直後に追加:

```ruby
  # 欠勤確定（§6.10）。destroy = 却下(dismiss)・:id は AbsenceCandidate#id（候補は ephemeral・§11④）
  resources :absence_confirmations, only: %i[index create destroy]
```

- [ ] **Step 2: 失敗するテストを書く**

`spec/requests/absence_confirmations_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe "AbsenceConfirmations", type: :request do
  let!(:org) { create(:organization, subdomain: "acme", time_zone: "Asia/Tokyo") }
  let!(:hr)       { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin, name: "人事 花子") } }
  let!(:manager)  { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, manager: hr, name: "上長 一郎") } }
  let!(:sub)      { ActsAsTenant.with_tenant(org) { create(:user, manager: manager, name: "部下 太郎") } }
  let!(:stranger) { ActsAsTenant.with_tenant(org) { create(:user, manager: hr, name: "他部 次郎") } }

  let(:target_date) { Date.new(2026, 5, 1) }   # 金曜 → 翌営業日 5/4(月) 17:00 が猶予期限

  def candidate_for(user, date: target_date, notified: Date.new(2026, 5, 1))
    ActsAsTenant.with_tenant(org) { create(:absence_candidate, user:, target_date: date, notified_on: notified) }
  end

  # 猶予経過後（2026-05-04 17:01 JST = 08:01 UTC）
  def after_grace(&) = travel_to(Time.utc(2026, 5, 4, 8, 1), &)

  def confirm_params(user, dates, reason: "unauthorized", note: nil)
    { user_id: user.id, dates: dates.map(&:to_s), absence_reason: reason, note: }
  end

  describe "GET index" do
    it "manager は部下の候補のみ見える（同一テナント別部下は見えない）" do
      candidate_for(sub)
      candidate_for(stranger)
      sign_in manager

      get absence_confirmations_url(host: tenant_host(org))

      expect(response.body).to include(sub.name)
      expect(response.body).not_to include(stranger.name)
    end

    it "hr_admin は組織全体の候補が見える" do
      candidate_for(sub)
      candidate_for(stranger)
      sign_in hr

      get absence_confirmations_url(host: tenant_host(org))

      expect(response.body).to include(sub.name, stranger.name)
    end

    it "一般社員は 403（role ゲート）" do
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get absence_confirmations_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "POST create（確定）" do
    it "部下の候補を確定し AR(absent) を作る" do
      candidate_for(sub)
      sign_in manager

      after_grace do
        expect { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [target_date]) }
          .to change { AttendanceRecord.unscoped.where(status: :absent).count }.by(1)
      end
      expect(response).to have_http_status(:see_other)
      expect(AbsenceCandidate.unscoped.count).to eq(0)
    end

    it "同一テナントの別部下は 404（IDOR variant 1 — Pundit Scope）" do
      candidate_for(stranger)
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(stranger, [target_date]) }

      expect(response).to have_http_status(:not_found)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "他テナントの社員は 404（IDOR variant 2 — acts_as_tenant）" do
      other_org = create(:organization, subdomain: "other")
      outsider = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      sign_in hr

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(outsider, [target_date]) }

      expect(response).to have_http_status(:not_found)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "候補の無い日付は 422（却下/撤回 LR 日の捏造を塞ぐ・§12⑨）" do
      candidate_for(sub)
      sign_in manager

      after_grace do
        post absence_confirmations_url(host: tenant_host(org)),
             params: confirm_params(sub, [target_date, Date.new(2026, 4, 30)])
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "notified_on: nil の候補は 422（§12①）" do
      candidate_for(sub, notified: nil)
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [target_date]) }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "猶予期限前は 422（16:59 JST）" do
      candidate_for(sub)
      sign_in manager

      travel_to(Time.utc(2026, 5, 4, 7, 59)) do
        post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [target_date])
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "不正な日付文字列は 422（Date.iso8601 の厳格 parse）" do
      candidate_for(sub)
      sign_in manager

      after_grace do
        post absence_confirmations_url(host: tenant_host(org)),
             params: { user_id: sub.id, dates: [ "2026-13-99" ], absence_reason: "unauthorized" }
      end

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "毒入力の absence_reason は 422（部分成功にしない）" do
      candidate_for(sub)
      sign_in manager

      after_grace do
        post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [target_date], reason: "bogus")
      end

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end

    it "hr_admin は manager_id: nil の社員（自分自身）も確定できる（§12⑧）" do
      candidate_for(hr)
      sign_in hr

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(hr, [target_date]) }

      expect(response).to have_http_status(:see_other)
      expect(AttendanceRecord.unscoped.where(user_id: hr.id, status: :absent).count).to eq(1)
    end

    it "manager は hr_admin（自分の上長）の候補を確定できない（404）" do
      candidate_for(hr)
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(hr, [target_date]) }

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE destroy（却下 dismiss・§11④/§12⑧）" do
    it "manager は部下の候補を却下でき AR は作られない" do
      c = candidate_for(sub)
      sign_in manager

      expect { delete absence_confirmation_url(c, host: tenant_host(org)) }
        .to change { AbsenceCandidate.unscoped.count }.by(-1)

      expect(response).to have_http_status(:see_other)
      expect(AttendanceRecord.unscoped.count).to eq(0)
      expect(AttendanceHistory.unscoped.count).to eq(0) # ephemeral：監査に残さない
    end

    it "却下は猶予期限前でも可（確定と違い不利益処分でない）" do
      c = candidate_for(sub)
      sign_in manager
      travel_to(Time.utc(2026, 5, 1, 1)) { delete absence_confirmation_url(c, host: tenant_host(org)) }
      expect(AbsenceCandidate.unscoped.count).to eq(0)
    end

    it "同一テナント別部下の候補は 404（IDOR）" do
      c = candidate_for(stranger)
      sign_in manager
      delete absence_confirmation_url(c, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(AbsenceCandidate.unscoped.count).to eq(1)
    end

    it "一般社員は 403" do
      c = candidate_for(sub)
      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      delete absence_confirmation_url(c, host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)
    end
  end
end
```

> **一般社員の DELETE が 403 になる理由**: `policy_scope(AbsenceCandidate)` は一般社員に `none` を返すため `find` は `RecordNotFound` → 404 になる。**403 を期待するなら `authorize` を `find` より先に呼ぶ**必要がある。実装（Step 3）では `authorize AbsenceCandidate, :destroy?`（class-level role ゲート）を先に置き、その後 `policy_scope(...).find` で対象ゲート（404）を掛ける二層にする。

- [ ] **Step 3: controller を実装**

`app/controllers/absence_confirmations_controller.rb`:

```ruby
# frozen_string_literal: true

# 欠勤確定（SPEC §6.10・設計 §5 / §11⑥ / §12③⑧）。管理者が欠勤候補を確認し、確定 or 却下する。
# 認可は二層: ① role ゲート（authorize）② 対象ゲート（policy_scope.find → 404）。
# 対象社員を policy_scope(User) 経由で解決することが、**同一テナントの他部下**を塞ぐ唯一の壁（§12③）。
class AbsenceConfirmationsController < ApplicationController
  def index
    authorize :absence_confirmation, :index?
    load_candidates
  end

  # 1 社員 × N 日付の一括確定（§6.10 step 3-5）。日付の権威は候補テーブル（params ではない）
  def create
    authorize :absence_confirmation, :create?
    target = roster.find(params[:user_id])
    dates = parse_dates(params[:dates])
    Absences::Confirm.call(
      target_user: target, dates:,
      candidates: policy_scope(AbsenceCandidate).where(user_id: target.id, target_date: dates),
      absence_reason: params[:absence_reason], note: params[:note], actor: current_user
    )
    redirect_to absence_confirmations_path, status: :see_other, notice: "欠勤を確定しました"
  rescue Date::Error, TypeError
    render_ineligible("日付の指定が正しくありません")
  rescue Absences::IneligibleError, Absences::ClosingLockedError => e
    render_ineligible(e.message)
  end

  # 却下(dismiss)＝候補を削除して一覧から除く（§11④・§12⑧）。監査には残さない（候補は ephemeral）。
  # 不利益処分でないため猶予期限の制約は掛けない
  def destroy
    authorize AbsenceCandidate, :destroy?             # ① role ゲート（一般社員は 403）
    candidate = policy_scope(AbsenceCandidate).find(params[:id]) # ② 対象ゲート（scope 外は 404）
    candidate.destroy!
    redirect_to absence_confirmations_path, status: :see_other, notice: "欠勤候補を却下しました"
  end

  private

  def load_candidates
    @candidates = policy_scope(AbsenceCandidate).includes(:user).order(:user_id, :target_date)
  end

  # policy_scope(User) は top-level UserPolicy 不在で NotDefinedError ゆえ scope class 明示（RAILS_GOTCHAS）
  def roster = policy_scope(User, policy_scope_class: AbsenceConfirmationPolicy::Scope)

  # 厳格 ISO8601。Date.parse は "2026-13-99" 等のゴミを黙認し得る（RAILS_GOTCHAS）
  def parse_dates(raw) = Array(raw).map { |value| Date.iso8601(value.to_s) }

  def render_ineligible(message)
    load_candidates
    flash.now[:alert] = message
    render :index, status: :unprocessable_entity
  end
end
```

> `create` は `Absences::Confirm` の `Result` を今は使わない（skip 日の flash 併記と通知は Task 6 で足す）。

- [ ] **Step 4: view を実装**

`app/views/absence_confirmations/index.html.erb`:

```erb
<main class="mx-auto w-full max-w-4xl p-4">
  <h1 class="text-2xl font-bold">欠勤確定</h1>

  <p class="mt-3 rounded bg-yellow-50 p-3 text-sm text-yellow-900">
    候補は<strong>会社カレンダーの稼働日</strong>から検出しています。非常勤・シフト勤務者の
    <strong>所定労働日でない日</strong>が含まれることがあります。所定労働日かを確認し、
    欠勤でない候補は「却下」してください。
  </p>

  <% if @candidates.empty? %>
    <p class="mt-6 text-gray-600">欠勤候補はありません。</p>
  <% else %>
    <% reason_options = AttendanceRecord.absence_reasons.keys.map { |key|
         [t("activerecord.attributes.attendance_record.absence_reasons.#{key}"), key] } %>

    <% @candidates.group_by(&:user).each do |user, candidates| %>
      <section class="mt-8 rounded border border-gray-300 p-4">
        <h2 class="text-lg font-bold"><%= user.name %>（<%= user.employee_code %>）</h2>

        <ul class="mt-3 divide-y divide-gray-100">
          <% candidates.each do |candidate| %>
            <li class="flex flex-wrap items-center justify-between gap-3 py-2 text-sm">
              <label class="flex items-center gap-2">
                <%# HTML5 の form 属性で、DOM 上は外にあるチェックボックスを下の form に紐付ける
                    （button_to が生成する form との入れ子を避ける） %>
                <%= check_box_tag "dates[]", candidate.target_date.iso8601, false,
                      id: "candidate_#{candidate.id}", form: "confirm_#{user.id}",
                      disabled: candidate.notified_on.nil? %>
                <span><%= candidate.target_date %></span>
              </label>

              <div class="flex items-center gap-3">
                <span class="text-xs <%= candidate.notified_on ? 'text-gray-500' : 'text-red-600' %>">
                  <%= candidate.notified_on ? "本人通知済（#{candidate.notified_on}）" : "本人未通知（確定不可）" %>
                </span>
                <%= button_to "却下", absence_confirmation_path(candidate), method: :delete,
                      class: "rounded border border-gray-300 px-3 py-1 text-gray-700 hover:bg-gray-100",
                      form: { data: { turbo_confirm: "#{candidate.target_date} の欠勤候補を却下します。よろしいですか？" } } %>
              </div>
            </li>
          <% end %>
        </ul>

        <%= form_with url: absence_confirmations_path, method: :post, id: "confirm_#{user.id}",
                      class: "mt-4 flex flex-wrap items-center gap-2" do %>
          <%= hidden_field_tag :user_id, user.id %>
          <%= select_tag :absence_reason, options_for_select(reason_options),
                class: "rounded border-gray-300 text-sm", "aria-label": "欠勤理由" %>
          <%= text_field_tag :note, nil, placeholder: "「その他」の場合のみ理由を入力",
                class: "grow rounded border-gray-300 text-sm" %>
          <%= submit_tag "選択した日を欠勤確定", class: "rounded bg-blue-600 px-4 py-2 text-white" %>
        <% end %>
      </section>
    <% end %>
  <% end %>
</main>
```

- [ ] **Step 5: GlobalNav に「欠勤確定」を追加**

`app/components/global_nav_component.rb` の `if approver?` ブロック内、`代理打刻` の直後に追加:

```ruby
      items << [ "欠勤確定", helpers.absence_confirmations_path, nil ]
```

`spec/requests/global_nav_spec.rb` に追記（既存の describe 群に合わせる）:

```ruby
    it "manager には「欠勤確定」リンクが出る" do
      sign_in manager
      get root_url(host: tenant_host(org))
      expect(response.body).to include(absence_confirmations_path)
    end

    it "一般社員には「欠勤確定」リンクが出ない" do
      sign_in employee
      get root_url(host: tenant_host(org))
      expect(response.body).not_to include(absence_confirmations_path)
    end
```

> `global_nav_spec.rb` の既存 `let` 名（`org` / `manager` / `employee`）に合わせること。異なる場合は既存に合わせて改名する。

- [ ] **Step 6: テストを通す**

Run: `bundle exec rspec spec/requests/absence_confirmations_spec.rb spec/requests/global_nav_spec.rb`
Expected: 全 PASS（16 + 2 例）

- [ ] **Step 7: 既存 request spec の回帰を確認**

Run: `bundle exec rspec spec/requests spec/components`
Expected: 全 PASS（ナビ項目が 1 つ増えるため、`not_to include(...)` でナビ文言に誤発火する既存 spec があれば調整する — 2-2b / 3-2 で同種の調整が入った前例あり）

- [ ] **Step 8: rubocop + Commit**

```bash
bundle exec rubocop --force-exclusion app/controllers/absence_confirmations_controller.rb app/components/global_nav_component.rb spec/requests/absence_confirmations_spec.rb
git add app/controllers/absence_confirmations_controller.rb app/views/absence_confirmations app/components/global_nav_component.rb config/routes.rb spec/requests/absence_confirmations_spec.rb spec/requests/global_nav_spec.rb
git commit -m "feat: 欠勤確定 UI（一覧・一括確定・却下・GlobalNav 動線・IDOR 2 variant）"
```

---

## Task 6: 確定通知 producer + 4-2b 事前通知文の縮小（§11③・§12⑦）

**Files:**
- Modify: `app/controllers/absence_confirmations_controller.rb`
- Modify: `app/services/attendance_anomalies/detect.rb:104-110`
- Test: `spec/requests/absence_confirmations_spec.rb`（追記）
- Test: `spec/services/attendance_anomalies/detect_spec.rb`（追記）

**Interfaces:**
- Consumes: `Notifier.call(target_user:, title:, body:, priority:, source_type:, subject_user:)`（既存）。`Notification.source_types` の `absence_confirmed`（既存・4-2a で予約済）。`Absences::Confirm::Result#confirmed_dates` / `#skipped_dates`（Task 4）。
- Produces:
  - 確定 tx **commit 後**に本人へ `absence_confirmed` 通知 1 件（1 社員 × N 日付を集約）。`priority: :action_required`（J4）
  - 通知失敗は rescue+log（主操作の応答を覆さない・§9.5・4-1c producer 同型）
  - skip 日があれば flash に併記
  - 4-2b 事前通知 body から「打刻変更申請を提出してください」を削除

> **なぜ「事後に有給休暇の申請ができます」と書いてよいか**: 4-2c-1（PR #32）で `LeaveRequests::ApplyApproval` が `absent → on_leave` の随伴列クリアと `absence_to_paid` 記録を実装済み。**打刻変更申請は依然 CCR `new_entry` が拒否**（#48）ゆえ約束しない（§11③・§12⑦）。

- [ ] **Step 1: 失敗するテストを書く（確定通知）**

`spec/requests/absence_confirmations_spec.rb` の `describe "POST create（確定）"` 内に追加:

```ruby
    it "確定後に本人へ absence_confirmed 通知を 1 件だけ送る（N 日付を 1 件に集約・§6.10 step 5）" do
      d2 = Date.new(2026, 5, 7)
      candidate_for(sub)
      candidate_for(sub, date: d2)
      sign_in manager

      after_grace do
        post absence_confirmations_url(host: tenant_host(org)),
             params: confirm_params(sub, [target_date, d2])
      end

      notifications = Notification.unscoped.where(target_user_id: sub.id, source_type: :absence_confirmed)
      expect(notifications.count).to eq(1)
      expect(notifications.first.priority).to eq("action_required")
      expect(notifications.first.body).to include("計 2 日", "有給休暇")
      expect(notifications.first.body).not_to include("打刻変更") # CCR new_entry は依然拒否（#48）
    end

    it "確定できた日が 0 件なら通知しない（幻通知の防止）" do
      candidate_for(sub)
      ActsAsTenant.with_tenant(org) { create(:attendance_record, user: sub, work_date: target_date, status: :working) }
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [target_date]) }

      expect(Notification.unscoped.where(source_type: :absence_confirmed).count).to eq(0)
    end

    it "通知が失敗しても確定は覆らない（§9.5 rescue+log）" do
      candidate_for(sub)
      allow(Notifier).to receive(:call).and_raise(StandardError, "boom")
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [target_date]) }

      expect(response).to have_http_status(:see_other)
      expect(AttendanceRecord.unscoped.where(status: :absent).count).to eq(1)
    end

    it "skip 日は flash に併記される" do
      d2 = Date.new(2026, 5, 7)
      candidate_for(sub)
      candidate_for(sub, date: d2)
      ActsAsTenant.with_tenant(org) { create(:attendance_record, user: sub, work_date: target_date, status: :working) }
      sign_in manager

      after_grace do
        post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [target_date, d2])
      end

      expect(flash[:notice]).to include(target_date.to_s)
      expect(flash[:notice]).to include("スキップ")
    end
```

- [ ] **Step 2: 失敗するテストを書く（4-2b 事前通知文）**

`spec/services/attendance_anomalies/detect_spec.rb` の候補通知の describe 内に追加:

```ruby
    it "事前通知の body は打刻変更申請を約束しない（CCR new_entry 拒否ゆえ非機能・§12⑦）" do
      # 既存の「本人稼働日 run で candidate を通知する」例と同じ setup を用いること
      notification = notifications_for(user, :absence_candidate).first
      expect(notification.body).not_to include("打刻変更申請")
      expect(notification.body).to include("管理者")
    end
```

> 既存 spec の該当 describe（`process_candidates` の notify-once 群）に置き、その describe の `before` で作られた候補・通知を再利用すること。

- [ ] **Step 3: テストが失敗することを確認**

Run: `bundle exec rspec spec/requests/absence_confirmations_spec.rb spec/services/attendance_anomalies/detect_spec.rb`
Expected: FAIL（通知 0 件 / body に「打刻変更申請」が残っている）

- [ ] **Step 4: controller に通知 producer を足す**

`app/controllers/absence_confirmations_controller.rb` の `create` を差し替え:

```ruby
  def create
    authorize :absence_confirmation, :create?
    target = roster.find(params[:user_id])
    dates = parse_dates(params[:dates])
    result = Absences::Confirm.call(
      target_user: target, dates:,
      candidates: policy_scope(AbsenceCandidate).where(user_id: target.id, target_date: dates),
      absence_reason: params[:absence_reason], note: params[:note], actor: current_user
    )
    notify_confirmed(target, result.confirmed_dates) if result.confirmed_dates.any?
    redirect_to absence_confirmations_path, status: :see_other, notice: confirm_notice(result)
  rescue Date::Error, TypeError
    render_ineligible("日付の指定が正しくありません")
  rescue Absences::IneligibleError, Absences::ClosingLockedError => e
    render_ineligible(e.message)
  end
```

private に追加（`render_ineligible` の直後）:

```ruby
  def confirm_notice(result)
    notice = "#{result.confirmed_dates.size} 日を欠勤確定しました"
    return notice if result.skipped_dates.empty?

    "#{notice}（#{result.skipped_dates.join(', ')} は既に勤怠記録があるためスキップしました）"
  end

  # 確定 tx の commit 後に発火（§9③ 幻通知の防止）。1 社員 × N 日付を 1 件に集約（§6.10 step 5）。
  # priority は action_required — 賃金控除に直結する不利益処分の告知で、本人に「事後の有給申請」
  # という action がある（SPEC §9.1 の「月次差戻し」と同格）。
  # 4-2c-1（PR #32）で absent→on_leave の事後有給パスが live 化したため有給申請を案内できる（§11③）。
  # 打刻変更申請は CCR new_entry が拒否のまま（#48）ゆえ約束しない。
  def notify_confirmed(target, dates)
    Notifier.call(
      target_user: target, subject_user: target,
      priority: :action_required, source_type: :absence_confirmed,
      title: "欠勤が確定されました",
      body: "#{dates.join(', ')}（計 #{dates.size} 日）の欠勤が確定されました。" \
            "事後に有給休暇の申請ができます。ご不明な点は管理者へお問い合わせください。"
    )
  rescue StandardError => e
    # 通知は確定（commit 済）の副次効果。失敗しても主操作の応答を覆さない（§9.5・4-1c producer 同型）
    Rails.logger.error(
      "[Notifier] producer 通知失敗 source_type=absence_confirmed user=#{target.id}: #{e.class}: #{e.message}"
    )
  end
```

- [ ] **Step 5: 4-2b の事前通知 body を縮小**

`app/services/attendance_anomalies/detect.rb` の `notify_candidate` の `body:` を置換:

```ruby
        body: "#{candidate.target_date} の出勤記録がありません。" \
              "心当たりがある場合は、翌営業日 17:00 までに管理者へお問い合わせください。"
```

> **§12⑦**: 候補は定義上 no-AR 日ゆえ CCR（`new_entry` 拒否・既存 AR 前提の検証）が全滅で「打刻変更申請」は非機能。#48 で CCR `new_entry` が解除されるまで約束しない。猶予期限（翌営業日 17:00）は 4-2c-2 の `Absences::Confirm#guard_grace_period!` がバックエンドで強制するようになったため、本文で告知してよい（SPEC §6.8 の文言と整合）。

- [ ] **Step 6: テストを通す**

Run: `bundle exec rspec spec/requests/absence_confirmations_spec.rb spec/services/attendance_anomalies/detect_spec.rb`
Expected: 全 PASS

- [ ] **Step 7: rubocop + Commit**

```bash
bundle exec rubocop --force-exclusion app/controllers/absence_confirmations_controller.rb app/services/attendance_anomalies/detect.rb
git add app/controllers/absence_confirmations_controller.rb app/services/attendance_anomalies/detect.rb spec/requests/absence_confirmations_spec.rb spec/services/attendance_anomalies/detect_spec.rb
git commit -m "feat: 欠勤確定通知（集約 1 件・tx 後発火）と 4-2b 事前通知文の虚偽 remedy 削除（§11③/§12⑦）"
```

---

## Task 7: W1（元 `absence_reason` の監査退避）+ W2（実 approve path の統合テスト）

**Files:**
- Modify: `app/services/leave_requests/apply_approval.rb`
- Test: `spec/services/leave_requests/apply_approval_spec.rb`（追記）
- Test: `spec/requests/approval_assignments_spec.rb`（追記）

**Interfaces:**
- Consumes: 4-2c-1 の `was_absent` 捕捉と `record_absence_to_paid(record, date)`（既存）。Task 4 で追加した i18n `absence_reasons` ラベル。
- Produces: `record_absence_to_paid(record, date, previous_absence_reason)` — シグネチャに第 3 引数を追加し、`AttendanceHistory#note` に「欠勤理由: {ラベル}」を焼く。

> **W1（4-2c-1 レビュー申し送り）**: `absent → on_leave` で `absence_reason` は `nil` にクリアされるため、`previous_status: absent` だけでは「どの欠勤が有給へ振り替わったか」が労基法 109 条の証跡から落ちる。**クリア前に捕捉**して history の `note` へ退避する（capture-before-assign と同じ罠 — `record.absence_reason = nil` の**後**に読むと常に nil）。
>
> **W2（同上）**: 4-2c-1 の回帰テストは `ApplyApproval.call` の直呼びのみ。§12② が要求した「実 approve path」（`Approvals::Approve` の `with_lock` 内で走り、失敗すれば承認 tx ごと rollback する経路）は未検証。request spec で端から端まで通す。

- [ ] **Step 1: 失敗するテストを書く（W1）**

`spec/services/leave_requests/apply_approval_spec.rb` の `describe "absent→on_leave 事後有給の上書き（§11①/§12②⑥）"` 内に追加:

```ruby
    it "absence_to_paid の note に元の欠勤理由を退避する（W1・労基法 109 条の証跡）" do
      create(:attendance_record, user:, work_date: start_date, status: :absent,
                                 absence_reason: :illness, clock_in: nil)

      apply(leave(type: unpaid_type, sd: start_date, ed: start_date))

      history = AttendanceHistory.find_by(user_id: user.id, event_type: :absence_to_paid,
                                          event_date: start_date)
      expect(history.note).to eq("欠勤理由: 疾病・傷病")
    end

    it "absent でない日の on_leave 作成では absence_to_paid を記録しない（note も生えない）" do
      apply(leave(type: unpaid_type, sd: start_date, ed: start_date))
      expect(AttendanceHistory.where(event_type: :absence_to_paid)).not_to exist
    end
```

- [ ] **Step 2: 失敗するテストを書く（W2・実 approve path）**

`spec/requests/approval_assignments_spec.rb` の末尾に describe を追加:

```ruby
  describe "PATCH approve（absent 日への事後有給・§11①/§12② 実 approve path）" do
    it "欠勤確定済の日を覆う休暇承認が rollback せず on_leave へ昇格し absence_reason をクリアする" do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, user: emp, work_date: Date.new(2026, 5, 1), status: :absent,
                                   absence_reason: :unauthorized, clock_in: nil, note: "調査中")
      end

      sign_in boss
      patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org))
      sign_in dept
      patch approve_approval_assignment_url(assignment_for(2), host: tenant_host(org))

      expect(response).to have_http_status(:see_other)

      ActsAsTenant.with_tenant(org) do
        expect(leave.reload.approval_status).to eq("approved") # 承認 tx が rollback していない
        record = AttendanceRecord.find_by(user_id: emp.id, work_date: Date.new(2026, 5, 1))
        expect(record.status).to eq("on_leave")
        expect(record.absence_reason).to be_nil
        expect(record.note).to be_nil

        history = AttendanceHistory.find_by(user_id: emp.id, event_type: :absence_to_paid)
        expect(history).to be_present
        expect(history.previous_status).to eq(AttendanceRecord.statuses[:absent])
        expect(history.new_status).to eq(AttendanceRecord.statuses[:on_leave])
        expect(history.actor_id).to eq(dept.id)   # 最終承認者
        expect(history.note).to eq("欠勤理由: 無届欠勤")
      end
    end
  end
```

> `leave` の `approval_status` 述語名は `LeaveRequest` の AASM 列名に合わせること（既存 spec の assert を確認して揃える）。

- [ ] **Step 3: テストが失敗することを確認**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb spec/requests/approval_assignments_spec.rb`
Expected: FAIL（W1: `history.note` が nil。W2 は 4-2c-1 の fix により大半通るが `history.note` の assert で落ちる = 判別性あり）

- [ ] **Step 4: `apply_approval.rb` を修正**

`upsert_attendance_records` を差し替え（`was_absent` の直後に理由を捕捉する — **クリア前**に読むこと）:

```ruby
    def upsert_attendance_records
      classifications = CompanyCalendarResolver.new(organization: @leave_request.organization)
                                               .day_classifications(@leave_request.start_date,
                                                                    @leave_request.end_date)
      LeaveDaysCalculator.counted_dates(classifications).each do |date|
        record = AttendanceRecord.find_or_initialize_by(
          user_id: @leave_request.requester_id, work_date: date
        )
        was_absent = record.absent? # §12② 遷移前 status を代入前に捕捉（silent no-op 回避）
        previous_absence_reason = record.absence_reason # W1 監査へ退避（クリア前に読む）
        record.status = leave_status
        record.leave_type_id = @leave_request.leave_type_id
        if was_absent
          record.absence_reason = nil # §11① 随伴列クリア（DB CHECK と整合）
          record.note = nil
        end
        record.save!
        # §12⑥ 監査（absent→on_leave の痕跡）。W1: 元の欠勤理由も残す
        record_absence_to_paid(record, date, previous_absence_reason) if was_absent
        recalculate(record)
      end
    end
```

`record_absence_to_paid` を差し替え、`absence_reason_note` を private に追加:

```ruby
    # absent→on_leave（事後有給）の監査（SPEC §6.2 L808・§12⑥）。actor 必須（4-2c-1）。
    # W1: AR.absence_reason は上書きでクリアされるため、元の理由を note へ焼いて証跡に残す
    # （労基法 109 条 5 年保存 — 「どの欠勤が有給へ振り替わったか」が previous_status だけでは追えない）
    def record_absence_to_paid(record, date, previous_absence_reason)
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id,
        actor: @acting_user,
        source: @leave_request,
        event_type: :absence_to_paid,
        event_date: date,
        previous_status: AttendanceRecord.statuses[:absent],
        new_status: AttendanceRecord.statuses[record.status],
        note: absence_reason_note(previous_absence_reason)
      )
    end

    def absence_reason_note(reason)
      return nil if reason.blank?

      "欠勤理由: #{I18n.t("activerecord.attributes.attendance_record.absence_reasons.#{reason}")}"
    end
```

- [ ] **Step 5: テストを通す**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb spec/requests/approval_assignments_spec.rb`
Expected: 全 PASS

- [ ] **Step 6: rubocop + Commit**

```bash
bundle exec rubocop --force-exclusion app/services/leave_requests/apply_approval.rb spec/services/leave_requests/apply_approval_spec.rb spec/requests/approval_assignments_spec.rb
git add app/services/leave_requests/apply_approval.rb spec/services/leave_requests/apply_approval_spec.rb spec/requests/approval_assignments_spec.rb
git commit -m "feat: absence_to_paid に元の欠勤理由を退避（W1）+ 実 approve path の統合テスト（W2）"
```

---

## Task 8: ドキュメント更新（SPEC / ROADMAP / RAILS_GOTCHAS / 社労士確認）

**Files:**
- Modify: `docs/SPEC.md`（§1.4 動線マップ・§6.10 制限・§9.1 通知）
- Modify: `docs/ROADMAP.md`（4-2 行・横断バックログ）
- Modify: `docs/LABOR_LAW_REVIEW_NOTES.md`（I1 の社労士確認）
- Modify: `docs/superpowers/specs/2026-06-28-phase4-2-daily-batch-design.md`（§12⑨⑩ の plan 判断を確定として追記）

**Interfaces:**
- Consumes: Task 1〜7 の実装結果。
- Produces: `/spec-check` が §1.4 の不変条件（`✅` 行は nav からクリック到達可）を満たす状態。

> `docs/SPEC.md` を編集すると `regen-spec-index` フックが冒頭のセクション索引（行番号表）を自動補正する。行番号のズレは気にせず本文だけ直すこと。

- [ ] **Step 1: SPEC §1.4 に動線行を追加**

`docs/SPEC.md` の §1.4 動線マップ表、「管理者 | 代理打刻したい」の行の直後に追加:

```markdown
| 管理者 | 欠勤候補を確認し欠勤確定したい | `/absence_confirmations` | ナビ「欠勤確定」 | AR(absent) 一括生成 + 本人通知 / 却下 | ✅ | §6.10 |
```

- [ ] **Step 2: SPEC §6.10 の制限を実装に合わせる**

`docs/SPEC.md:894` の「**制限:**」行を置換:

```markdown
**制限:**
- **締め済み月（`submitted` / `finalized`）**への欠勤確定は禁止（差戻し → 欠勤確定 → 再提出）。`deferred` 月は許可。判定は `MonthlySummaries::ClosingLock` を流用（`submitted` も遮断＝安全側）
- **本人未通知（`notified_on` が nil）の候補は確定不可**（弁明機会の担保・労基法 24 条）
- **猶予（`notified_on` の翌営業日 17:00）経過前は確定不可**。バックエンドで強制する
- **確定できるのは欠勤候補が実在する日付のみ**。候補は「AttendanceRecord も LeaveRequest（全 status）も無い稼働日」に生成されるため、**却下・撤回された休暇申請の日は候補が生まれず、v1 では欠勤確定できない**（実欠勤の追跡漏れを許容する仕様判断。候補ゲートを迂回する手動追加経路は設けない）
- 偽陽性の候補（非常勤・シフト勤務者の非所定日など）は管理者が**却下(dismiss)**して一覧から除く
```

- [ ] **Step 3: SPEC §9.1 に通知行を追加**

`docs/SPEC.md` の §9.1 社員向け通知の表、「月次差戻し」の直後に追加:

```markdown
| 欠勤確定 | 必須対応 | ベル + メール | 即時（確定操作後） |
```

- [ ] **Step 4: ROADMAP を更新**

`docs/ROADMAP.md` の 4-2 行（65 行目付近）の「4-2c-2 確定 UI 後続」を、完了記録に置換する。`— 4-2c-2 欠勤確定 UI ✅ PR #<番号>（Absences::Confirm＝5 ガード〔毒入力/候補不在/未通知/猶予前/締め済み〕・per-day savepoint 3 write・却下 dismiss・GlobalNav 動線・§12⑨⑩ を v1 仕様として確定・W1 監査退避 + W2 実 approve path 統合テスト同梱）` の形。

横断バックログに 2 行追加（末尾）:

```markdown
- [ ] **半休 LR が全日 absent を覆うと残り半日の欠勤が消える**（4-2c-1 レビュー I1）: `LeaveRequests::ApplyApproval` は `absent` 日に半休 LR が承認されると status を `morning_half` へ上書きし `absence_reason` をクリアする。AttendanceRecord は 1 日 1 行・status 単一のため「午前有給 + 午後欠勤」を表現できず、残り半日の欠勤が追跡から消える。正解（半日欠勤の表現）はデータモデル変更を要するため 4-2c-2 は現状挙動のまま出荷。**社労士確認**（LABOR_LAW_REVIEW_NOTES）の回答後にモデリングを判断
- [ ] **却下/撤回された休暇日の欠勤確定**（設計 §12⑨・v1 非対象として出荷）: 検知バッチは LR を全 status で「覆う」と扱うため、却下/撤回され打刻も無い日は欠勤候補が生成されず `absent` 化できない。候補ゲート（§11②「実在候補のみ確定」）を迂回する管理者手動追加経路は、過去日の確定捏造を防ぐ 2 層防御と正面から緊張するため v1 では設けない。実運用で追跡漏れが問題化したら再検討
```

- [ ] **Step 5: 社労士確認事項を追記**

`docs/LABOR_LAW_REVIEW_NOTES.md` の末尾（既存の番号体系に続けて）に追加:

```markdown
### #18 欠勤確定日への半休休暇の事後承認（4-2c-1 レビュー I1）

**状況**: 全日欠勤（`absent`・理由 illness 等）として確定した日に、後から**半日分**の有給休暇申請が承認されると、システムは当日を `morning_half`（または `afternoon_half`）へ上書きし欠勤理由を消す。残り半日は欠勤として追跡されない。

**確認したいこと**:
1. 実務上、「半日有給 + 半日欠勤」を勤怠記録として併記する必要があるか（賃金計算上、半日分の欠勤控除を要するか）
2. それとも「半休が承認された日は終日を欠勤扱いから外す」運用が一般的か
3. 併記が必要な場合、AttendanceRecord に「半日欠勤」の表現（status 追加 or 時間帯単位の欠勤列）を導入すべきか

**関連条文**: 労基法 24 条（賃金全額払い）/ 労基法 109 条（記録保存）
```

- [ ] **Step 6: 設計書に plan 判断の確定を追記**

`docs/superpowers/specs/2026-06-28-phase4-2-daily-batch-design.md` の §12⑨ と §12⑩ の「**plan 判断**」行の直後に、それぞれ追記:

§12⑨ に:
```markdown
- **plan 確定（2026-07-09・4-2c-2）**: **v1 非対象**。候補ゲート（§11②「実在候補のみ確定」）を厳守し、手動追加経路は設けない。SPEC §6.10 の「制限」に明記済み。
```

§12⑩ に:
```markdown
- **plan 確定（2026-07-09・4-2c-2）**: `MonthlySummaries::ClosingLock` を流用し **`submitted` も遮断**する（§5.2 の「finalized 禁止」より厳格・安全側）。SPEC §6.10 の「制限」を実装に合わせて改訂済み。
```

- [ ] **Step 7: Commit**

```bash
git add docs/SPEC.md docs/ROADMAP.md docs/LABOR_LAW_REVIEW_NOTES.md docs/superpowers/specs/2026-06-28-phase4-2-daily-batch-design.md docs/superpowers/plans/2026-07-09-phase4-2c-2-absence-confirmation-ui.md
git commit -m "docs: 4-2c-2 の SPEC 動線/制限/通知・ROADMAP・社労士確認 #18（半休×欠勤）を更新"
```

---

## 仕上げ（全タスク後）

1. **全スイート + 静的検証**:
   - `bundle exec rspec`（全緑・既存 pending は Approvals 自己承認 #2 のみ）
   - `bundle exec rubocop --force-exclusion $(git diff --name-only main...HEAD | grep '\.rb$')`
   - `bin/brakeman --no-pager`（app/ 変更ゆえ必須。`params[:user_id]` は `roster.find` へ渡すため mass-assignment 警告は出ない想定）
   - `/preflight`
2. **マージ前レビュアー**（`git diff main...HEAD --name-only` から都度導出・転記しない）:
   - `tenant-isolation-reviewer` — `app/models/attendance_record.rb` / `app/policies/*` / `Absences::Confirm` の `with_tenant` ラップ
   - `approval-engine-reviewer` — `app/services/leave_requests/apply_approval.rb`（承認副作用・W1）
   - `labor-law-compliance-reviewer` + `/legal-citation-audit` — 猶予期限の適正手続き・欠勤確定の賃金控除・通知文の remedy 正確性
3. **§1.4 到達性 DoD**: ログインして GlobalNav →「欠勤確定」→ 候補一覧 → 確定 → 本人にベル通知、が実際に一周することを手で確認する（`bin/rails s` + seed）。
4. **RAILS_GOTCHAS 還流**: 実装中に新しい罠を踏んだら本 PR に追記する。特に候補があるのは以下 —
   - 「per-day rescue の**手前**で毒入力を弾かないと、`rescue RecordInvalid` が 422 を skip に化けさせる」
   - 「HTML5 の `form` 属性で checkbox を外部 form に紐付ける（`button_to` の入れ子 form を避ける）」
   踏まなければ書かない（推測で台帳を膨らませない）。
5. **PR**: ROADMAP の 4-2 行更新を PR に含めてからマージ（1 スライス = 1 PR・squash）。

---

## Self-Review（writing-plans 規約）

**1. Spec coverage（§5 + §11 + §12 の binding を全数照合）**

| binding | 実装タスク |
|---|---|
| §5.1 controller/policy 構成 | Task 3・5 |
| §5.2 確定処理（AR + 候補 resolve + history N 件・通知集約） | Task 4・6 |
| §5.3 §1.4 動線 | Task 5（nav）・Task 8（SPEC 行） |
| §10② 権威源は候補・`policy_scope(User).find` | Task 4（guard_candidates_exist!）・Task 5（roster） |
| §10③ PORO/Service 分離（確定は `Absences::Confirm`） | Task 4 |
| §10⑤ 猶予のバックエンド強制 | Task 4（guard_grace_period!）・Task 1（next_business_day） |
| §11③ 通知文の remedy | Task 6 |
| §11④ dismiss 経路 | Task 5（destroy） |
| §11⑥ user/日付解決 + AR の同一組織検証 | Task 2・5 |
| §11⑦ per-day savepoint + 締め per-date ガード | Task 4 |
| §12① notified_on nil → 422（猶予計算より先） | Task 4（guard_notified!） |
| §12③ `policy_scope(User).find` は load-bearing・IDOR 2 variant | Task 5（request spec） |
| §12④ `create!` per-day・`insert_all` 禁止 | Task 4（confirm_one + コメント） |
| §12⑤ 3 write を 1 savepoint に | Task 4（confirm_one） |
| §12⑥ absence_to_paid writer（4-2c-1 で実装済）+ W1 note | Task 7 |
| §12⑦ 4-2b 事前通知 body 縮小 | Task 6 |
| §12⑧ dismiss 必須 + 注意喚起 + manager_id nil 負例 | Task 5 |
| §12⑨ plan 判断（v1 非対象） | Task 4（ガード）・Task 8（SPEC/設計書明記） |
| §12⑩ plan 判断（submitted も遮断） | Task 4（guard_closing!）・Task 8 |
| W1 / W2 / I1（4-2c-1 申し送り） | Task 7 / Task 7 / Task 8 |

**未カバーで意図的に外したもの**: §11⑨（`interval_violation_count` の live counter か Aggregate 派生か）は 4-2d の決定事項。§12⑨ の手動追加経路は J2 で v1 非対象と確定。

**2. Placeholder scan**: 全ステップに実コードを記載。`PR #<番号>` のみ後埋め（Task 8 Step 4 で明示）。`spec/requests/global_nav_spec.rb` と `spec/services/attendance_anomalies/detect_spec.rb` への追記は既存 `let` / `describe` 名への追従を明示的に指示（丸投げでなく「既存に合わせよ」の具体指示）。

**3. Type consistency**:
- `CompanyCalendarResolver#next_business_day(Date) → Date | nil`（Task 1）を `Absences::Confirm#grace_deadline` が `nil` チェック付きで消費（Task 4）— 一致。
- `Absences::Confirm.call(target_user:, dates:, candidates:, absence_reason:, note:, actor:)`（Task 4）を controller が同名キーワードで呼ぶ（Task 5・6）— 一致。
- `Result#confirmed_dates` / `#skipped_dates`（`Array<Date>`）を `confirm_notice` / `notify_confirmed` が消費（Task 6）— 一致。
- `AbsenceConfirmationPolicy::Scope`（over `User`）を `roster` が `policy_scope_class:` に渡す（Task 3 → 5）— 一致。
- `AbsenceCandidatePolicy::Scope`（over `AbsenceCandidate`）を `policy_scope(AbsenceCandidate)` が自動解決（Task 3 → 5）— 命名規約一致。
- `record_absence_to_paid(record, date, previous_absence_reason)` の 3 引数版（Task 7）は既存 2 引数版を置換。呼び出し側も同タスクで更新 — 一致。
- i18n キー `activerecord.attributes.attendance_record.absence_reasons.<key>` を Task 4（`reason_label`）・Task 5（view の `reason_options`）・Task 7（`absence_reason_note`）の 3 箇所が共有 — 一致。Task 4 Step 5 で先行追加する。

**4. 依存順**: Task 1（next_business_day）→ Task 2（AR 検証）→ Task 3（policy）→ Task 4（service・i18n 先行追加）→ Task 5（controller/view/nav）→ Task 6（通知）→ Task 7（W1/W2・独立だが i18n に依存）→ Task 8（docs）。Task 7 は Task 4 Step 5 の i18n に依存するため 4 より後であること。

**5. 判別性のあるテスト（positive 素通り防止）**:
- Task 2: `errors.details[:user]` に `:cross_tenant` を要求（`belongs_to` presence 由来のエラーと区別）
- Task 4: 毒入力 reason で `AttendanceRecord.count == 0` と候補 intact を両方 assert（ガードをループ後に置く実装だと候補が消えるので落ちる）
- Task 4: 猶予の連休吸収は「5/4 では拒否・5/6 で成功」の 2 方向（`next_business_day` を単純な `+1.day` にすると落ちる）
- Task 4: savepoint 例で「skip 日の候補が intact」を assert（savepoint を張らないと親 tx が毒され全滅する）
- Task 5: IDOR 2 variant を分離（Pundit 404 と acts_as_tenant 404）
- Task 6: 「確定 0 件なら通知しない」「通知失敗でも確定は残る」の 2 方向
- Task 7: `history.note` の内容一致（W1 の捕捉位置を `absence_reason = nil` の後に置くと nil になり落ちる＝capture-before-assign の二次罠を検出）
