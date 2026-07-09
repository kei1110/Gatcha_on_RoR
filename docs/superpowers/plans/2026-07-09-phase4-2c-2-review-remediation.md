# Phase 4-2c-2 レビュー是正（第 2 波）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 4-2c-2（欠勤確定 UI）のマージ前レビューで 3 レビュアーが検出した **Critical 2 件 + 構造的 Warning 群**を是正し、MERGE 可の状態にする。

**Architecture:** ① 監査証跡を「ローカライズ済みラベル」から「enum 整数 + 自由記述」の構造化保存へ移し、それを土台に `LeaveRequests::Withdraw` の欠勤復元を実装する ② `Absences::Confirm` のガード列に「操作者の組織」「弁明の行使（covering LR/AR）」を足し、締めガードを tx 内へ移し、rescue を真の競合のみに絞る ③ 猶予期限の定義を `Absences::GracePeriod` に一元化し、確定ガード・事前通知本文・確定 UI が同じ値を共有する。

**Tech Stack:** Rails 8.1 / PostgreSQL 18 / acts_as_tenant / Pundit / RSpec。

**前提:** 第 1 波（Task 1〜8・commit `0035082` まで）は実装済み。本計画はその上に積む。`websocket-driver` の脆弱性は独立 chore PR（#36）で処理済み。

---

## レビュー指摘の対応表（3 レビュアー × 本計画のタスク）

| 指摘 | 出所 | 対応 |
|---|---|---|
| **C1** `ja.yml` に `absent` ラベルが無く給与 CSV に `Translation missing` | labor-law | **R1** |
| **C1** 事後有給の撤回が元 absent の AR を `destroy!`（欠勤が台帳から消滅） | approval-engine | **R2** |
| W1 監査 note がローカライズ済みラベルで機械復元不能 / `other` の自由記述が消える | approval-engine・labor-law | **R2** |
| I3 `absence_reason_note` の `I18n.t` が実行時 locale 依存 | tenant・labor-law | **R2**（構造化で解消） |
| W2 `Absences::Confirm` に actor↔target の同一組織ガードが無い | tenant-isolation | **R3** |
| W1/W3 `rescue RecordInvalid` が本物の検証失敗を「skip 日」に握り潰す | tenant・approval-engine | **R3** |
| W2 `guard_closing!` が tx 外で評価される（判定と write の間に締めが commit し得る） | approval-engine | **R3** |
| W4 猶予中に提出された休暇申請（＝弁明の行使）を無視して確定できる | labor-law | **R3** |
| W1 事前通知が `informational`（確定通知より到達性が低い） | labor-law | **R4** |
| W2 事前通知本文に具体期限日と処分予告が無い | labor-law | **R4** |
| W8 確定 UI に猶予期限が現れない | labor-law | **R4** |
| I2/I6 `guard_grace_period!` の N+1（候補ごとに 30 日レンジクエリ） | tenant・approval-engine | **R4**（メモ化） |
| W3 policy spec の「他テナントは見えない」が空虚（default_scope だけで緑） | tenant-isolation | **R5** |
| I1 `destroy`（却下）に他テナント IDOR variant が無い | tenant-isolation | **R5** |
| W3 SPEC §6.8 が実装に追従していない | labor-law | **R6** |
| W4 hr_admin の自己却下が監査ゼロ / W6 実労働判明時の是正経路なし / W7 `investigating` | approval-engine・labor-law | **R6**（backlog + 社労士確認） |

---

## Global Constraints（binding・全タスクに適用）

**この是正で守るべき不変条件:**

- **`ActsAsTenant.with_tenant(信頼できない record.organization)` はテナント境界ではなく昇格プリミティブ**。他テナントの `target_user` を渡すと文脈がその org へ切り替わり、内側で作られる `AttendanceRecord` は `organization_id` も `user_id` も侵入先 org のもので**整合してしまう**（複合 FK も `user_must_belong_to_same_organization` も通過する）。ゆえに `guard_actor_same_organization!` は **`with_tenant` へ入る前**に評価すること。
- **`AttendanceRecord` には同日 uniqueness のモデル検証が意図的に置かれていない**（`attendance_record.rb` のコメントが明言・一次防衛は unique index）。したがって `confirm_one` の並行打刻レースは**必ず `RecordNotUnique`** で来る。`RecordInvalid` はこの savepoint 内では「本物の検証失敗」しか意味しない — **skip 日として握り潰さず、ログして再 raise する**。
- **監査（`AttendanceHistory`）に翻訳結果を焼かない**。理由は enum 整数（`absence_reason` 列）で構造化し、ラベルは読む時に i18n で解決する。`note` は `other` の自由記述専用。
- **`event_type` enum は append-only**（鉄則 7）。`absence_restored: 10` を末尾に追加するのみ。既存 0〜9 のリオーダ・再利用は禁止。
- **`db/schema.rb` と `Gemfile.lock` を手で編集しない**。migration / bundle 経由（`block-schema-edit` フック）。
- **`rubocop` にファイルを明示渡しするときは必ず `--force-exclusion`**。**zsh では `cmd $FILES` が単語分割されない** — `git diff --name-only | xargs bundle exec rubocop --force-exclusion` を使う（`rubocop` は存在しないパスを黙って無視し「0 files inspected, no offenses」と**緑を返す**）。
- **`LeaveRequests::Withdraw` / `ApplyApproval` は内側で rescue しない設計**（例外は `Approvals::Approve` の `with_lock` を伝播し承認ごと atomic に rollback）。この性質を変えない。
- **capture-before-assign**: status を代入する前に旧 status・随伴列を捕捉する（`docs/RAILS_GOTCHAS.md`「enum の排他検証 × 遷移随伴列クリア漏れ」）。

**マージ前レビュアー（再実行）:** `tenant-isolation-reviewer` / `approval-engine-reviewer`（`ApplyApproval`・`Withdraw` に触れる）/ `labor-law-compliance-reviewer`。仕上げに `/preflight`・`bundle exec rspec`・`bin/brakeman --no-pager`。

---

## File Structure

| ファイル | 責務 | タスク |
|----------|------|--------|
| `config/locales/ja.yml`（変更） | `statuses.absent` ラベル追加 | R1 |
| `db/migrate/*_add_absence_reason_to_attendance_histories.rb` | 監査の構造化列 | R2 |
| `app/models/attendance_history.rb`（変更） | `absence_restored` event_type / `absence_reason` enum / actor 必須 | R2 |
| `app/models/attendance_record.rb`（変更） | `.absence_reason_note` を削除（構造化で不要に） | R2 |
| `app/services/absences/confirm.rb`（変更） | 履歴 payload の構造化・ガード追加・rescue 絞り込み・tx 内締め判定 | R2・R3 |
| `app/services/leave_requests/apply_approval.rb`（変更） | `absence_to_paid` に構造化理由 + 自由記述を退避 | R2 |
| `app/services/leave_requests/withdraw.rb`（変更） | absent 復元 + `absence_restored` 監査 | R2 |
| `app/services/absences/grace_period.rb`（新規） | 猶予期限の単一定義（ガード・通知・UI が共有） | R4 |
| `app/services/attendance_anomalies/detect.rb`（変更） | 事前通知の priority 格上げ + 本文（具体期限日 + 処分予告） | R4 |
| `app/controllers/absence_confirmations_controller.rb`（変更） | `RecordInvalid` → 422 / 猶予期限を view へ | R3・R4 |
| `app/views/absence_confirmations/index.html.erb`（変更） | 猶予期限の表示・未経過は選択不可 | R4 |
| `docs/*`（変更） | SPEC §4.14/§6.8/§6.10/§9.1・ROADMAP・社労士確認・RAILS_GOTCHAS | R6 |

---

## Task R1: 給与 CSV の `absent` ラベル欠落（labor-law Critical）

**Files:**
- Modify: `config/locales/ja.yml`
- Test: `spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb`

**Interfaces:**
- Consumes: 既存 `DailyDetailExporter`（`I18n.t("activerecord.attributes.attendance_record.statuses.#{record.status}")` で「状態」列を出力）。
- Produces: 確定した欠勤日が日別明細 CSV に `欠勤` と印字される（現状は `Translation missing: ja.activerecord.attributes.attendance_record.statuses.absent`）。

> **なぜ Critical か**: `monthly_attendance_summaries` に欠勤日数の列は無く、`MonthlySummaries::Aggregate` の `WORKED_STATUSES` は `absent` を除外するだけで計上しない。**欠勤確定が賃金計算へ届く経路はこの CSV の「状態」列だけ**。給与担当が受け取る賃金台帳の基礎資料（労基法 108 条・109 条）に i18n のエラー文字列が印字される。`absent` enum は先行スライスで追加済みだが、**この status を持つ行を生成できるようにしたのは 4-2c-2 が初めて**。

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb` に追加（既存の describe 群の末尾。既存 spec の `let` / ヘルパ名に合わせること）:

```ruby
  it "確定した欠勤日の「状態」列に「欠勤」を出力する（i18n 欠落で Translation missing を出さない）" do
    create(:attendance_record, user:, work_date: Date.new(2026, 5, 1), status: :absent,
                               absence_reason: :unauthorized, clock_in: nil)

    body = described_class.call(user:, period:) # 既存 spec の呼び出し形に合わせる
    expect(body).to include("欠勤")
    expect(body).not_to include("Translation missing")
  end
```

Run: `bundle exec rspec spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb`
Expected: FAIL（`Translation missing: ja.activerecord.attributes.attendance_record.statuses.absent` が本文に含まれる）

> 既存 spec の呼び出し方（`described_class.new(...).call` か `.call` か、`period` の作り方）を必ず読んで合わせること。テストの骨格を発明しない。

- [ ] **Step 2: i18n を追加**

`config/locales/ja.yml` の `activerecord.attributes.attendance_record.statuses` の `on_leave: 全休` の直後に追加（インデントは既存行と厳密に一致させる）:

```yaml
          absent: 欠勤
```

- [ ] **Step 3: 実測で確認**

Run: `bin/rails runner 'puts I18n.t("activerecord.attributes.attendance_record.statuses.absent")'`
Expected: `欠勤`

- [ ] **Step 4: テストを通す**

Run: `bundle exec rspec spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb`
Expected: 全 PASS

- [ ] **Step 5: rubocop + Commit**

```bash
bundle exec rubocop --force-exclusion spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb
git add config/locales/ja.yml spec/services/monthly_summaries/csv/daily_detail_exporter_spec.rb
git commit -m "fix: 給与 CSV の absent ラベル欠落（Translation missing が賃金台帳に印字される・労基法 108/109 条）"
```

---

## Task R2: 監査の構造化 + 撤回時の欠勤復元（approval-engine Critical）

**Files:**
- Create: `db/migrate/<ts>_add_absence_reason_to_attendance_histories.rb`
- Modify: `app/models/attendance_history.rb`
- Modify: `app/models/attendance_record.rb`（`.absence_reason_note` を削除）
- Modify: `app/services/absences/confirm.rb`（履歴 payload のみ）
- Modify: `app/services/leave_requests/apply_approval.rb`
- Modify: `app/services/leave_requests/withdraw.rb`
- Test: `spec/models/attendance_history_spec.rb` / `spec/models/attendance_record_spec.rb` / `spec/services/absences/confirm_spec.rb` / `spec/services/leave_requests/apply_approval_spec.rb` / `spec/services/leave_requests/withdraw_spec.rb` / `spec/requests/approval_assignments_spec.rb`

**Interfaces:**
- Consumes: 既存 `AttendanceRecord.absence_reasons`（`{unauthorized: 0, illness: 1, family: 2, investigating: 3, other: 4}`・凍結）。既存 `AttendanceHistory` の追記専用トリガー（UPDATE/DELETE/TRUNCATE を拒否 — **ALTER TABLE ADD COLUMN は DDL ゆえ影響なし**）。
- Produces:
  - `attendance_histories.absence_reason`（integer, null 可）— 「この履歴行が指す欠勤理由」。`absence_confirmed` = 確定した理由 / `absence_to_paid` = **振替前**の理由 / `absence_restored` = 復元した理由
  - `AttendanceHistory.event_types` に `absence_restored: 10`（append・actor 必須）
  - `LeaveRequests::Withdraw` が `absence_to_paid` 履歴を持つ日を `destroy!` せず `absent` へ復元する
  - `AttendanceRecord.absence_reason_note` は**削除**（翻訳結果を append-only 監査に焼く設計を撤回）

> **なぜ Critical か（実挙動で確認済み）**: `Absences::Confirm` が作る `absent` AR は `clock_in` が nil。事後有給の承認で `on_leave` に昇格しても nil のまま。そこへ撤回承認が走ると `Withdraw#restore_attendance_records` は `record.clock_in.blank?` を「この休暇が作った AR」と解釈して `destroy!` する。`AbsenceCandidate` は確定時に destroy 済みで再生成されず、`AttendanceAnomalies::Detect#covering_leave_requests` は **status を問わない**ため撤回済み LR がその日を覆い続け候補は二度と生えない。結果その日は **AR なし・候補なし・残高も戻る** ＝ 欠勤が台帳から消える。「確定 → 本人が事後有給を申請 → 承認 → 誤申請に気づいて撤回」という**正常操作**で到達する。
>
> **なぜ構造化が前提か**: 現状の `absence_to_paid` 履歴は理由を `"欠勤理由: 疾病・傷病"` という**ローカライズ済み文字列**でしか持たない。復元するには逆パースが要る。`previous_status` は整数 5 で構造化されているのに随伴列だけ非構造だった。加えて `other` の自由記述は `Absences::Confirm` が AR.note にのみ書き、`ApplyApproval` の `record.note = nil` が消すため**どこにも残らない**（コード自身が掲げる労基法 109 条の要件に反する）。

- [ ] **Step 1: 失敗するテストを書く（Withdraw の復元 — これが本タスクの主眼）**

`spec/services/leave_requests/withdraw_spec.rb` に describe を追加（既存 spec の `let` / ヘルパ名に合わせること）:

```ruby
  describe "absent 由来の AR の復元（4-2c-2 レビュー C1）" do
    it "事後有給の撤回で AR を destroy せず absent へ復元し、欠勤理由と自由記述を戻す" do
      record = create(:attendance_record, user:, work_date: start_date, status: :absent,
                                          absence_reason: :other, note: "私用のため", clock_in: nil)
      lr = leave(type: unpaid_type, sd: start_date, ed: start_date)
      LeaveRequests::ApplyApproval.call(leave_request: lr, acting_user: approver)
      expect(record.reload.status).to eq("on_leave")

      described_class.call(leave_request: lr, acting_user: approver)

      restored = AttendanceRecord.find_by(user_id: user.id, work_date: start_date)
      expect(restored).to be_present            # destroy されていない
      expect(restored.status).to eq("absent")
      expect(restored.absence_reason).to eq("other")
      expect(restored.note).to eq("私用のため") # other の自由記述が戻る
    end

    it "復元を absence_restored 履歴に記録する（actor 必須・previous_status は on_leave）" do
      create(:attendance_record, user:, work_date: start_date, status: :absent,
                                 absence_reason: :illness, clock_in: nil)
      lr = leave(type: unpaid_type, sd: start_date, ed: start_date)
      LeaveRequests::ApplyApproval.call(leave_request: lr, acting_user: approver)

      described_class.call(leave_request: lr, acting_user: approver)

      history = AttendanceHistory.find_by(user_id: user.id, event_type: :absence_restored,
                                          event_date: start_date)
      expect(history).to be_present
      expect(history.actor_id).to eq(approver.id)
      expect(history.previous_status).to eq(AttendanceRecord.statuses[:on_leave])
      expect(history.new_status).to eq(AttendanceRecord.statuses[:absent])
      expect(history.absence_reason).to eq("illness")
    end

    it "absent 由来でない（休暇が新規作成した）AR は従来どおり destroy される" do
      lr = leave(type: unpaid_type, sd: start_date, ed: start_date)
      LeaveRequests::ApplyApproval.call(leave_request: lr, acting_user: approver)
      expect(AttendanceRecord.find_by(user_id: user.id, work_date: start_date)).to be_present

      described_class.call(leave_request: lr, acting_user: approver)

      expect(AttendanceRecord.find_by(user_id: user.id, work_date: start_date)).to be_nil
      expect(AttendanceHistory.where(event_type: :absence_restored)).not_to exist
    end
  end
```

Run: `bundle exec rspec spec/services/leave_requests/withdraw_spec.rb -e "absent 由来"`
Expected: FAIL（1 例目は `restored` が nil ＝ AR が destroy されている。2 例目は `absence_restored` が未定義で `ArgumentError`）

> `withdraw_spec.rb` が存在しない場合は新規作成し、`spec/services/leave_requests/apply_approval_spec.rb` の `let` / `leave` ヘルパ構成を写して使うこと。

- [ ] **Step 2: migration を生成して body を差し替え**

```bash
bin/rails generate migration AddAbsenceReasonToAttendanceHistories
```

body を全置換:

```ruby
# frozen_string_literal: true

class AddAbsenceReasonToAttendanceHistories < ActiveRecord::Migration[8.1]
  def change
    # 監査に「欠勤理由」を構造化して残す（4-2c-2 レビュー: ローカライズ済みラベルを append-only 監査に
    # 焼くと機械復元できず locale 変更で壊れる）。撤回時の absent 復元（Withdraw）が本列を読む。
    # 追記専用トリガーは行レベル（UPDATE/DELETE/TRUNCATE）ゆえ ADD COLUMN は影響しない。
    add_column :attendance_histories, :absence_reason, :integer
  end
end
```

Run: `bin/rails db:migrate && bin/rails db:test:prepare`
Expected: `db/schema.rb` の `attendance_histories` に `t.integer "absence_reason"` が追記される（手編集しない）

- [ ] **Step 3: `AttendanceHistory` を拡張**

`app/models/attendance_history.rb` の `enum :event_type` を差し替え（**末尾に append のみ**）:

```ruby
  enum :event_type, {
    clock_in: 0, clock_out: 1, leave_approved: 2, leave_withdrawn: 3,
    clock_change_approved: 4, absence_confirmed: 5, absence_to_paid: 6,
    proxy_clock: 7, interval_shortage: 8, clock_change_withdrawn: 9,
    absence_restored: 10
  }, validate: true

  # 「この履歴行が指す欠勤理由」を構造化して保存する（4-2c-2 レビュー）。
  #   absence_confirmed = 確定した理由 / absence_to_paid = 振替前の理由 / absence_restored = 復元した理由
  # 整数マッピングは AttendanceRecord と同一（凍結）。翻訳結果を監査へ焼かず、ラベルは読む時に解決する。
  enum :absence_reason, AttendanceRecord.absence_reasons, prefix: true, validate: { allow_nil: true }
```

`validates :actor_id, presence: true, if: :absence_to_paid?` の直後に追加:

```ruby
  validates :actor_id, presence: true, if: :absence_restored?  # 4-2c-2 撤回時の欠勤復元
```

- [ ] **Step 4: enum マッピングの pin テストを追加**

`spec/models/attendance_history_spec.rb` に追加:

```ruby
  describe "enum マッピングの凍結（append-only・鉄則 7）" do
    it "event_type は既存 0〜9 を保持し absence_restored を 10 で append する" do
      expect(described_class.event_types).to eq(
        "clock_in" => 0, "clock_out" => 1, "leave_approved" => 2, "leave_withdrawn" => 3,
        "clock_change_approved" => 4, "absence_confirmed" => 5, "absence_to_paid" => 6,
        "proxy_clock" => 7, "interval_shortage" => 8, "clock_change_withdrawn" => 9,
        "absence_restored" => 10
      )
    end

    it "absence_reason は AttendanceRecord と同一マッピング（drift 防止）" do
      expect(described_class.absence_reasons).to eq(AttendanceRecord.absence_reasons)
    end
  end

  describe "actor 必須（absence_restored）" do
    let(:org) { create(:organization) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "absence_restored は actor 無しで無効" do
      h = build(:attendance_history, user: create(:user), actor: nil,
                                     event_type: :absence_restored, event_date: Date.new(2026, 5, 1))
      expect(h).to be_invalid
      expect(h.errors[:actor_id]).to be_present
    end
  end
```

- [ ] **Step 5: `Absences::Confirm` の履歴 payload を構造化**

`app/services/absences/confirm.rb` の `confirm_one` 内の `AttendanceHistory.create!` を差し替え:

```ruby
        AttendanceHistory.create!(
          user: @target_user, actor: @actor,
          event_type: :absence_confirmed, event_date: candidate.target_date,
          new_status: AttendanceRecord.statuses[:absent],
          absence_reason: @absence_reason,  # 構造化（翻訳結果を監査へ焼かない）
          note: note_for_reason             # other の自由記述のみ（他は nil）
        )
```

`spec/services/absences/confirm_spec.rb` の該当 assert を差し替え:

```ruby
      expect(history.absence_reason).to eq("unauthorized")
      expect(history.note).to be_nil # other 以外は自由記述なし
```

（`expect(history.note).to eq("欠勤理由: 無届欠勤")` の行を削除する）

さらに `describe "正常系"` に 1 例追加:

```ruby
    it "other の自由記述を監査履歴にも残す（労基法 109 条・AR.note は事後有給でクリアされるため）" do
      c = candidate
      after_grace { confirm(dates: [target_date], candidates: [c], reason: "other", note: "私用") }

      history = AttendanceHistory.find_by(user_id: user.id, event_type: :absence_confirmed)
      expect(history.absence_reason).to eq("other")
      expect(history.note).to eq("私用")
    end
```

- [ ] **Step 6: `ApplyApproval` が構造化理由 + 自由記述を退避**

`app/services/leave_requests/apply_approval.rb` の `upsert_attendance_records` の捕捉部を差し替え（**クリア前に読む** — capture-before-assign）:

```ruby
        was_absent = record.absent? # §12② 遷移前 status を代入前に捕捉（silent no-op 回避）
        previous_absence_reason = record.absence_reason # 監査へ退避（クリア前に読む）
        previous_note = record.note                     # other の自由記述（クリア前に読む）
        record.status = leave_status
        record.leave_type_id = @leave_request.leave_type_id
        if was_absent
          record.absence_reason = nil # §11① 随伴列クリア（DB CHECK と整合）
          record.note = nil
        end
        record.save!
        # §12⑥ 監査（absent→on_leave の痕跡）。Withdraw の復元元でもある（4-2c-2 レビュー C1）
        record_absence_to_paid(record, date, previous_absence_reason, previous_note) if was_absent
        recalculate(record)
```

`record_absence_to_paid` を差し替え:

```ruby
    # absent→on_leave（事後有給）の監査（SPEC §6.2 L808・§12⑥）。actor 必須。
    # AR.absence_reason / note は上書きでクリアされるため、構造化した理由と自由記述を履歴へ退避する
    # （労基法 109 条 5 年保存 — かつ LeaveRequests::Withdraw がこの行を読んで absent を復元する）
    def record_absence_to_paid(record, date, previous_absence_reason, previous_note)
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id,
        actor: @acting_user,
        source: @leave_request,
        event_type: :absence_to_paid,
        event_date: date,
        previous_status: AttendanceRecord.statuses[:absent],
        new_status: AttendanceRecord.statuses[record.status],
        absence_reason: previous_absence_reason,
        note: previous_note
      )
    end
```

`spec/services/leave_requests/apply_approval_spec.rb` の note assert を差し替え:

```ruby
    it "absence_to_paid に元の欠勤理由を構造化して退避する（W1・労基法 109 条の証跡）" do
      create(:attendance_record, user:, work_date: start_date, status: :absent,
                                 absence_reason: :illness, clock_in: nil)

      apply(leave(type: unpaid_type, sd: start_date, ed: start_date))

      history = AttendanceHistory.find_by(user_id: user.id, event_type: :absence_to_paid,
                                          event_date: start_date)
      expect(history.absence_reason).to eq("illness")
    end

    it "other の自由記述も履歴へ退避する（AR.note はクリアされる）" do
      create(:attendance_record, user:, work_date: start_date, status: :absent,
                                 absence_reason: :other, note: "私用のため", clock_in: nil)

      apply(leave(type: unpaid_type, sd: start_date, ed: start_date))

      history = AttendanceHistory.find_by(user_id: user.id, event_type: :absence_to_paid)
      expect(history.absence_reason).to eq("other")
      expect(history.note).to eq("私用のため")
      expect(AttendanceRecord.find_by(work_date: start_date).note).to be_nil
    end
```

（既存の `expect(history.note).to eq("欠勤理由: 疾病・傷病")` の例を上記で置換する）

- [ ] **Step 7: `Withdraw` に絶対に間違えてはいけない実装を入れる**

`app/services/leave_requests/withdraw.rb` の `restore_attendance_records` を差し替え、private を追加:

```ruby
    # counted_dates を再計算せず、範囲内で leave-status を持つ AR を直接巻き戻す（R3/R4）。
    # 1 日 1 AR（unique [user, work_date]）ゆえ範囲内 leave-status AR = この休暇の日。
    # **absent 由来の日は destroy せず復元する**（4-2c-2 レビュー C1 — 候補は再生成されず欠勤が台帳から消える）
    def restore_attendance_records
      AttendanceRecord
        .where(user_id: @leave_request.requester_id,
               work_date: @leave_request.start_date..@leave_request.end_date,
               status: %i[on_leave morning_half afternoon_half])
        .find_each do |record|
          conversion = absence_to_paid_history(record.work_date)
          if conversion
            restore_absence(record, conversion)
          elsif record.clock_in.blank?
            record.destroy!
          else
            record.update!(status: record.clock_out.present? ? :clocked_out : :working, leave_type_id: nil)
            Clockings::Recalculate.call(record:) if record.clock_out.present?
          end
        end
    end

    # この休暇の承認が absent を on_leave へ昇格させた日か。昇格した AR は clock_in が nil のままなので、
    # clock_in.blank? だけでは「休暇が新規作成した AR」と区別できない（destroy すると欠勤が消える）
    def absence_to_paid_history(work_date)
      AttendanceHistory.find_by(user_id: @leave_request.requester_id, source: @leave_request,
                                event_type: :absence_to_paid, event_date: work_date)
    end

    # 欠勤へ戻す（理由・自由記述は absence_to_paid 履歴が構造化して保持している）。
    # previous_status は update! の**前**に捕捉する（capture-before-assign）
    def restore_absence(record, conversion)
      previous_status = AttendanceRecord.statuses[record.status]
      record.update!(status: :absent, absence_reason: conversion.absence_reason,
                     note: conversion.note, leave_type_id: nil)
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id, actor: @acting_user, source: @leave_request,
        event_type: :absence_restored, event_date: record.work_date,
        previous_status: previous_status,
        new_status: AttendanceRecord.statuses[:absent],
        absence_reason: conversion.absence_reason, note: conversion.note
      )
    end
```

> **順序が重要**: `previous_status` は `update!` の前に読む。`update!` の後に `record.status` を読むと常に `absent` になり、履歴の遷移前後が同値の無意味な行になる（`ApplyApproval` の `was_absent` と同じ罠）。

- [ ] **Step 8: `AttendanceRecord.absence_reason_note` を削除**

`app/models/attendance_record.rb` から `def self.absence_reason_note(reason) ... end` とその上のコメントブロックを削除する（構造化列に置き換わり、呼び出し元は無くなった）。

`spec/models/attendance_record_spec.rb` の `describe ".absence_reason_note（監査 note の単一書式源）" do ... end` ブロックを削除する。

Run: `grep -rn "absence_reason_note" app/ spec/`
Expected: 出力なし（残っていれば消し漏れ）

- [ ] **Step 9: 実 approve→withdraw 経路の統合テストを追加**

`spec/requests/approval_assignments_spec.rb` の `describe "PATCH approve（absent 日への事後有給・§11①/§12② 実 approve path）"` の末尾に追加（既存 `let` の `org` / `hr` / `dept` / `boss` / `emp` / `leave` / `assignment_for` を使う）:

```ruby
    it "承認後に撤回まで通しても欠勤が台帳から消えない（実 approve/withdraw path・stub なし）" do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, user: emp, work_date: Date.new(2026, 5, 1), status: :absent,
                                   absence_reason: :illness, clock_in: nil)
      end

      sign_in boss
      patch approve_approval_assignment_url(assignment_for(1), host: tenant_host(org))
      sign_in dept
      patch approve_approval_assignment_url(assignment_for(2), host: tenant_host(org))

      sign_in emp
      patch request_withdrawal_leave_request_url(leave, host: tenant_host(org)),
            params: { withdrawal_reason: "誤申請のため" }

      ActsAsTenant.with_tenant(org) do
        withdrawal = leave.approval_assignments.where(purpose: :withdrawal).order(:position)
        sign_in boss
        patch approve_approval_assignment_url(withdrawal.first, host: tenant_host(org))
        sign_in dept
        patch approve_approval_assignment_url(withdrawal.second, host: tenant_host(org))

        record = AttendanceRecord.find_by(user_id: emp.id, work_date: Date.new(2026, 5, 1))
        expect(record).to be_present                 # destroy されていない
        expect(record.status).to eq("absent")
        expect(record.absence_reason).to eq("illness")
        expect(AttendanceHistory.where(event_type: :absence_restored)).to exist
      end
    end
```

> `purpose` / `withdrawal` の列名・enum 名・撤回承認の段数は `spec/requests/withdrawal_flow_spec.rb` を読んで実物に合わせること。**撤回フローの正確な手順はその spec が正**。合わなければ、そちらの流儀を写す。

- [ ] **Step 10: テストを通す**

Run: `bundle exec rspec spec/models/attendance_history_spec.rb spec/models/attendance_record_spec.rb spec/services/absences/confirm_spec.rb spec/services/leave_requests spec/requests/approval_assignments_spec.rb`
Expected: 全 PASS

- [ ] **Step 11: 全体回帰**

Run: `bundle exec rspec`
Expected: 全 PASS（既知の pending 1 件のみ）

- [ ] **Step 12: rubocop + brakeman + Commit**

```bash
git diff --name-only | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion
bin/brakeman --no-pager
git add app db/migrate db/schema.rb spec
git commit -m "fix: 撤回時に absent を復元（欠勤の台帳消失を封鎖）+ 監査理由の構造化（approval-engine Critical）"
```

---

## Task R3: `Absences::Confirm` の構造修正（tenant / approval-engine / labor-law Warning）

**Files:**
- Modify: `app/services/absences/confirm.rb`
- Modify: `app/controllers/absence_confirmations_controller.rb`
- Test: `spec/services/absences/confirm_spec.rb` / `spec/requests/absence_confirmations_spec.rb`

**Interfaces:**
- Consumes: `Absences::IneligibleError` / `Absences::ClosingLockedError`（既存）。`MonthlySummaries::ClosingLock`（既存）。
- Produces:
  - ガード列（`call`）: `guard_actor_same_organization!` → **`with_tenant` の内側で** `guard_reason!` → `guard_candidates_exist!` → `guard_candidates_belong_to_target!` → `guard_not_covered!` → `guard_notified!` → `guard_grace_period!` → `confirm_all`（`guard_closing!` は tx 内の先頭）
  - `confirm_one` の rescue は **`RecordNotUnique` のみ**。`RecordInvalid` は log + `Rails.error.report` + 再 raise
  - controller が `ActiveRecord::RecordInvalid` を rescue して 422

> **なぜ `guard_actor_same_organization!` が `with_tenant` の外か**: `with_tenant(@target_user.organization)` は文脈を**切り替える**ため、その内側では複合 FK も `user_must_belong_to_same_organization` も越境を検出できない（`organization_id` が引数 org から供給され `user_id` と整合する）。昇格する**前**に actor と target の組織一致を検証するのが、この service 単体の唯一の境界。
>
> **なぜ `RecordInvalid` を握り潰さないか**: `AttendanceRecord` には同日 uniqueness のモデル検証が無い（一次防衛は unique index）。したがって並行打刻レースは**必ず `RecordNotUnique`**。`RecordInvalid` は本物の検証失敗しか意味せず、それを「既に勤怠記録があるためスキップしました」という flash で管理者に返すのは事実に反する。

- [ ] **Step 1: 失敗するテストを書く**

`spec/services/absences/confirm_spec.rb` の `describe "ガード（すべて write 前に 422）"` に追加:

```ruby
    it "操作者が対象社員と別テナントなら拒否する（with_tenant 昇格の前に検証・tenant-isolation W2）" do
      other_org = create(:organization, subdomain: "other")
      outsider = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      c = candidate

      expect {
        after_grace do
          described_class.call(target_user: user, dates: [target_date], candidates: [c],
                               absence_reason: "unauthorized", note: nil, actor: outsider)
        end
      }.to raise_error(Absences::IneligibleError, /組織が一致しません/)

      expect(AttendanceRecord.count).to eq(0)
    end

    it "猶予中に提出された休暇申請がある日は確定できない（弁明の行使・labor-law W4）" do
      c = candidate
      create(:leave_request, requester: user, start_date: target_date, end_date: target_date)

      expect { after_grace { confirm(dates: [target_date], candidates: [c]) } }
        .to raise_error(Absences::IneligibleError, /休暇申請が存在する/)

      expect(AttendanceRecord.count).to eq(0)
      expect(AbsenceCandidate.where(id: c.id)).to exist
    end
```

`describe "per-day savepoint（§12⑤）"` の 3rd-write テストを差し替え（**skip でなく再 raise が正**）:

```ruby
    it "履歴作成（3 つ目の write）が失敗したら握り潰さず伝播し、AR も候補も巻き戻る" do
      c = candidate
      allow(AttendanceHistory).to receive(:create!)
        .and_raise(ActiveRecord::RecordInvalid.new(AttendanceHistory.new))

      expect { after_grace { confirm(dates: [target_date], candidates: [c]) } }
        .to raise_error(ActiveRecord::RecordInvalid)

      expect(AttendanceRecord.count).to eq(0)           # 1 つ目の write が巻き戻っている
      expect(AbsenceCandidate.where(id: c.id)).to exist # 2 つ目の write が巻き戻っている
    end
```

`spec/requests/absence_confirmations_spec.rb` に追加:

```ruby
    it "記録の整合性エラーは 500 でなく 422（管理者に事実と異なる skip flash を出さない）" do
      candidate_for(sub)
      allow(AttendanceHistory).to receive(:create!)
        .and_raise(ActiveRecord::RecordInvalid.new(AttendanceHistory.new))
      sign_in manager

      after_grace { post absence_confirmations_url(host: tenant_host(org)), params: confirm_params(sub, [target_date]) }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(AttendanceRecord.unscoped.count).to eq(0)
    end
```

Run: `bundle exec rspec spec/services/absences/confirm_spec.rb spec/requests/absence_confirmations_spec.rb`
Expected: FAIL（4 例）

- [ ] **Step 2: `call` を差し替え、ガードを追加**

`app/services/absences/confirm.rb` の `call` とクラス冒頭コメントを差し替え:

```ruby
    # ガード順は意味論上固定:
    #   ① 操作者の組織 → ② 毒入力 reason → ③ 候補不在日 → ④ 候補の所有者不一致
    #   → ⑤ 弁明の行使（AR / 休暇申請が覆う日） → ⑥ 本人未通知 → ⑦ 猶予前 → ⑧ 締め済み（tx 内）
    #   ① を with_tenant の**外**に置くのは、with_tenant がテナント文脈を「切り替える」ため内側では
    #     複合 FK も cross_tenant 検証も越境を検出できないから（この service 単体の唯一の境界）。
    #   ② を先頭近くに置くのは、per-day の rescue（並行打刻の競合吸収）が毒入力を「skip 日」として
    #     握り潰し 422 を返さなくなるのを防ぐため（部分成功にしない）。
    #   ⑥ を ⑦ より前に置くのは next_business_day(nil) を計算させないため。
    #   ⑧ を tx 内で撃つのは、判定と write の間に締め（submitted）が commit する窓を閉じるため。
    def call
      guard_actor_same_organization! # with_tenant へ入る前（昇格前）に検証する
      ActsAsTenant.with_tenant(organization) do
        guard_reason!
        guard_candidates_exist!
        guard_candidates_belong_to_target!
        guard_not_covered!
        guard_notified!
        guard_grace_period!
        confirm_all
      end
    end
```

private に追加（`guard_reason!` の直前）:

```ruby
    # ① with_tenant(@target_user.organization) は文脈を切り替えるため、内側の複合 FK も
    #    user_must_belong_to_same_organization も越境を検出できない（organization_id が引数 org 由来で
    #    user_id と整合してしまう）。昇格前に actor と target の組織一致を検証するのが唯一の境界
    def guard_actor_same_organization!
      return if @actor.organization_id == @target_user.organization_id

      raise IneligibleError, "操作者と対象社員の組織が一致しません"
    end
```

`guard_candidates_belong_to_target!` の直後に追加:

```ruby
    # ⑤ 候補の掃除は日次バッチのみ。バッチ実行後〜猶予期限までに本人が休暇申請を出す（＝通知に応じた
    #    弁明そのもの）と、候補行は残ったまま確定できてしまう。write 前に候補の前提を再評価する
    def guard_not_covered!
      covered = @candidates.map(&:target_date).select { |date| covered?(date) }
      return if covered.empty?

      raise IneligibleError, "#{covered.join(', ')} は勤怠記録または休暇申請が存在するため確定できません"
    end

    # AttendanceAnomalies::Detect#covered? と同一条件（AR 実在 or 全 status の covering LR 実在）
    def covered?(date)
      AttendanceRecord.exists?(user_id: @target_user.id, work_date: date) ||
        LeaveRequest.where(requester_id: @target_user.id)
                    .where(start_date: ..date).where(end_date: date..).exists?
    end
```

- [ ] **Step 3: `confirm_all` から `with_tenant` を外し、`guard_closing!` を tx 内へ、rescue を絞る**

`confirm_all` を差し替え:

```ruby
    def confirm_all
      confirmed = []
      skipped = []
      ActiveRecord::Base.transaction do
        guard_closing! # ⑧ tx 内で評価（判定と write の間に締めが commit する窓を閉じる）
        @candidates.each do |candidate|
          confirm_one(candidate)
          confirmed << candidate.target_date
        rescue ActiveRecord::RecordNotUnique
          # 真の競合（並行 clock_in / CCR 承認が同日 AR を先に作った）。AR に同日 uniqueness の
          # モデル検証は無く unique index が一次防衛ゆえ、この経路の競合は必ず RecordNotUnique。
          # savepoint のみ rollback され親 tx は健全・候補は intact（再確定可能）
          skipped << candidate.target_date
        rescue ActiveRecord::RecordInvalid => e
          # 本物の検証失敗（越境・毒入力・監査行の不備）。「既に勤怠記録があるためスキップ」という
          # 事実と異なる flash に化けさせない。savepoint rollback 後に伝播させ全件やめる（fail-closed）
          Rails.logger.error("[Absences::Confirm] 検証失敗 date=#{candidate.target_date}: #{e.record.errors.full_messages}")
          Rails.error.report(e, handled: false)
          raise
        end
      end
      Result.new(confirmed_dates: confirmed, skipped_dates: skipped)
    end
```

> `with_tenant` は `call` へ移したので `confirm_all` からは削除する。

- [ ] **Step 4: controller が `RecordInvalid` を 422 に落とす**

`app/controllers/absence_confirmations_controller.rb` の `create` の rescue 節に追加（`rescue Absences::IneligibleError, ...` の**後**）:

```ruby
  rescue ActiveRecord::RecordInvalid
    # Absences::Confirm が握り潰さず伝播させた本物の検証失敗。500 でなく 422 で再描画する
    render_ineligible("欠勤確定に失敗しました（記録の整合性エラー）。管理者へご連絡ください")
```

- [ ] **Step 5: テストを通す**

Run: `bundle exec rspec spec/services/absences/confirm_spec.rb spec/requests/absence_confirmations_spec.rb`
Expected: 全 PASS

- [ ] **Step 6: 全体回帰 + rubocop + brakeman + Commit**

```bash
bundle exec rspec
git diff --name-only | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion
bin/brakeman --no-pager
git add app spec
git commit -m "fix: Confirm に操作者組織ガードと弁明再検証を追加・締め判定を tx 内へ・rescue を真の競合のみに絞る"
```

---

## Task R4: 猶予期限の一元化 + 事前通知の格上げ + 確定 UI の猶予表示

**Files:**
- Create: `app/services/absences/grace_period.rb`
- Modify: `app/services/absences/confirm.rb`
- Modify: `app/services/attendance_anomalies/detect.rb`
- Modify: `app/controllers/absence_confirmations_controller.rb`
- Modify: `app/views/absence_confirmations/index.html.erb`
- Test: `spec/services/absences/grace_period_spec.rb` / `spec/services/attendance_anomalies/detect_spec.rb` / `spec/requests/absence_confirmations_spec.rb`

**Interfaces:**
- Consumes: `CompanyCalendarResolver#next_business_day(date) → Date | nil`。`Organization#time_zone`。
- Produces:
  - `Absences::GracePeriod.new(organization:)` — `#deadline(notified_on) → ActiveSupport::TimeWithZone | nil` / `#elapsed?(notified_on, now = Time.current) → Boolean`。`notified_on` ごとにメモ化（候補 N 件で 30 日レンジクエリが N 回飛ぶ N+1 を解消）
  - 事前通知（`Detect#notify_candidate`）が `priority: :action_required`・本文に**具体的な期限日時**と**処分予告**を含む
  - 確定 UI が候補ごとに「確定可能日時」を表示し、猶予未経過はチェックボックスを `disabled`

> **なぜ事前通知を格上げするか（labor-law W1）**: 弁明の機会を担保する起点である事前通知が `informational`（ベルのみ・メールは二重 opt-in 時のみ）である一方、既に賃金控除が確定した後の通知だけが `action_required`（メール常時）で確実に届く。労基法 24 条の適正手続きとしては順序が逆。
>
> **なぜ本文に期限日と帰結を書くか（labor-law W2）**: 「翌営業日」は会社カレンダー依存で本人には自明でなく、沈黙の帰結（欠勤確定・賃金控除）も告知されていない。不利益処分の予告は、企図する処分内容と沈黙の帰結を告げてこそ弁明の機会たり得る。

- [ ] **Step 1: 失敗するテストを書く（GracePeriod）**

`spec/services/absences/grace_period_spec.rb`:

```ruby
# frozen_string_literal: true

require "rails_helper"

RSpec.describe Absences::GracePeriod do
  let(:org) { create(:organization, time_zone: "Asia/Tokyo") }
  let(:grace) { described_class.new(organization: org) }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  describe "#deadline" do
    it "notified_on の翌営業日 17:00（組織 TZ）を返す（2026-05-01 金 → 2026-05-04 月 17:00 JST）" do
      deadline = grace.deadline(Date.new(2026, 5, 1))
      expect(deadline).to eq(Time.utc(2026, 5, 4, 8)) # JST 17:00 = UTC 08:00
    end

    it "連休を吸収する" do
      create(:company_calendar, date: Date.new(2026, 5, 4), day_type: :company_holiday, name: "連休")
      create(:company_calendar, date: Date.new(2026, 5, 5), day_type: :company_holiday, name: "連休")
      expect(grace.deadline(Date.new(2026, 5, 1))).to eq(Time.utc(2026, 5, 6, 8))
    end

    it "notified_on が nil なら nil（next_business_day(nil) を計算しない）" do
      expect(grace.deadline(nil)).to be_nil
    end

    it "同一 notified_on の再問い合わせはカレンダーを再クエリしない（メモ化・N+1 解消）" do
      grace.deadline(Date.new(2026, 5, 1))
      expect(CompanyCalendar).not_to receive(:where)
      grace.deadline(Date.new(2026, 5, 1))
    end
  end

  describe "#elapsed?" do
    it "16:59 JST は未経過・17:01 JST は経過（境界の両側）" do
      expect(grace.elapsed?(Date.new(2026, 5, 1), Time.utc(2026, 5, 4, 7, 59))).to be(false)
      expect(grace.elapsed?(Date.new(2026, 5, 1), Time.utc(2026, 5, 4, 8, 1))).to be(true)
    end

    it "notified_on が nil なら常に未経過（fail-closed）" do
      expect(grace.elapsed?(nil)).to be(false)
    end
  end
end
```

Run: `bundle exec rspec spec/services/absences/grace_period_spec.rb`
Expected: FAIL（`NameError: uninitialized constant Absences::GracePeriod`）

- [ ] **Step 2: `Absences::GracePeriod` を実装**

`app/services/absences/grace_period.rb`:

```ruby
# frozen_string_literal: true

module Absences
  # 欠勤確定の猶予期限（SPEC §6.8「猶予: 翌営業日 17:00」）の単一定義。
  # 確定ガード（Absences::Confirm）・事前通知本文（AttendanceAnomalies::Detect）・確定 UI が
  # 同じ値を共有する（二度書き禁止）。resolver を保持し notified_on ごとにメモ化して
  # 候補 N 件の 30 日レンジクエリ N 回（N+1）を 1 回に畳む。
  #
  # 17:00 は法定値ではなく運用値（SPEC §8 の鉄則: 法定値をテナント設定から読まない — 逆に
  # 本値は運用値ゆえコード内定数で足りる）。TZ は organization.time_zone（地域設定）。
  class GracePeriod
    DEADLINE_HOUR = 17

    def initialize(organization:)
      @organization = organization
      @resolver = CompanyCalendarResolver.new(organization:)
      @cache = {}
    end

    # notified_on の翌営業日 17:00（組織 TZ）。notified_on が nil、または先読み範囲内に
    # 稼働日が無ければ nil（呼び出し側が fail-closed に倒す）
    def deadline(notified_on)
      return nil if notified_on.nil?

      @cache[notified_on] ||= compute_deadline(notified_on)
    end

    # 猶予が経過したか。deadline を算出できない場合は false（未経過＝確定不可の側へ倒す）
    def elapsed?(notified_on, now = Time.current)
      due = deadline(notified_on)
      !due.nil? && now > due
    end

    private

    def compute_deadline(notified_on)
      next_day = @resolver.next_business_day(notified_on)
      return nil if next_day.nil?

      ActiveSupport::TimeZone[@organization.time_zone]
        .local(next_day.year, next_day.month, next_day.day, DEADLINE_HOUR)
    end
  end
end
```

- [ ] **Step 3: `Absences::Confirm` を `GracePeriod` に委譲**

`app/services/absences/confirm.rb` から `GRACE_DEADLINE_HOUR` 定数と `grace_deadline` / `resolver` の private メソッドを削除し、`guard_grace_period!` を差し替え:

```ruby
    # ⑦ 猶予 = notified_on の翌営業日 17:00（組織 TZ）。経過前は確定不可（適正手続き・労基法 24 条）
    def guard_grace_period!
      now = Time.current
      @candidates.each do |candidate|
        due = grace.deadline(candidate.notified_on)
        raise IneligibleError, "猶予期限を算出できません（稼働日が見つかりません）" if due.nil?
        next if now > due

        raise IneligibleError,
              "猶予期限（#{due.strftime('%Y-%m-%d %H:%M')}）を過ぎるまで #{candidate.target_date} は確定できません"
      end
    end

    def grace = @grace ||= GracePeriod.new(organization:)
```

- [ ] **Step 4: 事前通知を格上げし本文を書き換える**

`app/services/attendance_anomalies/detect.rb` の `notify_candidate` を差し替え、private に `grace` を追加:

```ruby
    def notify_candidate(candidate, today)
      user = candidate.user
      Notifier.call(
        target_user: user, priority: :action_required, source_type: :absence_candidate,
        title: "出勤記録がありません（欠勤確定の予告）",
        body: "#{candidate.target_date} の出勤記録がありません。#{deadline_text(today)}までに管理者へお申し出ください。" \
              "ご連絡が無い場合、欠勤として確定され賃金控除の対象となることがあります。"
      )
      candidate.update!(notified_on: today) # §11⑧ 本人 Notifier 成功後に確定（猶予起算アンカー保護）
      notify_candidate_manager(user, candidate.target_date) # 管理者は best-effort（notified_on の条件にしない）
    end

    # 猶予期限は notified_on（= today）の翌営業日 17:00。Absences::Confirm のガードと同一定義を共有する
    def deadline_text(today)
      due = grace.deadline(today)
      due ? due.strftime("%Y-%m-%d %H:%M") : "翌営業日 17:00"
    end

    def grace = @grace ||= Absences::GracePeriod.new(organization: @org)
```

`spec/services/attendance_anomalies/detect_spec.rb` の事前通知テストを差し替え:

```ruby
    it "事前通知は必須対応（メール常時）で、具体期限日と処分予告を含み打刻変更申請を約束しない" do
      notification = notifications_for(user, :absence_candidate).first
      expect(notification.priority).to eq("action_required")
      expect(notification.body).to include("賃金控除")
      expect(notification.body).to match(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}/) # 具体的な期限日時
      expect(notification.body).not_to include("打刻変更申請")
    end
```

（既存の「事前通知の body は打刻変更申請を約束しない」例を上記で置換する）

- [ ] **Step 5: 確定 UI に猶予期限を表示**

`app/controllers/absence_confirmations_controller.rb` の `load_candidates` を差し替え:

```ruby
  def load_candidates
    @candidates = policy_scope(AbsenceCandidate).includes(:user).order(:user_id, :target_date)
    @grace = Absences::GracePeriod.new(organization: current_user.organization)
  end
```

`app/views/absence_confirmations/index.html.erb` の `<li>` 内を差し替え:

```erb
            <li class="flex flex-wrap items-center justify-between gap-3 py-2 text-sm">
              <% confirmable = candidate.notified_on.present? && @grace.elapsed?(candidate.notified_on) %>
              <label class="flex items-center gap-2">
                <%= check_box_tag "dates[]", candidate.target_date.iso8601, false,
                      id: "candidate_#{candidate.id}", form: "confirm_#{user.id}",
                      disabled: !confirmable %>
                <span><%= candidate.target_date %></span>
              </label>

              <div class="flex items-center gap-3">
                <span class="text-xs <%= confirmable ? 'text-gray-500' : 'text-red-600' %>">
                  <% if candidate.notified_on.nil? %>
                    本人未通知（確定不可）
                  <% elsif confirmable %>
                    本人通知済（<%= candidate.notified_on %>）
                  <% else %>
                    <%= @grace.deadline(candidate.notified_on)&.strftime("%Y-%m-%d %H:%M") %> 以降に確定可
                  <% end %>
                </span>
                <%= button_to "却下", absence_confirmation_path(candidate), method: :delete,
                      class: "rounded border border-gray-300 px-3 py-1 text-gray-700 hover:bg-gray-100",
                      form: { data: { turbo_confirm: "#{candidate.target_date} の欠勤候補を却下します。よろしいですか？" } } %>
              </div>
            </li>
```

- [ ] **Step 6: UI の request spec を追加**

`spec/requests/absence_confirmations_spec.rb` の `describe "GET index"` に追加:

```ruby
    it "猶予未経過の候補は確定可能日時を表示し、チェックボックスを無効化する" do
      candidate_for(sub)
      sign_in manager

      travel_to(Time.utc(2026, 5, 4, 7, 59)) { get absence_confirmations_url(host: tenant_host(org)) }

      expect(response.body).to include("2026-05-04 17:00 以降に確定可")
      expect(response.body).to include("disabled")
    end
```

- [ ] **Step 7: テストを通す**

Run: `bundle exec rspec spec/services/absences spec/services/attendance_anomalies spec/requests/absence_confirmations_spec.rb`
Expected: 全 PASS

- [ ] **Step 8: 全体回帰 + rubocop + brakeman + Commit**

```bash
bundle exec rspec
git diff --name-only | grep -E '\.rb$' | xargs bundle exec rubocop --force-exclusion
bin/brakeman --no-pager
git add app spec
git commit -m "feat: 猶予期限を Absences::GracePeriod に一元化・事前通知を必須対応へ格上げ（期限日 + 処分予告）・確定 UI に猶予表示"
```

---

## Task R5: テストの判別性補強（tenant-isolation Warning 3 / Info 1）

**Files:**
- Test: `spec/policies/absence_candidate_policy_spec.rb`
- Test: `spec/policies/absence_confirmation_policy_spec.rb`
- Test: `spec/requests/absence_confirmations_spec.rb`

**Interfaces:**
- Consumes: 既存 policy 2 種と controller。**プロダクションコードは変更しない**。
- Produces: 「他テナントは見えない」テストが `organization_id` 明示 where の有効性を実際に裏付ける（現状は `around` の `with_tenant` により acts_as_tenant の default_scope だけで緑になり、policy から `organization_id` を削除しても落ちない）。`destroy`（却下）の他テナント IDOR variant を追加。

- [ ] **Step 1: policy spec の他テナント例を `without_tenant` で包む**

`spec/policies/absence_candidate_policy_spec.rb` の「他テナントの候補は hr_admin にも見えない」を差し替え:

```ruby
    it "他テナントの候補は hr_admin にも見えない（default_scope を外しても organization_id 明示で閉じる）" do
      outsider_candidate = ActsAsTenant.with_tenant(other_org) do
        create(:absence_candidate, user: create(:user, organization: other_org),
                                   organization: other_org, target_date: Date.new(2026, 5, 1))
      end

      # acts_as_tenant の default_scope を外し、policy の organization_id 明示 where だけで閉じることを確認
      ActsAsTenant.without_tenant do
        expect(resolve(hr)).not_to include(outsider_candidate)
        expect(resolve(hr)).to include(sub_candidate)
      end
    end
```

`spec/policies/absence_confirmation_policy_spec.rb` の「hr_admin でも他テナントの社員は含まない」を差し替え:

```ruby
    it "hr_admin でも他テナントの社員は含まない（default_scope を外しても閉じる）" do
      outsider = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }

      ActsAsTenant.without_tenant do
        expect(resolve(hr)).not_to include(outsider)
        expect(resolve(hr)).to include(sub)
      end
    end
```

> **判別性の確認**: policy から `organization_id` の where を一時的に削除すると、この例が落ちること（`without_tenant` で default_scope が無効になるため）。実装は変更せず、テストだけで確認すること。

- [ ] **Step 2: `destroy` の他テナント IDOR variant を追加**

`spec/requests/absence_confirmations_spec.rb` の `describe "DELETE destroy（却下 dismiss・§11④/§12⑧）"` に追加:

```ruby
    it "他テナントの候補は 404（IDOR variant 2 — acts_as_tenant）" do
      other_org = create(:organization, subdomain: "other")
      outsider_candidate = ActsAsTenant.with_tenant(other_org) do
        create(:absence_candidate, user: create(:user, organization: other_org),
                                   organization: other_org, target_date: target_date,
                                   notified_on: target_date)
      end
      sign_in hr

      delete absence_confirmation_url(outsider_candidate, host: tenant_host(org))

      expect(response).to have_http_status(:not_found)
      expect(AbsenceCandidate.unscoped.where(id: outsider_candidate.id)).to exist
    end
```

- [ ] **Step 3: テストを通す**

Run: `bundle exec rspec spec/policies spec/requests/absence_confirmations_spec.rb`
Expected: 全 PASS（プロダクションコードの変更なしで通るはず。落ちたら policy に本物の穴があるので報告すること — 勝手にテストを緩めない）

- [ ] **Step 4: rubocop + Commit**

```bash
bundle exec rubocop --force-exclusion spec/policies spec/requests/absence_confirmations_spec.rb
git add spec
git commit -m "test: policy の他テナント除外を without_tenant で判別的に + 却下の他テナント IDOR variant"
```

---

## Task R6: ドキュメント更新（SPEC / ROADMAP / 社労士確認 / RAILS_GOTCHAS）

**Files:**
- Modify: `docs/SPEC.md`（§4.14 taxonomy / §6.8 通知本文 / §6.10 制限 / §9.1 通知表）
- Modify: `docs/ROADMAP.md`
- Modify: `docs/LABOR_LAW_REVIEW_NOTES.md`
- Modify: `docs/RAILS_GOTCHAS.md`

**Interfaces:**
- Consumes: R1〜R5 の実装結果。
- Produces: docs が実装と一致し、`/spec-check` が §1.4 の不変条件を満たす。

> `docs/SPEC.md` を編集すると `regen-spec-index` フックが冒頭の索引（行番号表）を自動補正する。行番号のズレは気にせず本文だけ直すこと。

- [ ] **Step 1: SPEC §4.14 の event_type taxonomy に `absence_restored` を追記**

`docs/SPEC.md` の §4.14（AttendanceHistory の event_type 一覧）に、末尾値として `absence_restored`（整数 10・撤回時に事後有給から欠勤へ戻した記録）を追加する。**append-only であり既存値のリオーダは禁止**である旨の既存注記は保持すること。

- [ ] **Step 2: SPEC §6.8 の事前通知本文を実装に追従**

`docs/SPEC.md` の §6.8（打刻漏れ検知）にある

> 欠勤候補は本人へ事前通知:「{日付} の出勤記録がありません。打刻漏れなら打刻変更申請を（猶予: 翌営業日 17:00）」

を次に置換:

```markdown
欠勤候補は本人へ**必須対応**（ベル + メール）で事前通知:「{日付} の出勤記録がありません。{猶予期限日時}までに管理者へお申し出ください。ご連絡が無い場合、欠勤として確定され賃金控除の対象となることがあります」。**打刻変更申請は案内しない**（候補は定義上 AR 不在日であり `ClockChangeRequest` の `new_entry` は拒否されるため機能しない）。猶予期限は `notified_on` の翌営業日 17:00（組織 TZ・`Absences::GracePeriod` が単一定義）。
```

- [ ] **Step 3: SPEC §6.10 の「制限」を 8 ガードに追従**

`docs/SPEC.md` §6.10 の「制限」箇条書きの先頭に 2 項目を追加（既存 5 項目はそのまま）:

```markdown
- **操作者と対象社員の組織が一致しない確定は拒否**（`with_tenant` はテナント文脈を切り替えるため、複合 FK も model 検証も越境を検出できない — service 単体の唯一の境界）
- **対象日を勤怠記録または休暇申請（全 status）が覆う場合は確定不可**。猶予期間中に本人が休暇申請を出した場合（＝弁明の行使）を確定させないため、write 前に候補の前提を再評価する
```

- [ ] **Step 4: SPEC §9.1 に事前通知の行を追加**

§9.1 社員向け通知の表、「欠勤確定」行の**直前**に追加:

```markdown
| 欠勤候補（欠勤確定の予告） | 必須対応 | ベル + メール | 本人の次の稼働日バッチ |
```

- [ ] **Step 5: ROADMAP を更新**

`docs/ROADMAP.md` の 4-2 行の 4-2c-2 完了記録を差し替える。「6 ガード」を **「8 ガード〔操作者組織/毒入力/候補不在/所有者不一致/弁明の行使/未通知/猶予前/締め済み（tx 内）〕」** に直し、`撤回時の absent 復元（absence_restored）`・`監査理由の構造化`・`猶予期限の GracePeriod 一元化`・`事前通知の必須対応化` を追記する。

横断バックログに 4 行追加（末尾）:

```markdown
- [ ] **hr_admin の自己却下が監査ゼロ**（4-2c-2 approval-engine レビュー W4）: `AbsenceCandidatePolicy::Scope` の hr_admin 分岐は組織全体（自分の候補を含む）で、却下（dismiss）は候補を destroy するだけで `AttendanceHistory` を残さない。hr_admin は自分の無断欠勤の候補を痕跡ゼロで消せる。manager 分岐は `manager_id: user.id` で構造的に自己除外されており非対称。hr_admin 分岐からも自己を除外するか、却下に監査行を残すか、SPEC §6.10 に「意図的受容」と明記するかを判断する
- [ ] **欠勤確定後に実労働が判明した場合の是正経路が無い**（4-2c-2 labor-law レビュー W6・**社労士確認 #23**）: `absent` AR は `clock_in`/`clock_out` が nil ゆえ CCR は `target_record_clocked_out` を満たさず、`new_entry` は #48 で拒否、代理打刻は当日限定。唯一の救済「事後の有給申請」は年休残高を消費し、残高不足なら `OverBalanceError` で経路が消滅する。実際に労働した日の賃金請求権を年休で代替させることは労基法 24 条の全額払いを満たさない（労安法 66 条の 8 の 3 の労働時間把握義務とも緊張）。CCR `new_entry` 解禁（#48）と併せて設計する
- [ ] **`investigating`（調査中）のまま根拠なしで確定できる**（4-2c-2 labor-law レビュー W7・**社労士確認 #22**）: 確定 UI は `absence_reasons` を全件 select に展開し、`guard_reason!` は enum キーでありさえすれば通す。`other` 以外は `note` が nil で保存されるため、「調査中である」という理由で根拠を一切残さずに不可逆な（上記 W6）不利益記録を作れる。`investigating` を確定選択肢から除外して候補への注記専用にするか、選択時に `note` 必須 + UI 警告を出すかを判断する
- [ ] **`Absences::Confirm` の締め判定に MonthlyAttendanceSummary 行ロックが無い**（4-2c-2 approval-engine レビュー W2 の残余）: `guard_closing!` を tx 内へ移して窓を大幅に縮めたが、READ COMMITTED では判定 SELECT と `create!` の間に締めが commit する窓が理論上残る。完全に閉じるには対象 summary 行を `lock` で掴む必要がある。既存 `Approvals::Approve#guard!` も同じ窓を持つため、対称に直すなら別スライスで（ROADMAP「締め提出（Submit）の TOCTOU 窓」と同根）
```

- [ ] **Step 6: 社労士確認事項を追記**

`docs/LABOR_LAW_REVIEW_NOTES.md` の末尾（既存の `### #21` の直後）に 4 項目を追加。**既存テーブルが #1〜#20、`### #21` が使用済みゆえ #22 から採番する**（`grep -n "^### #" docs/LABOR_LAW_REVIEW_NOTES.md` と冒頭テーブルで必ず確認すること）:

```markdown
### #22 `investigating`（調査中）での欠勤確定の適否（4-2c-2 labor-law レビュー W7）

**状況**: 確定 UI は欠勤理由に `investigating`（打刻漏れ調査中）を選べ、`other` 以外は自由記述欄も出ない。すなわち「調査中である」という理由で、根拠を一切残さずに賃金控除に直結する記録を作れる。

**確認したいこと**: (a) 未確定事由での確定・控除は労基法 24 条の適正手続きとして許されるか（保留扱いにすべきか）、(b) 許すなら根拠（note）の記録を必須とすべきか。

**関連条文**: 労基法 24 条（賃金全額払い）<https://laws.e-gov.go.jp/law/322AC0000000049>

### #23 欠勤確定後に実労働が判明した場合の是正手順（4-2c-2 labor-law レビュー W6）

**状況**: `absent` AR は打刻列が nil ゆえ打刻変更申請（CCR）が機能せず（`new_entry` は拒否・#48）、代理打刻も当日限定。唯一の救済は「事後の有給申請」だが、これは年休残高を消費し、残高不足なら承認自体が `OverBalanceError` で失敗する。

**確認したいこと**: 実際に労働した日の賃金請求権を年次有給休暇で代替させることは労基法 24 条の全額払いを満たさないと解されるが、(a) 誤確定の是正手順として何が適切か、(b) システムとして最低限どの経路を用意すべきか。

**関連条文**: 労基法 24 条 / 労基法 39 条 5 項（年休は労働義務のある日の労務を免除する制度）/ 労安法 66 条の 8 の 3（労働時間の状況の把握義務）<https://laws.e-gov.go.jp/law/347AC0000000057>

### #24 弁明機会の担保水準（4-2c-2 labor-law レビュー W1/W4）

**状況**: `notified_on` は Notifier の**送信成功**を記録するもので、本人の**受領・認識**ではない。異議申立てを記録する場も無く、猶予期限は時間経過のみを強制する（本スライスで、猶予中に提出された休暇申請を確定させないガードは追加した）。

**確認したいこと**: 事前通知を必須対応（ベル + メール）へ格上げし、本文に具体期限日と処分予告を明記した現在の水準で、労基法 24 条の適正手続きとして足りるか。異議申立ての記録（申立フォーム・記録テーブル）を要するか。

### #25 労基法 109 条の保存期間の経過措置

**状況**: 本則「五年間」は原典照合済み。ただし附則 143 条 3 項による経過措置（当分の間 三年間）の有無・現行の効力は **jp-labor-evidence MCP で取得できず未照合**（`get_article` が `not_found`。附則条文は本ツールの取得範囲外と思われる）。

**確認したいこと**: 実運用の保存期間設定（アーカイブ・匿名化ジョブの起点）を決める前に、現行の効力を確認したい。
```

さらに、既存の「追加確認事項（Phase 4-2）」節の 3 項目目（`illness` / `family` の一律 unpaid 扱い）に、本スライスで確定した挙動を追記する（ラベル「疾病・傷病」「家庭事情」は法令用語ではなく就業規則上の分類語であり、単独では有給／無給の別を示さない旨）。

- [ ] **Step 7: RAILS_GOTCHAS に 3 件追記**

`docs/RAILS_GOTCHAS.md` に、実際に踏んだ罠のみを WHAT/WHY/HOW/verified 形式で追記する。

**（1）`acts_as_tenant` セクションへ:**

```markdown
### `ActsAsTenant.with_tenant(信頼できない record.organization)` はテナント境界ではなく昇格プリミティブ（4-2c-2・verified 2026-07-09）

- **WHAT:** 書き込みを伴う service が `with_tenant(@target_user.organization)` で自己ラップしていると、他テナントの `target_user` を渡された瞬間にテナント文脈がその org へ切り替わる。内側で作られるレコードは `organization_id`（`with_tenant` 由来）も `user_id`（引数由来）も侵入先 org のもので**整合する**ため、複合 FK `[organization_id, user_id] → users` も model 検証 `user_must_belong_to_same_organization` も**通過する**。二層防御が両層とも素通りする。
- **WHY:** `with_tenant` は「現在の文脈と一致するか」を検証せず、引数のテナントへ無条件に切り替える。§3.6 の二層防御は「`organization_id` が現在のテナントから来る」ことを暗黙の前提にしており、その前提を service 自身が壊す。読み取り専用の利用（`ClosingLock`・`CompanyCalendarResolver`）では無害だが、**書き込み service では「その service 自身がテナント境界になれない」**ことを意味する。
- **HOW:** 書き込み service は `with_tenant` へ入る**前**に、操作者（actor）と対象（target）の `organization_id` 一致を独立に検証する（`Absences::Confirm#guard_actor_same_organization!`）。controller の `policy_scope` が一次防衛だが、service 単体でも fail-closed に倒すこと。「複合 FK が最終防衛」と書かれたコメントを、`with_tenant` で自己ラップする service に対して信用しない。
- verified: Rails 8.1.3 / 2026-07-09（4-2c-2 の tenant-isolation レビューで検出。実害到達経路は controller の `policy_scope(User)` と `warden_tenant_guard` により塞がれていたが、service 単体では素通りだった）
```

**（2）ActiveRecord association セクションへ:**

```markdown
### `rescue RecordInvalid` で「並行レース」を吸収したつもりが本物の検証失敗を握り潰す（4-2c-2・verified 2026-07-09）

- **WHAT:** per-day savepoint の `rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid` に「並行 clock_in が同日 AR を先に作った等」というコメントを付けて skip 扱いにしていたが、`AttendanceRecord` は**同日 uniqueness のモデル検証を意図的に置いていない**（一次防衛は unique index）。したがってその競合は**必ず `RecordNotUnique`** で来る。`RecordInvalid` の arm が拾うのは越境検証・毒入力・監査行の不備といった**本物の失敗のみ**で、それが「既に勤怠記録があるためスキップしました」という事実と異なる flash に化け、ログにも残らなかった。
- **WHY:** 「レースを吸収する」意図で例外クラスを 2 つ並べると、片方が実際には別の意味を持つことに気付けない。モデルに uniqueness 検証があるかどうかで `RecordNotUnique` / `RecordInvalid` のどちらが飛ぶかが変わるため、**モデル側の検証方針を読まずに rescue の広さを決めてはならない**。
- **HOW:** rescue する例外は「その経路で実際に飛び得るもの」だけに絞る。`RecordNotUnique` = DB unique index の競合（吸収してよい）／`RecordInvalid` = model 検証の失敗（ログ + `Rails.error.report` して再 raise・fail-closed）。既存の正しい idiom は `HolidayWorkRequests::ApplyApproval#lock_or_create_balance`（`e.record.errors.details[:x]` で `:taken` 由来のみを握り潰し、他は再 raise）。
- verified: Rails 8.1.3 / 2026-07-09（4-2c-2 で tenant-isolation と approval-engine の 2 レビュアーが独立に検出）
```

**（3）テスト / 検証プロセス セクションへ:**

```markdown
### zsh では `cmd $FILES` が単語分割されず、rubocop は「0 files inspected」で緑を返す（4-2c-2・verified 2026-07-09）

- **WHAT:** `FILES=$(git diff --name-only main...HEAD | grep '\.rb$' | tr '\n' ' ')` の後に `bundle exec rubocop --force-exclusion $FILES` と書くと、rubocop は `Inspecting 0 files` / `no offenses detected` と表示して **exit 0（緑）** を返す。実際には 1 ファイルも検査していない。
- **WHY:** zsh は既定で `SH_WORD_SPLIT` が off であり、unquoted な変数展開を単語分割しない（bash とここが違う）。22 個のパスが結合された 1 個の巨大な引数として渡り、rubocop は存在しないパスを黙って無視する。「lint が緑」と「lint が何かを検査した」は別の命題。
- **HOW:** `git diff --name-only main...HEAD | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion` とパイプで渡す（`/preflight` skill の Phase 1 は既にこの形で正しい）。実行結果の `Inspecting N files` の N が期待どおりか毎回確認する。
- verified: zsh 5.9 / rubocop / 2026-07-09（4-2c-2 の仕上げで実踏。`--force-exclusion` を付けても検査対象が 0 なら意味がない）
```

- [ ] **Step 8: Commit**

```bash
git add docs
git commit -m "docs: 4-2c-2 レビュー是正の SPEC/ROADMAP 追従・社労士確認 #22〜#25・RAILS_GOTCHAS 3 件"
```

---

## 仕上げ（全タスク後）

1. **全スイート + 静的検証**:
   - `bundle exec rspec`（全緑・既存 pending は Approvals 自己承認 #2 のみ）
   - `git diff --name-only main...HEAD | grep '\.rb$' | xargs bundle exec rubocop --force-exclusion`（**`Inspecting N files` の N を確認**）
   - `bin/brakeman --no-pager`（0 warnings）
   - `bin/bundler-audit check --update`（chore PR #36 が main に入った後に rebase して再確認）
2. **マージ前レビュアー（再実行・実 diff から導出）**: `tenant-isolation-reviewer` / `approval-engine-reviewer`（`ApplyApproval`・`Withdraw`・`AttendanceHistory` に触れる）/ `labor-law-compliance-reviewer` + `/legal-citation-audit`
3. **whole-branch review**（最も能力の高いモデル）
4. **§1.4 到達性 DoD**: GlobalNav →「欠勤確定」→ 候補一覧 → 確定 → 本人にベル + メール通知、が一周することを手で確認
5. **PR**: ROADMAP の該当行更新を含めてから squash マージ

## Self-Review（writing-plans 規約）

**1. 指摘のカバレッジ**: 冒頭の対応表が 3 レビュアーの Critical 2 件と Warning 群を R1〜R6 に全数マッピングしている。backlog 送りにしたもの（hr_admin 自己却下・実労働判明時の是正・`investigating`・締めの行ロック）は R6 Step 5 で ROADMAP に、社労士確認は R6 Step 6 で #22〜#25 として明示的に記録する（黙って落とさない）。

**2. Placeholder scan**: 全ステップに実コードを記載。`<ts>` は generate が確定。既存 spec の `let` / ヘルパ名に合わせる指示は「既存を読んで合わせよ」と具体化した（丸投げしていない）。

**3. Type consistency**:
- `attendance_histories.absence_reason`（integer・`AttendanceRecord.absence_reasons` と同一マッピング）を R2 で導入し、`Confirm#confirm_one`・`ApplyApproval#record_absence_to_paid`・`Withdraw#restore_absence` の 3 writer と `Withdraw#absence_to_paid_history` の 1 reader が共有 — 一致。
- `Absences::GracePeriod#deadline(notified_on) → TimeWithZone | nil` / `#elapsed?(notified_on, now) → Boolean`（R4）を `Confirm#guard_grace_period!`・`Detect#deadline_text`・controller/view が消費 — 一致。
- `AttendanceRecord.absence_reason_note` は R2 Step 8 で**削除**し、呼び出し元 2 箇所（`confirm.rb` / `apply_approval.rb`）を同タスク内で構造化に置換 — 参照残りなし（Step 8 の grep で確認）。
- `record_absence_to_paid(record, date, previous_absence_reason, previous_note)` の 4 引数版（R2）は呼び出し元 1 箇所を同時更新 — 一致。

**4. 依存順**: R1（独立・最小）→ R2（migration + 監査構造化 + Withdraw。`absence_reason_note` を消すので R3/R4 より先）→ R3（Confirm のガードと rescue）→ R4（GracePeriod 抽出。R3 が触った `guard_grace_period!` を差し替える）→ R5（spec のみ）→ R6（docs）。R2 → R3 → R4 は同一ファイル（`confirm.rb`）を順に触るため**並列実行しないこと**。

**5. 判別性のあるテスト**:
- R1: `not_to include("Translation missing")` — i18n を戻すと落ちる
- R2: 「absent 由来でない AR は従来どおり destroy される」で復元条件の過剰適用を検出。`previous_status` を `update!` 後に読むと 2 例目が落ちる（capture-before-assign の罠）
- R3: 3rd-write テストが `raise_error` を期待するよう反転 — `RecordInvalid` を skip に握り潰す実装だと落ちる。actor 組織ガードのテストは `with_tenant` の内側に置くと（昇格して）通ってしまうため、ガードが `call` 冒頭にあることを間接的に固定する
- R4: メモ化テストが `expect(CompanyCalendar).not_to receive(:where)` で N+1 の再発を検出
- R5: `without_tenant` で包むことで、policy から `organization_id` を消すと落ちるようになる（現状は落ちない）
