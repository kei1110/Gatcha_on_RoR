# Phase 4-2c-3 欠勤確定の取消 — 設計

作成: 2026-07-10 ／ 対象: SPEC §6.10・§4.14・§13.1 ／ 前提スライス: 4-2c-1（PR #32）・4-2c-2（PR #37）

**2 サブ PR に分割する。**

| サブ PR | 内容 | 位置づけ |
|---|---|---|
| **4-2c-3a** | `AttendanceRecord` の read-modify-write を行ロックで直列化する共通規約 | **merge blocker**（取消を作らなくても既存の dormant バグを閉じる） |
| **4-2c-3b** | 欠勤確定の取消 UI ＋ 却下(dismiss) の監査行 | 本体 |

---

## 1. 背景

4-2c-2（PR #37）は欠勤確定に **8 つのガード（入口）** を置いたが、確定を取り消す**出口をひとつも作らなかった**。確定は賃金控除に直結するため、これは「アプリ内で取り消せない不利益記録」を意味する。labor-law レビュアーの merge 条件により、4-2c-3 は **Phase 4-2 の完了条件**へ昇格している（ROADMAP・LABOR_LAW_REVIEW_NOTES #23）。

誤確定後の是正経路は現状すべて塞がっている:

- 打刻変更申請（CCR）— `absent` AR は打刻列が nil ゆえ `target_record_clocked_out` を満たさず、`new_entry` は #48 で拒否
- 代理打刻 — 当日限定
- 事後の有給申請 — 年休残高を消費し、残高不足なら `OverBalanceError` で経路が消滅

したがって取消そのものを実装する以外に出口がない。

## 2. 決定事項

| # | 論点 | 決定 | 根拠 |
|---|---|---|---|
| D1 | 取消後の `AbsenceCandidate` | `notified_on: nil` で作り直す（**ベストエフォート**） | 取消しても「その日が未説明」である事実は変わらない。`Detect#process_candidates` が既存候補を全件走査し、`covered?` なら destroy・`notified_on` が nil なら再通知して猶予を再起算する既存機械にそのまま乗る。ただし §7-a の限界あり |
| D2 | スコープ | 却下(dismiss) の監査行を同梱する | 候補を復活させると「取消 → 候補復活 → 却下」で痕跡ゼロの完全消去が可能になる。自己取消の禁止では塞げない（確定前に候補を却下すれば同じ結果） |
| D3 | UI | `/absence_confirmations#index` に「確定済み欠勤」セクションを追加し `POST /absence_cancellations` へ送る | ナビを増やさず、誤確定の直後に同じ画面で戻せる。`DELETE /absence_confirmations/:id` は既に候補の却下が使っており `:id` の型が衝突する |
| D4 | 理由 | 取消は `note` **必須**・却下は任意 | 取消は賃金控除を消す唯一の出口で低頻度・不正の動機がある。却下は大量かつ定型（非常勤の非所定日）で、必須化するとコピペされた同一文字列が並び情報量がゼロに収束する |
| D5 | 分割 | 行ロックを 4-2c-3a として先に出す | 取消を作らなくても `Withdraw` branch ④ との間に dormant バグが実在する。承認パスへの diff を分離すると approval-engine-reviewer の射程が絞れる |

## 3. 4-2c-3a — `AttendanceRecord` の行ロック規約

### 3.1 塞ぐ穴

`LeaveRequests::ApplyApproval#upsert_attendance_records` は **ロックなし SELECT → UPDATE** の read-modify-write である（`apply_approval.rb:51-63`）。

```ruby
record = AttendanceRecord.find_or_initialize_by(user_id:, work_date: date)  # ロックなし
was_absent = record.absent?
record.status = leave_status
record.save!                                                                 # UPDATE
```

READ COMMITTED では、この SELECT と UPDATE の間に**別トランザクションが同じ行を DELETE して commit できる**。そのとき UPDATE は 0 行を更新するが、`attendance_records` に `lock_version` 列が無いため **Rails は例外を上げず `save!` が `true` を返す**（実測で確認）。

結果、承認は以下を確定させる:

- `LeaveRequest`: `approved`
- `LeaveBalance`: 消費済み
- `AttendanceHistory`: `absence_to_paid`（`previous_status = absent`）
- `AttendanceRecord`: **存在しない**

台帳・残高・監査が三者三様に分離する。

**この穴は取消を作る前から存在する。** `LeaveRequests::Withdraw` の branch ④（`record.destroy!`）が DELETE 側になり得るためである（`withdraw.rb`）。取消は、同じ穴を管理者のボタン 1 つに昇格させるにすぎない。

### 3.2 修正

`AttendanceRecord` の既存行を read-modify-write する箇所は、**必ず行ロックを取ってから読む**。

```ruby
# ApplyApproval#upsert_attendance_records
record = AttendanceRecord.lock.find_by(user_id: @leave_request.requester_id, work_date: date) ||
         AttendanceRecord.new(user_id: @leave_request.requester_id, work_date: date)
```

`SELECT ... FOR UPDATE` は、削除済み行に対して READ COMMITTED で **0 行を返す**。よって `find_by` が nil になり `AttendanceRecord.new` の INSERT 経路へ落ちる。0 行 UPDATE は構造的に到達不能になる。

`LeaveRequests::Withdraw#restore_attendance_records` も `find_each` で読んだ AR を分岐判定に使うため、分岐前に `record.lock!` を挟む（ロック後に `clock_in` / status を読み直す）。

### 3.3 ロック順序（デッドロック検査）

| service | 取得順 |
|---|---|
| `Approvals::Approve` → `ApplyApproval` | approval 行 → `LeaveBalance` 行 → `AttendanceRecord` 行 |
| `LeaveRequests::Withdraw` | `LeaveBalance` 行 → `AttendanceRecord` 行 |
| `Absences::Cancel`（3b） | `AttendanceRecord` 行のみ |

**モデル間順序:** `AttendanceRecord` は常に最後に取る。`Cancel` は `LeaveBalance` を取らない。よってモデル間の循環待ちは生じない。

**同一テーブル内順序（4-2c-3a Task 3 レビューで補強）:** 上表はモデル間順序を揃えるだけで、**同一トランザクションが複数の `AttendanceRecord` 行を掴む順序**までは規定していなかった。`ApplyApproval#upsert_attendance_records` は `counted_dates`（`day_classifications` の `(from..to).index_with` 由来＝**work_date 昇順**）でロックし、`Withdraw#restore_attendance_records` は当初 `find_each`（**id 昇順**）だった。`AttendanceRecord` は `[user_id, work_date]` が unique だが、branch④ の `destroy!` → 後日の再作成で「早い日付の行が大きい id」になり得るため、id 順と work_date 順は逆転し得る。同一ユーザーの重複する休暇期間を `ApplyApproval` と `Withdraw` が同時処理すると、2 行を逆順に掴んで循環待ち（`ActiveRecord::Deadlocked`・データ破損はしないが想定外エラー）になる余地があった。**規約: 同一ユーザーの複数 `AttendanceRecord` 行を掴む処理はすべて work_date 昇順でロックする**（`Withdraw` は `find_each` → `order(:work_date).each` へ・`ApplyApproval` は既に work_date 昇順・`Cancel`(3b) も 1 日 1 行だが複数日を扱うなら work_date 昇順に従う）。

### 3.4 テスト（足場を実測済み・2026-07-10）

このリポジトリに並行テストの前例は無いため足場から作る。ただし**バグの証明と修正の証明では必要な足場が違う**（RAILS_GOTCHAS 追記済み）。

**(a) バグの証明 — 1 接続・スレッド不要。** 「消えた行への read-modify-write」は SQL と Rails の性質であって並行性の性質ではない。

```ruby
rec = create(:attendance_record, ...)
AttendanceRecord.where(id: rec.id).delete_all   # stale read の後に行が消える
rec.status = :clocked_out
expect(rec.save!).to be(true)                   # ← 0 行 UPDATE を黙認する（実測で確認）
```

これは既存の `spec/services/holiday_work_requests/apply_approval_spec.rb` の流儀（読み取りだけを過去に置き、下流は実挙動を走らせる）と同型。

**(b) 修正の証明 — 2 接続が要る。** `SELECT ... FOR UPDATE` の効果は「他 tx を待たせること」で、待ち手のいない 1 接続では観測できない。

- 対象 example group に `self.use_transactional_tests = false`
- 保持スレッドは `ActiveRecord::Base.connection_pool.with_connection` で自前の接続を取る
- **`ActsAsTenant.test_tenant` は `Thread.current` 局所**なのでスレッド内で改めて `with_tenant(org)` で包む
- 待ちは sleep で測らず `SET lock_timeout = '300ms'` を撃ち `ActiveRecord::LockWaitTimeout` を期待する（決定的になる）
- 後片付けに **`connection.truncate_tables` / `TRUNCATE` を使わない**（前者は失敗時に FK と追記専用トリガーを無効のまま残す・後者は `attendance_histories` の `BEFORE TRUNCATE` トリガーに無条件で阻まれる）。`spec/support/concurrency_helpers.rb#truncate_all_tables!` の **DELETE 総当たり**を使う（Task 1 実装で判明・RAILS_GOTCHAS）
- `config/database.yml` の `max_connections: 5` でスレッド 2 本は収まる

**修正前が本当に落ちることを確認してから修正を入れる**（非判別テストにしない）。

## 4. 4-2c-3b — 取消と却下

### 4.1 `Absences::Cancel`

```ruby
guard_actor_same_organization!            # ① with_tenant の外（昇格前・Confirm 同型）
ActsAsTenant.with_tenant(organization) do
  guard_note!                             # ② 取消理由 presence
  guard_record_belongs_to_target!         # ③ 呼び出し元の契約違反を write 前に拒否
  ActiveRecord::Base.transaction do
    guard_closing!                        # ④ MonthlySummaries::ClosingLock（tx 内・§7-c の限界あり）
    record.with_lock do                   # FOR UPDATE で掴み直す
      guard_still_absent!                 # ⑤ ロック後に status 再判定（絶対に外せない）
      previous_reason = record.absence_reason        # capture-before-destroy
      AttendanceHistory.create!(user:, actor:, event_type: :absence_canceled,
                                event_date: record.work_date,
                                previous_status: AttendanceRecord.statuses[:absent],
                                new_status: nil,
                                absence_reason: previous_reason, note: cancel_note)
      record.destroy!
      AbsenceCandidate.create!(user:, target_date: record.work_date, notified_on: nil)
    end
  end
end
```

**⑤ を `with_lock` の内側に置くのが要点。** 外に置くと、読んだ status と削除する行の status が別物になり得る（事後有給の承認が `absent → on_leave` へ書き換える）。承認済みの有給休暇日を取消が destroy する事故は、これでのみ防げる。

`Confirm` の 8 ガードのうち **②毒入力・③候補実在・⑤弁明の行使・⑥未通知・⑦猶予**は取消では意味が反転するため、共有せず別 service にする。

### 4.2 競合の落ち方

| 競合 | 例外 | 応答 |
|---|---|---|
| 管理者 2 人が同時に取消 | 2 人目の `with_lock` の reload が行を掴めず `ActiveRecord::RecordNotFound` | 422「他の操作で既に取り消されています」 |
| 取消中に事後有給が承認 | `guard_still_absent!` が `on_leave` を検出 | 422「既に有給休暇へ振り替えられています」 |
| CCR が AR を参照（#48 解禁後） | `destroy!` が `ActiveRecord::InvalidForeignKey` | 422（fail-closed） |

`AbsenceCandidate` の unique index は競合検出器**ではない** — 2 人目は `create!` まで到達しない。unique index は backstop にとどまる。

### 4.3 `Absences::Dismiss`

現行 controller の `candidate.destroy!`（`absence_confirmations_controller.rb:33-39`）を service へ移し、**1 トランザクションで** `AttendanceHistory(absence_dismissed)` の append と束ねる。分離すると「候補だけ消えて履歴なし」または「却下履歴だけあって候補が残る」状態が生じる。

### 4.4 データモデル変更（すべて append-only・鉄則 7）

**`AttendanceHistory.event_type`**（§4.14 taxonomy）

| 値 | 名 | `previous_status` | `new_status` | `absence_reason` | `note` |
|---|---|---|---|---|---|
| 11 | `absence_canceled` | `5`（absent） | `nil` | 取り消した欠勤の理由（構造化） | 取消理由（**必須**） |
| 12 | `absence_dismissed` | `nil` | `nil` | `nil` | 却下理由（任意） |

- `ABSENCE_EVENT_TYPES`（`absence_reason` を許す集合）に `absence_canceled` を**足す**・`absence_dismissed` は**足さない**（候補は理由列を持たない）
- `validates :actor_id, presence: true, if: :absence_canceled?` / `if: :absence_dismissed?` を追加する（既存の event_type ごとの個別追加と同型。追記専用ゆえ create 時の検証が唯一の砦）

**`Notification.source_type`**: `absence_canceled: 8` を append。

### 4.5 通知

取消は本人へ通知する（`priority: :informational`）。既存の「欠勤が確定されました」（`action_required`）を残したまま黙って AR を消すと、本人は取消を知る経路を持たない。

**候補の再生成による再通知はベストエフォートに降格する**（§7-a）。**常に届く経路は取消通知だけ**である。

取消 tx の commit 後に発火し、失敗は rescue + log（§9.5・`notify_confirmed` 同型）。

### 4.6 認可

- role ゲート: `AbsenceCancellationPolicy#create?` = `manager_or_admin?`
- 対象ゲート: `policy_scope(User, policy_scope_class: AbsenceCancellationPolicy::Scope).find(params[:user_id])`
- **`Scope` は `active: true` で絞らない。** `AbsenceConfirmationPolicy::Scope` は候補が `User.active` にしか生えないため `active` を要求するが、取消は過去の確定を直す操作で、対象が退職・無効化済みでも直せなければならない
- 確定済み AR の一覧取得も必ず roster 起点にする（IDOR はここで塞ぐ）

### 4.7 UI

`/absence_confirmations#index` に 2 つ目のセクションを置く。

```
【欠勤候補】               ← 既存
  2026-07-08 山田  [確定][却下]

【確定済み欠勤】           ← 新規
  2026-07-01 佐藤  無届  [取消]
  2026-06-28 鈴木  疾病  [締め済み・取消不可]
```

一覧の範囲は roster × `AttendanceRecord.absent` × 直近 92 日（約 3 締め期間）。締め状態は `MonthlyAttendanceSummary` を 1 クエリで先読みし、メモリで期間ラベルと突き合わせる（N+1 を作らない）。締め済み行は表示するが操作不可（何が確定済みかは見える方が監査上よい）。

## 5. 不変条件 — `LeaveRequests::Withdraw` との相互作用

`Withdraw#unrestored_absence_conversion` は `[absence_to_paid, absence_restored]` の最新を見て `absence_to_paid` なら `absent` へ復元する。

**主張:** ここに `absence_canceled` を足す必要はない。

**根拠（4-2c-3a 適用後にのみ成立する）:** `status: :absent` を書く箇所は app/ 全体でちょうど 2 つ。

1. `Absences::Confirm#confirm_one` — AR が存在しない日にのみ `create!`
2. `LeaveRequests::Withdraw#restore_absence` — 必ず `absence_restored` を同時に書く

したがって「AR が `absent` ⟹ `{absence_to_paid, absence_restored}` の最新は `absence_to_paid` ではない」が帰納的に成立し、`guard_still_absent!` がこれを取消側で使い切る。`absence_to_paid` が最新なのは AR が `on_leave` / 半休のときだけで、そのとき取消は拒否される。

**この帰納法は `ApplyApproval` の read-modify-write が原子的であることに依存する。** 4-2c-3a を適用しない場合、AR が存在しないまま `absence_to_paid` だけが追記される状態が作れ、その後 LR 2 件の承認と撤回を経て、**取り消したはずの欠勤が復活する**（codex レビューが構成した操作列）。

**よって: 死にコードを足すのではなく、この不変条件を固定するテストとコメントを `Withdraw` に置く。**

## 6. レビュアー起動（`git diff main...HEAD --name-only` から導出・CLAUDE.md トリガー表）

| サブ PR | 触れる面 | 起動するレビュアー |
|---|---|---|
| 4-2c-3a | `app/services/leave_requests/`（承認副作用・撤回） | `approval-engine-reviewer` |
| 4-2c-3b | `app/models/`（enum 追加）・`app/services/absences/`・policy・controller | `tenant-isolation-reviewer` ／ `approval-engine-reviewer`（enum 追加・副作用 atomicity） ／ `labor-law-compliance-reviewer` + `/legal-citation-audit`（賃金控除の解除） |

Phase 4-2 の完了条件でもあるため、4-2c-3b の merge 前に `/spec-check` を回す。

## 7. 既知の限界（本設計が閉じないもの・すべて記録する）

**7-a. 事後有給を撤回して `absent` に戻った日を取り消すと、候補は通知される前に消える。**
`Detect#covered?` は `covering_leave_requests` を **status 不問**で判定する（`detect.rb:154-157`）。撤回済み（`withdrawn`）の LR も「覆っている」と見なされるため、再生成した候補は次回バッチで `destroy` される。これは「却下・撤回された休暇申請の日は候補が生まれず v1 では欠勤確定できない」という **SPEC §6.10 の既存の意図的仕様と整合**するが、D1 の狙い（猶予の再起算）はこの経路で成立しない。取消が最も必要になるこじれた日で、ちょうど効かない。**取消通知（§4.5）が唯一常に届く経路である理由がこれ。**

**7-b. `MonthlyAttendanceSummary` の締め TOCTOU。** `ClosingLock#locked?` は `exists?` で summary 行をロックしない（`closing_lock.rb:17-22`）。tx 内で撃っても、判定と write の間に締めが commit する窓は閉じない。**`confirm.rb:126-139` のコメントはこの保証を主張しているが成立していない — 本 PR で訂正する。** 完全に閉じるには締め操作と勤怠変更が共通のロック対象を持つ必要があり、`Approvals::Approve#guard!` も同じ窓を持つ（ROADMAP 既記録）。

**7-c. SPEC §4.13（548 行）は `absent_days` 列を記載するが `monthly_attendance_summaries` に該当列が無い。** 既存の SPEC↔schema 乖離。本スライスの外だが `/spec-check` の対象として記録する。

**7-d. 給与 CSV に訂正の通知経路が無い。** 日別 CSV は live な `AttendanceRecord` を直接読むため、締め前でも既に export 済みなら取消は外部給与システムへ伝播しない。

**7-e. `clock_change_requests` → `attendance_records` の複合 FK は RESTRICT。** 今日は `target_record_clocked_out` 検証により CCR が `absent` AR を指せないが、#48（`new_entry` 解禁）の後は `destroy!` が `InvalidForeignKey` になり得る。§4.2 の rescue はその前倒し防衛。

## 8. テスト方針

- **3a**: §3.4 のとおり（a）1 接続でバグを固定、（b）2 接続で FOR UPDATE の待ちを固定
- **3b**: `guard_still_absent!` を消すと落ちるテスト（`with_lock` 内で status が変わる状況を stub で作る）／取消 → 候補再生成 → バッチ通知 → 再確定の往復／却下の履歴と候補 destroy が同一 tx（履歴 `create!` を raise させて候補が残ることを固定）／§5 の不変条件（`absence_to_paid` が最新なら取消は 422）／§7-a の限界（撤回済 LR が覆う日では候補が通知前に消える）を**現状挙動として固定**する
- 監査行の `absence_reason` は**整数**で保存されることを固定（翻訳結果を焼かない・4-2c-2 の教訓）
