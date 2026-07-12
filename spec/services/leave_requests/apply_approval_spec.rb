# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::ApplyApproval do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org) }
  let(:paid_type) { create(:leave_type, system_type: :annual, paid_leave: true) }
  let(:unpaid_type) { create(:leave_type, system_type: :other, paid_leave: false, allow_half_day: true) }

  # start_date の年度（決算月に依らず robust に算出）
  let(:start_date) { Date.new(2026, 5, 1) }   # 金曜（fallback weekday）
  let(:fiscal_year) { org.fiscal_year_for(start_date) }

  def leave(type:, sd: start_date, ed: start_date, half: :none, days: 1)
    create(:leave_request, requester: user, leave_type: type,
           start_date: sd, end_date: ed, half_day_type: half, days_requested: days)
  end

  def apply(lr) = described_class.call(leave_request: lr, acting_user: approver)

  describe "残高加算（paid・§4.10 ハード拒否）" do
    it "paid 種別は used_days に days_requested を加算" do
      balance = create(:leave_balance, user:, leave_type: paid_type,
                       fiscal_year:, granted_days: 20, used_days: 3)
      apply(leave(type: paid_type, days: 1))
      expect(balance.reload.used_days).to eq(BigDecimal("4"))
    end

    it "残高超過は OverBalanceError で拒否し used_days を変えない" do
      balance = create(:leave_balance, user:, leave_type: paid_type,
                       fiscal_year:, granted_days: 5, carry_over_days: 0, used_days: 5)
      expect { apply(leave(type: paid_type, days: 1)) }
        .to raise_error(Approvals::OverBalanceError)
      expect(balance.reload.used_days).to eq(BigDecimal("5"))
    end

    it "残高行が無い paid 種別は over-balance（available=0）" do
      expect { apply(leave(type: paid_type, days: 1)) }
        .to raise_error(Approvals::OverBalanceError)
    end

    it "非 paid 種別は残高を一切触らない（balance 行が無くても成功）" do
      expect { apply(leave(type: unpaid_type, days: 1)) }.not_to raise_error
    end

    it "over-balance では AR も history も作られない（残高→AR→history の順序契約を固定）" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, granted_days: 0, used_days: 0)
      expect { apply(leave(type: paid_type, days: 1)) }.to raise_error(Approvals::OverBalanceError)
      expect(AttendanceRecord.count).to eq(0)
      expect(AttendanceHistory.count).to eq(0)
    end
  end

  describe "AttendanceRecord upsert（§13.1 の 2-2b 担当遷移）" do
    it "全休は計上日ごとに on_leave AR を作成（打刻無・calc NULL）" do
      apply(leave(type: unpaid_type, days: 1))   # 2026-05-01（金）単日
      record = AttendanceRecord.find_by(user:, work_date: start_date)
      expect(record).to have_attributes(status: "on_leave", clock_in: nil)
      expect(record.actual_work_hours).to be_nil
    end

    it "除外日（土日）には AR を作らない" do
      # 2026-05-01(金)〜2026-05-04(月): 土(2)/日(3) 除外、金・月のみ計上
      apply(leave(type: unpaid_type, sd: Date.new(2026, 5, 1), ed: Date.new(2026, 5, 4), days: 2))
      expect(AttendanceRecord.where(user:).pluck(:work_date))
        .to contain_exactly(Date.new(2026, 5, 1), Date.new(2026, 5, 4))
    end

    it "月跨ぎは各 AR が自分の月の work_date を持つ" do
      # 2026-05-29(金)〜2026-06-01(月): 5/29 金・6/1 月が計上（5/30 土・5/31 日 除外）
      apply(leave(type: unpaid_type, sd: Date.new(2026, 5, 29), ed: Date.new(2026, 6, 1), days: 2))
      dates = AttendanceRecord.where(user:).pluck(:work_date)
      expect(dates).to contain_exactly(Date.new(2026, 5, 29), Date.new(2026, 6, 1))
    end

    it "打刻済（clocked_out）の日に午前半休が承認されると status 更新 + 遅刻免除" do
      pattern = create(:work_pattern, start_time: "09:00", end_time: "18:00", break_minutes: 60)
      existing = create(:attendance_record, user:, work_pattern: pattern, status: :clocked_out,
                        work_date: start_date,
                        clock_in: Time.utc(2026, 5, 1, 1),    # JST 10:00（本来遅刻）
                        clock_out: Time.utc(2026, 5, 1, 9))   # JST 18:00
      apply(leave(type: unpaid_type, half: :morning))
      expect(existing.reload).to have_attributes(status: "morning_half", is_late: false)
    end

    it "AttendanceHistory(leave_approved) を actor=承認者・source=申請で 1 行記録" do
      expect { apply(leave(type: unpaid_type, days: 1)) }
        .to change { AttendanceHistory.where(event_type: :leave_approved).count }.by(1)
      history = AttendanceHistory.find_by(event_type: :leave_approved)
      expect(history).to have_attributes(actor_id: approver.id, source: have_attributes(id: anything),
                                         user_id: user.id)
    end
  end

  describe "代休 LeaveRequest 消費（D2 一般化）" do
    let(:org) { create(:organization) }
    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
    let(:user) { create(:user, organization: org) }
    let(:approver) { create(:user, :manager_role, organization: org) }
    let(:comp) { create(:leave_type, system_type: :compensatory_leave, paid_leave: false, organization: org) }
    let(:fy) { org.fiscal_year_for(Date.new(2026, 6, 7)) }

    def consume(days:, start_date: Date.new(2026, 6, 7))
      lr = create(:leave_request, organization: org, requester: user, leave_type: comp,
                                  start_date:, end_date: start_date, days_requested: days,
                                  approval_status: :approved)
      described_class.call(leave_request: lr, acting_user: approver)
    end

    it "残高ありで取得すると used_days が減算される" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 2)
      consume(days: 1)
      expect(LeaveBalance.find_by(user:, leave_type: comp, fiscal_year: fy).used_days).to eq(1)
    end

    it "残高超過は OverBalanceError + used_days 不変 + AR/history 未作成" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 1)
      expect { consume(days: 2) }.to raise_error(Approvals::OverBalanceError)
      bal = LeaveBalance.find_by(user:, leave_type: comp, fiscal_year: fy)
      expect(bal.used_days).to eq(0)
      expect(AttendanceRecord.where(user:, work_date: Date.new(2026, 6, 7))).to be_empty
    end

    it "境界（消費 == 残高）は成功" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 1)
      expect { consume(days: 1) }.not_to raise_error
    end

    it "代休 LeaveBalance は carry_over_days=0 を維持（繰越対象外・R8）" do
      create(:leave_balance, organization: org, user:, leave_type: comp, fiscal_year: fy, granted_days: 2)
      consume(days: 1)
      expect(LeaveBalance.find_by(user:, leave_type: comp, fiscal_year: fy).carry_over_days).to eq(0)
    end
  end

  describe "年度跨ぎ（§6.2 start_date 年度に統一）" do
    it "start_date の年度の残高にのみ加算する" do
      # 3月決算（4月開始）想定でも robust に: start_date 年度の残高だけ動く
      fy_start = org.fiscal_year_for(Date.new(2026, 5, 1))
      this_year = create(:leave_balance, user:, leave_type: paid_type, fiscal_year: fy_start,
                         granted_days: 20, used_days: 0)
      apply(leave(type: paid_type, sd: Date.new(2026, 5, 1), ed: Date.new(2026, 5, 1), days: 1))
      expect(this_year.reload.used_days).to eq(BigDecimal("1"))
    end
  end

  describe "leave_type_id の AR 焼き込み（3-3a）" do
    it "paid 種別: 作成する休暇 AR に leave_type_id を set" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, granted_days: 20, used_days: 0)
      apply(leave(type: paid_type, days: 1))
      rec = AttendanceRecord.find_by(user:, work_date: start_date)
      expect(rec.leave_type_id).to eq(paid_type.id)
    end

    it "非 paid 種別でも leave_type_id を set" do
      apply(leave(type: unpaid_type, days: 1))
      rec = AttendanceRecord.find_by(user:, work_date: start_date)
      expect(rec.leave_type_id).to eq(unpaid_type.id)
    end
  end

  describe "absent→on_leave 事後有給の上書き（§11①/§12②⑥）" do
    it "既存 absent AR を覆う承認は on_leave へ昇格し absence_reason をクリア（RecordInvalid を起こさない）" do
      create(:attendance_record, user:, work_date: start_date, status: :absent,
                                 absence_reason: :unauthorized, clock_in: nil, note: "調査中")

      expect { apply(leave(type: unpaid_type, sd: start_date, ed: start_date)) }.not_to raise_error

      ar = AttendanceRecord.find_by(user_id: user.id, work_date: start_date)
      expect(ar.status).to eq("on_leave")
      expect(ar.absence_reason).to be_nil
      expect(ar.note).to be_nil
    end

    it "absent→on_leave 時に AttendanceHistory(absence_to_paid) を previous_status: absent で記録" do
      create(:attendance_record, user:, work_date: start_date, status: :absent,
                                 absence_reason: :illness, clock_in: nil)

      apply(leave(type: unpaid_type, sd: start_date, ed: start_date))

      h = AttendanceHistory.find_by(user_id: user.id, event_type: :absence_to_paid, event_date: start_date)
      expect(h).to be_present
      expect(h.actor_id).to eq(approver.id)
      expect(h.previous_status).to eq(AttendanceRecord.statuses[:absent])
      expect(h.new_status).to eq(AttendanceRecord.statuses[:on_leave])
    end

    it "absent でない日（新規 on_leave 作成）は absence_to_paid を記録しない" do
      apply(leave(type: unpaid_type, sd: start_date, ed: start_date))

      expect(AttendanceHistory.where(event_type: :absence_to_paid).count).to eq(0)
    end

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

    it "absent でない日の on_leave 作成では absence_to_paid を記録しない（note も生えない）" do
      apply(leave(type: unpaid_type, sd: start_date, ed: start_date))
      expect(AttendanceHistory.where(event_type: :absence_to_paid)).not_to exist
    end
  end

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

    describe "並行（2 接続・FOR UPDATE でシリアライズ）" do
      include ConcurrencyHelpers
      self.use_transactional_tests = false

      # 外側の around { with_tenant(org) } はこのネストでは未使用だが、use_transactional_tests
      # = false 下では org 生成が commit される。after フックが正常に完走すれば下記の理由で
      # 毎回きれいに消えるが、途中で process が落ちる等 after 自体が走らない事態への保険として
      # 連番 subdomain を避け、次回実行時の衝突要因を作らないようにしておく。
      let(:org) { create(:organization, subdomain: "aa-lock-unused-#{SecureRandom.hex(4)}") }

      # ApplyApproval は実処理として必ず AttendanceHistory（§4.14 追記専用）を書く。これを
      # 素の truncate_all_tables!（DELETE 総当たり）だけで片付けようとすると、attendance_histories
      # 自体が削除不能なため、それを参照する organizations/users も巻き添えで永久に残り、
      # 連番 subdomain の他 spec と衝突し得る（実測: 別 spec の let(:org) が同じ連番で偽 FAIL した）。
      #
      # 本テストが書く attendance_histories 行はこの example 専用のテスト用データで法的保存対象
      # ではない（§4.14 の対象は本番データ）。1 つの transaction 内で
      # DISABLE TRIGGER → DELETE → ENABLE TRIGGER を行い、成功時のみ commit する。例外発生時は
      # transaction 全体が ROLLBACK され、DISABLE も含めて巻き戻る（DDL も transactional）ため、
      # 「無効化したまま残る」（docs/RAILS_GOTCHAS.md 187〜191 行の危険パターン）は起こらない。
      # 接続断（kill 等）で COMMIT に到達しなかった場合も同様に未コミットのまま破棄される。
      # これにより organizations/users/attendance_histories を含め毎回完全にクリーンな状態へ戻る
      # （実測: 3 回連続実行 + concurrency_helpers_spec.rb との同時実行で残留 0 件・disabled trigger 0 件を確認）。
      after do
        Organization.where(id: ActsAsTenant.test_tenant&.id).delete_all

        conn = ActiveRecord::Base.connection
        conn.transaction do
          conn.execute("ALTER TABLE attendance_histories DISABLE TRIGGER attendance_histories_no_mutate")
          conn.execute("DELETE FROM attendance_histories")
          conn.execute("ALTER TABLE attendance_histories ENABLE TRIGGER attendance_histories_no_mutate")
        end

        truncate_all_tables!
      end

      # brief 記載の `hold_row_lock(...) { AttendanceRecord.where(id: rec.id).delete_all }` は
      # 採用しない。hold_row_lock は「yield が返ってから release する」設計（yield 中はロック保持・
      # release は ensure で yield 復帰後）だが、その yield 自身が同じ行への delete_all だと
      # Postgres の行ロック待ちに入り、それを解く release は yield 復帰後にしか実行されない
      # ため自己デッドロックする（実測: 5 分ハングで kill。Task 1 自身の
      # concurrency_helpers_spec.rb 内 "#hold_row_lock" では同じ delete_all を SET
      # lock_timeout = '300ms' 付きで LockWaitTimeout を期待しており、素の delete_all が
      # 無期限に待つことを自ら証明している）。
      #
      # 代わりに、削除側（deleter）・承認側（approver）を別スレッド・別接続で真に並行実行する。
      # deleter は delete_all を投げた直後に自分の transaction を意図的に一定時間開いたまま保持し、
      # approver（ApplyApproval.call）がその間にロック待ちへ入るのを待ってから commit する。
      # 修正前: find_or_initialize_by の SELECT は素の SELECT（READ COMMITTED 下では
      #   deleter の未コミット DELETE をブロックせず素通りし、削除前の行を「まだある」と誤認する）
      #   → 後続の save! が実 UPDATE を発行する段になって初めて deleter の行ロックを待つ
      #   → deleter が commit（行が実際に消える）→ UPDATE は 0 行に成功し AR は復活しない（RAILS_GOTCHAS）。
      # 修正後: lock.find_by 自体が SELECT ... FOR UPDATE として deleter の行ロックを待ち、
      #   commit 後は行が無いため nil に解決 → 新規 INSERT に落ちる。
      it "別 tx が保持する AR ロックを承認が待ち、修正版は 0 行 UPDATE を踏まない" do
        # subdomain は固定値にしない。org2 は AttendanceHistory から参照され truncate 不能で
        # 恒久的に test DB へ残るため、固定値だと次回実行時に一意制約衝突する（実測済み）。
        org2 = create(:organization, subdomain: "aa-lock-#{SecureRandom.hex(4)}")
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

        locked = Queue.new

        deleter = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ActsAsTenant.with_tenant(org2) do
              AttendanceRecord.transaction do
                AttendanceRecord.where(id: rec.id).delete_all
                locked << :ok
                sleep 0.3 # 未コミットのまま保持し、approver がロック待ちへ入る猶予を作る
              end
            end
          end
        end

        locked.pop # delete_all が発行済み（未コミット）になるまで待つ

        approver = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            ActsAsTenant.with_tenant(org2) do
              LeaveRequests::ApplyApproval.call(leave_request: lr, acting_user: mgr)
            end
          end
        end

        deleter.join
        approver.join

        ActsAsTenant.with_tenant(org2) do
          rows = AttendanceRecord.where(user_id: u.id, work_date: Date.new(2026, 5, 1))
          expect(rows.count).to eq(1)
          expect(rows.first).to be_on_leave
          expect(bal.reload.used_days).to eq(BigDecimal("1"))
        end
      end
    end
  end
end
