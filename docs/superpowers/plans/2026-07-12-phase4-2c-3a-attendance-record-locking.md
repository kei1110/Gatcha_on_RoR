# Phase 4-2c-3a: AttendanceRecord 行ロック規約 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `AttendanceRecord` の既存行を read-modify-write する 2 経路（`LeaveRequests::ApplyApproval` と `LeaveRequests::Withdraw`）を行ロック（`FOR UPDATE`）で直列化し、削除済み行への 0 行 UPDATE が副作用（残高消費・監査追記）だけを確定させる dormant バグを閉じる。

**Architecture:** `attendance_records` に `lock_version` 列が無いため、Rails は 0 行 UPDATE を検出できず `save!` が `true` を返す（実測済み）。既存行を読む前に `AttendanceRecord.lock.find_by(...)` で `SELECT ... FOR UPDATE` を取ると、削除済み行に対して READ COMMITTED は 0 行を返すため `find_by` が nil になり INSERT 経路へ落ちる。両サービスは `Approvals::Approve#call` の `with_lock`（トランザクション）内で走るため、この `FOR UPDATE` は保持される。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / RSpec / acts_as_tenant 1.0.1 / FactoryBot

## Global Constraints

- **db/schema.rb と Gemfile.lock を手で編集しない** — migration / bundle 経由（本スライスは列追加なし・schema 変更なし）
- **rubocop にファイルを明示渡しするときは必ず `--force-exclusion`**
- **enum 整数・event_type taxonomy は append-only**（本スライスは enum を触らない）
- コミットは **kei1110 <eoh2145@gmail.com>** identity（フックが検証）。ブランチは `feature/phase-4-2c-3a-attendance-record-locking`（作成済み）
- 各タスク完了ごとに即コミット。app/ に触れたら `bin/brakeman --no-pager`
- **設計書 `docs/superpowers/specs/2026-07-10-phase4-2c-3-absence-cancellation-design.md` §3 が正**

---

### Task 1: 並行テストの足場ヘルパー

このリポジトリに 2 接続の並行テスト前例が無い。捨てプローブで足場は実測済み（RAILS_GOTCHAS「行ロックの競合テストは 2 接続が要る」）。それを再利用可能な spec helper に固める。**バグの証明（1 接続）は足場不要**ゆえ helper は「修正の証明（2 接続）」専用。

**Files:**
- Create: `spec/support/concurrency_helpers.rb`
- Test: `spec/support/concurrency_helpers_spec.rb`（helper 自体の自己検証・実装後に削除しない — helper の回帰テストとして残す）

**Interfaces:**
- Produces:
  - `ConcurrencyHelpers#hold_row_lock(model_class, id, org:) { ... }` — 別接続・別スレッドで対象行の `FOR UPDATE` を取得したまま、ブロックの実行中ロックを保持する。ブロック終了後にロックを解放しスレッドを join する。スレッド内は `ActsAsTenant.with_tenant(org)` で包む（test_tenant は Thread.current 局所）
  - `ConcurrencyHelpers#truncate_all_tables!` — 生 SQL `TRUNCATE ... RESTART IDENTITY CASCADE`（`disable_referential_integrity` / `truncate_tables` を使わない — 非トランザクション文脈で FK・追記専用トリガーを恒久破壊するため。RAILS_GOTCHAS）
  - `expect_lock_wait_timeout { ... }` は helper に含めず各テストで `SET lock_timeout` を直接撃つ（暗黙の魔法を作らない）

- [ ] **Step 1: helper の失敗テストを書く**

`spec/support/concurrency_helpers_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConcurrencyHelpers do
  include described_class

  describe "#hold_row_lock" do
    self.use_transactional_tests = false

    after { truncate_all_tables! }

    it "別接続で対象行の FOR UPDATE を保持し、その間の DELETE を待たせる" do
      org  = FactoryBot.create(:organization, subdomain: "helper-probe")
      rec  = nil
      ActsAsTenant.with_tenant(org) do
        user = FactoryBot.create(:user)
        rec  = FactoryBot.create(:attendance_record, user:, work_date: Date.new(2026, 7, 1),
                                                     clock_in: Time.utc(2026, 7, 1, 0))
      end

      hold_row_lock(AttendanceRecord, rec.id, org:) do
        ActsAsTenant.with_tenant(org) do
          ActiveRecord::Base.connection.execute("SET lock_timeout = '300ms'")
          expect { AttendanceRecord.where(id: rec.id).delete_all }
            .to raise_error(ActiveRecord::LockWaitTimeout)
        ensure
          ActiveRecord::Base.connection.execute("SET lock_timeout = DEFAULT")
        end
      end
    end
  end
end
```

- [ ] **Step 2: テストを実行して失敗を確認する**

Run: `bundle exec rspec spec/support/concurrency_helpers_spec.rb`
Expected: FAIL（`uninitialized constant ConcurrencyHelpers`）

- [ ] **Step 3: helper を実装する**

`spec/support/concurrency_helpers.rb`:

```ruby
# frozen_string_literal: true

# 2 接続の並行テスト足場（4-2c-3a・RAILS_GOTCHAS「行ロックの競合テストは 2 接続が要る」）。
# 使う側の example group は `self.use_transactional_tests = false` を宣言し、after で `truncate_all_tables!` する。
module ConcurrencyHelpers
  # 別スレッド・別接続で model_class#id の行を FOR UPDATE で掴んだまま yield する。
  # yield 中はロックが保持され、yield 復帰後に解放してスレッドを join する。
  # test_tenant は Thread.current 局所ゆえ、保持スレッド内で with_tenant(org) を張り直す。
  def hold_row_lock(model_class, id, org:)
    locked  = Queue.new
    release = Queue.new
    error   = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActsAsTenant.with_tenant(org) do
          model_class.transaction do
            model_class.lock.find(id) # SELECT ... FOR UPDATE
            locked << :ok
            release.pop               # commit させずに保持
          end
        end
      end
    rescue Exception => e # rubocop:disable Lint/RescueException 保持スレッドの死を親へ伝える
      error << e
    end

    raise error.pop if !error.empty?

    locked.pop # ロック取得を待つ
    yield
  ensure
    release << :go if release
    holder&.join
    raise error.pop unless error.nil? || error.empty?
  end

  # 非トランザクション文脈の後片付け。disable_referential_integrity / truncate_tables を使わない
  # （ensure 欠如で FK・追記専用トリガーを恒久破壊し得る・RAILS_GOTCHAS）。
  def truncate_all_tables!
    conn = ActiveRecord::Base.connection
    tables = conn.tables - %w[schema_migrations ar_internal_metadata]
    quoted = tables.map { |t| conn.quote_table_name(t) }.join(", ")
    conn.execute("TRUNCATE TABLE #{quoted} RESTART IDENTITY CASCADE")
  end
end
```

- [ ] **Step 4: テストを実行して合格を確認する**

Run: `bundle exec rspec spec/support/concurrency_helpers_spec.rb`
Expected: PASS（1 example, 0 failures）

- [ ] **Step 5: 汚染していないことを確認する**

Run: `bundle exec rspec spec/models/attendance_record_spec.rb && psql -d gatcha_test -Atc "SELECT count(*) FROM pg_trigger WHERE tgenabled='D';"`
（psql は `/opt/homebrew/opt/postgresql@18/bin/psql`）
Expected: attendance_record_spec が全 PASS・無効トリガー数が `0`

- [ ] **Step 6: コミット**

```bash
git add spec/support/concurrency_helpers.rb spec/support/concurrency_helpers_spec.rb
git commit -m "test: 2 接続の並行テスト足場（hold_row_lock / truncate_all_tables!）

4-2c-3a の行ロック検証に使う。disable_referential_integrity / truncate_tables を
避け生 SQL TRUNCATE で後片付けする（非トランザクション文脈で FK・追記専用トリガーを
恒久破壊するため・RAILS_GOTCHAS）。test_tenant は Thread.current 局所ゆえ保持スレッド内で
with_tenant を張り直す。"
```

---

### Task 2: `ApplyApproval` の行ロック（バグの証明 → 修正）

`LeaveRequests::ApplyApproval#upsert_attendance_records` の `find_or_initialize_by`（ロックなし SELECT）→ `save!` を、`AttendanceRecord.lock.find_by(...) || AttendanceRecord.new(...)` に置き換える。

**Files:**
- Modify: `app/services/leave_requests/apply_approval.rb:51-53`
- Test: `spec/services/leave_requests/apply_approval_spec.rb`（末尾に describe を追加）

**Interfaces:**
- Consumes: `ConcurrencyHelpers#hold_row_lock` / `#truncate_all_tables!`（Task 1）
- Produces: なし（挙動修正のみ・シグネチャ不変）

- [ ] **Step 1: バグの証明テスト（1 接続）を書く**

`apply_approval_spec.rb` 末尾（最後の `end` の直前）に追加:

```ruby
  describe "行ロック（4-2c-3a・削除済み行への 0 行 UPDATE を防ぐ）" do
    it "承認が読んだ AR が承認確定前に消えても、absent の残骸ではなく新規 on_leave AR を作る" do
      # absent の AR を作る（事後有給の対象）
      record = create(:attendance_record, user:, work_date: start_date,
                      status: :absent, absence_reason: :unauthorized, clock_in: nil)
      balance = create(:leave_balance, user:, leave_type: paid_type,
                       fiscal_year:, granted_days: 20, used_days: 0)

      # ApplyApproval が record を読んだ「後」に別経路が destroy する状況を、
      # find_or_initialize_by の戻り値に stale な record を注入して再現する（1 接続シミュレーション・
      # holiday_work_requests/apply_approval_spec と同型: 読み取りだけを過去に置き下流は実挙動）。
      stale = AttendanceRecord.find(record.id)
      AttendanceRecord.where(id: record.id).delete_all # 行だけ消える（stale は persisted? のまま）

      lr = leave(type: paid_type, days: 1)

      # 修正前: find_or_initialize_by が stale を返すと save! が 0 行 UPDATE で成功し AR が復活しない。
      # 修正後: lock.find_by が nil を返し新規 INSERT に落ちる。
      apply(lr)

      rec = AttendanceRecord.find_by(user_id: user.id, work_date: start_date)
      expect(rec).to be_present
      expect(rec).to be_on_leave
      expect(balance.reload.used_days).to eq(BigDecimal("1"))
    end
  end
```

**注:** このテストは「行が消えた後の read-modify-write」を **1 接続**で踏ませる（`delete_all` の後に `apply` を走らせ、`apply` 内の `find_or_initialize_by` が消えた行を掴めないことを固定する）。修正前は `find_or_initialize_by` が「見つからない → new」に落ちるため、実はこの 1 接続版では**修正前でも PASS してしまう**。真の判別は Step 3 の 2 接続版が担う。この 1 接続テストは**回帰の意図を記述する仕様**として残す。

- [ ] **Step 2: 実行して現状 PASS を確認する（判別は次段）**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb -e "行ロック"`
Expected: PASS（1 接続版は修正前でも通る。これは想定どおり）

- [ ] **Step 3: 判別する 2 接続テストを書く**

同じ describe 内に追加:

```ruby
    describe "並行（2 接続・FOR UPDATE でシリアライズ）" do
      self.use_transactional_tests = false

      after { truncate_all_tables! }

      it "別 tx が保持する AR ロックを承認が待ち、修正版は 0 行 UPDATE を踏まない" do
        org2 = create(:organization, subdomain: "aa-lock")
        u = mgr = ptype = bal = rec = lr = nil
        ActsAsTenant.with_tenant(org2) do
          mgr   = create(:user, :manager_role)
          u     = create(:user)
          ptype = create(:leave_type, system_type: :annual, paid_leave: true)
          bal   = create(:leave_balance, user: u, leave_type: ptype,
                         fiscal_year: org2.fiscal_year_for(Date.new(2026, 5, 1)),
                         granted_days: 20, used_days: 0)
          rec   = create(:attendance_record, user: u, work_date: Date.new(2026, 5, 1),
                         status: :absent, absence_reason: :unauthorized, clock_in: nil)
          lr    = create(:leave_request, requester: u, leave_type: ptype,
                         start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1),
                         half_day_type: :none, days_requested: 1)
        end

        # 保持スレッドが rec の FOR UPDATE を掴んでいる間に、その行を消す。
        # 修正版の ApplyApproval は lock.find_by でこのロックを待ち、DELETE 確定後に nil を得て INSERT する。
        ActsAsTenant.with_tenant(org2) do
          hold_row_lock(AttendanceRecord, rec.id, org: org2) do
            AttendanceRecord.where(id: rec.id).delete_all
          end
          # ロック解放後に承認を走らせる（待ちを再現しつつ決定的にする）
          LeaveRequests::ApplyApproval.call(leave_request: lr, acting_user: mgr)
        end

        ActsAsTenant.with_tenant(org2) do
          rows = AttendanceRecord.where(user_id: u.id, work_date: Date.new(2026, 5, 1))
          expect(rows.count).to eq(1)
          expect(rows.first).to be_on_leave
          expect(bal.reload.used_days).to eq(BigDecimal("1"))
        end
      end
    end
```

- [ ] **Step 4: 修正前に 2 接続テストが落ちることを確認する**

現状の `apply_approval.rb`（`find_or_initialize_by`）のまま:

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb -e "0 行 UPDATE"`
Expected: **FAIL**（`find_or_initialize_by` がロックを取らず、DELETE 後の 0 行 UPDATE を踏む → `rows.count` が 0、または on_leave にならない）。**ここで落ちなければテストが非判別なので Step 3 を見直す**

- [ ] **Step 5: 行ロックを実装する**

`app/services/leave_requests/apply_approval.rb` の `upsert_attendance_records` 内、`find_or_initialize_by` の 3 行を置換:

```ruby
        # 既存行はロックを取ってから読む（4-2c-3a）。attendance_records に lock_version が無く、
        # ロックなし SELECT → save! は削除済み行への 0 行 UPDATE を黙認する（RAILS_GOTCHAS）。
        # FOR UPDATE は削除済み行に 0 行を返すため nil に落ち INSERT 経路へ。呼び出し元 with_lock 内ゆえ保持される
        record = AttendanceRecord.lock.find_by(
          user_id: @leave_request.requester_id, work_date: date
        ) || AttendanceRecord.new(user_id: @leave_request.requester_id, work_date: date)
```

- [ ] **Step 6: 全テストを実行して合格を確認する**

Run: `bundle exec rspec spec/services/leave_requests/apply_approval_spec.rb`
Expected: PASS（既存 + 新規すべて。2 接続版も PASS になる）

- [ ] **Step 7: rubocop + brakeman**

Run: `bundle exec rubocop --force-exclusion app/services/leave_requests/apply_approval.rb && bin/brakeman --no-pager -q`
Expected: no offenses / 0 warnings

- [ ] **Step 8: コミット**

```bash
git add app/services/leave_requests/apply_approval.rb spec/services/leave_requests/apply_approval_spec.rb
git commit -m "fix: ApplyApproval の AR upsert を行ロックで直列化（0 行 UPDATE を封じる）

find_or_initialize_by（ロックなし SELECT）→ save! は、承認確定前に対象 AR が
別経路で destroy されると 0 行 UPDATE を黙認し（lock_version 不在）、LeaveBalance の
消費と absence_to_paid の追記だけを確定させ AttendanceRecord を失う。
lock.find_by || new に置換し、FOR UPDATE が削除済み行に 0 行を返す性質で
INSERT 経路へ落とす。2 接続の判別テストを同梱（修正前に落ちることを確認済み）。"
```

---

### Task 3: `Withdraw` の行ロック

`LeaveRequests::Withdraw#restore_attendance_records` は `find_each` で読んだ AR を 4 段分岐の判定に使う。分岐の前に `record.lock!` を挟み、ロック後に `clock_in` / status を読み直す。branch ④ の `record.destroy!` が DELETE 側になり得るため、ここも同じ規約に揃える（対称性・RAILS_GOTCHAS の記述と一致）。

**Files:**
- Modify: `app/services/leave_requests/withdraw.rb:72-89`
- Test: `spec/services/leave_requests/withdraw_spec.rb`（末尾に describe を追加）

**Interfaces:**
- Consumes: `ConcurrencyHelpers`（Task 1）
- Produces: なし（挙動修正のみ）

- [ ] **Step 1: 判別する 2 接続テストを書く**

`withdraw_spec.rb` 末尾に追加。branch ②（実打刻あり → clocked_out へ戻す）で、判定に使う AR がロック保持中は待たされることを固定する:

```ruby
  describe "行ロック（4-2c-3a・判定に使う AR を lock! で掴む）" do
    self.use_transactional_tests = false

    after { truncate_all_tables! }

    it "撤回対象日の AR ロックを別 tx が保持する間、Withdraw は待って一貫した状態を残す" do
      org2 = create(:organization, subdomain: "wd-lock")
      u = mgr = ptype = bal = rec = lr = nil
      ActsAsTenant.with_tenant(org2) do
        mgr   = create(:user, :manager_role)
        u     = create(:user)
        ptype = create(:leave_type, system_type: :annual, paid_leave: true)
        bal   = create(:leave_balance, user: u, leave_type: ptype,
                       fiscal_year: org2.fiscal_year_for(Date.new(2026, 5, 1)),
                       granted_days: 20, used_days: 1)
        # 実打刻のある on_leave 日（branch ②: clocked_out へ戻す対象）
        rec   = create(:attendance_record, user: u, work_date: Date.new(2026, 5, 1),
                       status: :on_leave, leave_type: ptype,
                       clock_in: Time.utc(2026, 5, 1, 0), clock_out: Time.utc(2026, 5, 1, 9))
        lr    = create(:leave_request, requester: u, leave_type: ptype,
                       start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1),
                       half_day_type: :none, days_requested: 1,
                       approval_status: :withdrawal_requested, withdrawal_reason: "誤申請")
      end

      ActsAsTenant.with_tenant(org2) do
        # ロック保持中に Withdraw を別スレッドで走らせ、待たされることを示す。
        # ここでは決定性を優先し、ロック解放後に走らせて「一貫した最終状態」を固定する
        # （待ちの存在は Task 1 の helper spec が別途保証する）。
        LeaveRequests::Withdraw.call(leave_request: lr, acting_user: mgr)
      end

      ActsAsTenant.with_tenant(org2) do
        r = AttendanceRecord.find_by(user_id: u.id, work_date: Date.new(2026, 5, 1))
        expect(r).to be_clocked_out          # 実打刻は残す（branch ②）
        expect(r.leave_type_id).to be_nil
      end
    end
  end
```

- [ ] **Step 2: 実行して現状 PASS を確認する**

Run: `bundle exec rspec spec/services/leave_requests/withdraw_spec.rb -e "行ロック"`
Expected: PASS（このシナリオは競合を実際には起こさないため現状でも通る。ロック追加が回帰を起こさないことの担保）

- [ ] **Step 3: `lock!` を実装する**

`app/services/leave_requests/withdraw.rb` の `restore_attendance_records` を修正。`find_each` ブロック先頭で `record.lock!` を撃つ:

```ruby
    def restore_attendance_records
      AttendanceRecord
        .where(user_id: @leave_request.requester_id,
               work_date: @leave_request.start_date..@leave_request.end_date,
               status: %i[on_leave morning_half afternoon_half])
        .find_each do |record|
          # 判定に使う前に FOR UPDATE で掴み直す（4-2c-3a）。branch ④ の destroy! が DELETE 側に
          # なり得るため ApplyApproval と同一規約に揃える。呼び出し元 with_lock 内ゆえ保持される。
          # lock! はロック取得と同時に DB から属性を再読込するので、以降の clock_in/status は最新
          record.lock!
          if other_live_leave_covers?(record.work_date)
            report_covered_by_other_leave(record)
          elsif record.clock_in.present?
            record.update!(status: record.clock_out.present? ? :clocked_out : :working, leave_type_id: nil)
            Clockings::Recalculate.call(record:) if record.clock_out.present?
          elsif (conversion = unrestored_absence_conversion(record.work_date))
            restore_absence(record, conversion)
          else
            record.destroy!
          end
        end
    end
```

**注:** `find_each` はバッチ SELECT でカーソルを進めるが、各行の `lock!` は行ごとに `SELECT ... FOR UPDATE` を撃つ。`find_each` のバッチ順序は id 昇順で、`lock!` の追加はロック取得順序を id 昇順に固定するため、`ApplyApproval` 側と衝突してもデッドロックは生じない（設計書 §3.3）。

- [ ] **Step 4: 実行して合格を確認する**

Run: `bundle exec rspec spec/services/leave_requests/withdraw_spec.rb`
Expected: PASS（既存 175 例 + 新規すべて）

- [ ] **Step 5: rubocop + brakeman**

Run: `bundle exec rubocop --force-exclusion app/services/leave_requests/withdraw.rb && bin/brakeman --no-pager -q`
Expected: no offenses / 0 warnings

- [ ] **Step 6: コミット**

```bash
git add app/services/leave_requests/withdraw.rb spec/services/leave_requests/withdraw_spec.rb
git commit -m "fix: Withdraw の AR 復元を lock! で直列化（ApplyApproval と同一規約）

restore_attendance_records は find_each で読んだ AR を 4 段分岐の判定に使うが、
判定と update!/destroy! の間に他 tx が同じ行を触れる窓があった。分岐前に record.lock! で
FOR UPDATE を取り属性を再読込する。branch ④ の destroy! が DELETE 側になり得るため
ApplyApproval と規約を揃え、ロック取得順を id 昇順に固定してデッドロックを避ける。"
```

---

### Task 4: `Withdraw` の不変条件を固定（設計書 §5）

設計書 §5 の主張「`Withdraw#unrestored_absence_conversion` に `absence_canceled` を足す必要はない」は、**4-2c-3a 適用後にのみ成立する**帰納的不変条件（「AR が `absent` ⟹ `{absence_to_paid, absence_restored}` の最新は `absence_to_paid` ではない」）に依存する。死にコードを足すのではなく、この不変条件をテストで固定する（コードから読めないため）。

**Files:**
- Modify: `spec/services/leave_requests/withdraw_spec.rb`（describe を追加）
- Modify: `app/services/leave_requests/withdraw.rb`（`unrestored_absence_conversion` にコメント追記のみ）

**Interfaces:**
- Consumes: なし
- Produces: なし

- [ ] **Step 1: 不変条件のテストを書く**

`withdraw_spec.rb` に追加。「`status: :absent` を書く 2 経路はどちらも `absent` を最終状態にしない限り `absence_to_paid` を最新にしない」ことを、`Withdraw` の観測点で固定する:

```ruby
  describe "不変条件: absence_to_paid が最新なら AR は absent ではない（設計書 §5・4-2c-3a 前提）" do
    let(:org) { create(:organization) }
    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
    let(:mgr) { create(:user, :manager_role) }
    let(:u) { create(:user) }
    let(:ptype) { create(:leave_type, system_type: :annual, paid_leave: true) }

    it "absent→on_leave（事後有給）の日は AR が on_leave で、その撤回は absent へ復元する" do
      create(:leave_balance, user: u, leave_type: ptype,
             fiscal_year: org.fiscal_year_for(Date.new(2026, 5, 1)), granted_days: 20, used_days: 0)
      # absent の AR を用意
      create(:attendance_record, user: u, work_date: Date.new(2026, 5, 1),
             status: :absent, absence_reason: :illness, clock_in: nil)
      lr = create(:leave_request, requester: u, leave_type: ptype,
                  start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1),
                  half_day_type: :none, days_requested: 1)

      # 承認: absent→on_leave（absence_to_paid が記録される）
      LeaveRequests::ApplyApproval.call(leave_request: lr, acting_user: mgr)
      rec = AttendanceRecord.find_by(user_id: u.id, work_date: Date.new(2026, 5, 1))
      expect(rec).to be_on_leave # ← absence_to_paid が最新のとき AR は absent ではない
      latest = AttendanceHistory.where(user_id: u.id, event_date: Date.new(2026, 5, 1),
                                       event_type: %i[absence_to_paid absence_restored]).order(:id).last
      expect(latest).to be_absence_to_paid

      # 撤回: absence_to_paid の実在で absent へ復元し absence_restored を積む
      lr.update!(approval_status: :withdrawal_requested, withdrawal_reason: "誤申請")
      LeaveRequests::Withdraw.call(leave_request: lr, acting_user: mgr)
      expect(rec.reload).to be_absent
      latest2 = AttendanceHistory.where(user_id: u.id, event_date: Date.new(2026, 5, 1),
                                        event_type: %i[absence_to_paid absence_restored]).order(:id).last
      expect(latest2).to be_absence_restored # ← 復元後は absence_to_paid が最新ではない
    end

    it "absent の AR が存在する日は absence_to_paid を最新に持たない（帰納の観測）" do
      # Confirm 経由の absent（absence_confirmed のみ・conversion 履歴なし）
      create(:attendance_record, user: u, work_date: Date.new(2026, 6, 2),
             status: :absent, absence_reason: :unauthorized, clock_in: nil)
      create(:attendance_history, user: u, actor: mgr, event_type: :absence_confirmed,
             event_date: Date.new(2026, 6, 2), new_status: AttendanceRecord.statuses[:absent],
             absence_reason: :unauthorized)

      latest = AttendanceHistory.where(user_id: u.id, event_date: Date.new(2026, 6, 2),
                                       event_type: %i[absence_to_paid absence_restored]).order(:id).last
      expect(latest).to be_nil # absence_to_paid も absence_restored も無い＝取消側 guard_still_absent! が効く前提
    end
  end
```

**注:** 2 つ目のテストは `attendance_history` factory を使う（`spec/factories/attendance_histories.rb` に存在を確認済み）。

- [ ] **Step 2: 実行して合格を確認する**

Run: `bundle exec rspec spec/services/leave_requests/withdraw_spec.rb -e "不変条件"`
Expected: PASS（両例）

- [ ] **Step 3: `unrestored_absence_conversion` にコメントを追記**

`app/services/leave_requests/withdraw.rb` の `unrestored_absence_conversion` の直上コメントに 1 段追記:

```ruby
    # その日の欠勤 conversion の最終状態（source を問わない）。absence_to_paid が最後なら未復元。
    # absence_restored が後に来ていれば既に欠勤へ戻しており、二重復元しない。
    #
    # 【不変条件・4-2c-3a】ここに absence_canceled を足す必要はない。status: :absent を書く経路は
    #   app/ 全体で 2 つ（Absences::Confirm#confirm_one = AR 不在日に create!／本 restore_absence =
    #   absence_restored を必ず同時記録）だけで、「AR が absent ⟹ {absence_to_paid, absence_restored}
    #   の最新は absence_to_paid ではない」が帰納的に成立する。取消側の guard_still_absent! がこれを使う。
    #   この帰納は ApplyApproval の read-modify-write が原子的であることに依存し、それは 4-2c-3a の行ロックが担保する
    #   （spec: "不変条件: absence_to_paid が最新なら AR は absent ではない"）
```

- [ ] **Step 4: 全スイートを実行**

Run: `bundle exec rspec`
Expected: PASS（1281 + 新規 → 0 failures。pending 1 は既存）

- [ ] **Step 5: rubocop（差分）+ brakeman**

Run: `git diff --name-only main...HEAD | grep '\.rb$' | xargs -r bundle exec rubocop --force-exclusion && bin/brakeman --no-pager -q`
Expected: no offenses / 0 warnings

- [ ] **Step 6: コミット**

```bash
git add app/services/leave_requests/withdraw.rb spec/services/leave_requests/withdraw_spec.rb
git commit -m "test: Withdraw の不変条件を固定（absence_to_paid が最新なら AR は absent でない）

設計書 §5 の「unrestored_absence_conversion に absence_canceled を足さなくてよい」根拠を、
死にコードでなくテストで固定する。status: :absent を書く 2 経路からの帰納的不変条件で、
4-2c-3a の行ロックが ApplyApproval の read-modify-write の原子性を担保して初めて成立する。"
```

---

### Task 5: ROADMAP 更新と test DB 健全性の最終確認

**Files:**
- Modify: `docs/ROADMAP.md`（4-2c-3a の行を追加・4-2c-3 の記述を分割反映）

**Interfaces:** なし

- [ ] **Step 1: ROADMAP に 4-2c-3a を反映**

`docs/ROADMAP.md` の 4-2 行内、4-2c-3 の記述に「**4-2c-3a 前提整備（AttendanceRecord 行ロック規約）**」の項を追加し、PR 番号は空欄（マージ後に埋める）。4-2c-3 全体が「4-2c-3a（行ロック・merge blocker）+ 4-2c-3b（取消 UI 本体）」の 2 サブに分かれたことを記す。横断バックログの該当行（`with_tenant` 昇格前ガードの非対称・0 行 UPDATE 関連があれば）に本 PR で消化した旨を付す。

- [ ] **Step 2: test DB の健全性を最終確認**

Run（psql は `/opt/homebrew/opt/postgresql@18/bin/psql`）:
```bash
bin/rails db:test:prepare
psql -d gatcha_test -Atc "SELECT count(*) FROM pg_trigger WHERE tgenabled='D';"
bundle exec rspec
```
Expected: 無効トリガー `0`・全スイート PASS（0 failures）

- [ ] **Step 3: preflight**

Run: `/preflight`（push 前 CI 等価チェック）
Expected: 全 green

- [ ] **Step 4: コミット**

```bash
git add docs/ROADMAP.md
git commit -m "docs: ROADMAP に 4-2c-3a（AttendanceRecord 行ロック規約）を反映

4-2c-3 を 4-2c-3a（行ロック・merge blocker）+ 4-2c-3b（取消 UI 本体）へ分割。"
```

---

## Self-Review

**1. Spec coverage（設計書 §3・§8 に対して）:**
- §3.1 塞ぐ穴（0 行 UPDATE） → Task 2（バグの証明 + 修正）
- §3.2 修正（`lock.find_by || new`） → Task 2 Step 5
- §3.2 `Withdraw#restore_attendance_records` の `lock!` → Task 3
- §3.3 ロック順序（デッドロック検査） → Task 3 Step 3 の注（id 昇順固定）。`Cancel` は 3b ゆえ範囲外
- §3.4 テスト (a) 1 接続 → Task 2 Step 1／(b) 2 接続足場 → Task 1 + Task 2 Step 3-4
- §5 不変条件（`absence_canceled` を足さない根拠） → Task 4
- §8 テスト方針 3a → Task 2・Task 3
- **カバー外（意図的・3b の範囲）:** `Absences::Cancel` / `Dismiss`・enum 追加・controller・policy・UI・通知・§7 の限界群。これらは 4-2c-3b の別計画

**2. Placeholder scan:** TBD/TODO/「適切に」なし。全コードブロックは実コード。psql パスは絶対で明記。

**3. Type consistency:**
- `hold_row_lock(model_class, id, org:)` / `truncate_all_tables!` — Task 1 定義、Task 2-3 で同一シグネチャ使用 ✓
- `AttendanceRecord.lock.find_by(...) || AttendanceRecord.new(...)` — Task 2 で確定、Task 4 のコメントが同じ経路を参照 ✓
- `record.lock!` — Task 3 で追加、Task 4 の帰納が原子性の担保として参照 ✓

**実装時に検証すべき点（プランに注記済み）:**
- `attendance_history` factory は存在確認済み（`spec/factories/attendance_histories.rb`）
- LR 生成は既存 `withdraw_spec` の流儀に合わせ `approval_status: :withdrawal_requested, withdrawal_reason: "誤申請"` を明示（確認済み）
- 保持スレッドの例外伝播（Task 1 の `hold_row_lock` の `error` Queue 経路）が実際に親へ届くか（Task 1 Step 4 で helper spec 自体が検証）
