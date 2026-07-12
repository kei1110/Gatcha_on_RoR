# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveRequests::Withdraw do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }
  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org) }
  let(:paid_type) { create(:leave_type, system_type: :annual, paid_leave: true, allow_half_day: true) }
  let(:comp_type) { create(:leave_type, system_type: :compensatory_leave, paid_leave: false) }
  let(:unpaid_type) { create(:leave_type, system_type: :other, paid_leave: false, allow_half_day: true) }
  let(:start_date) { Date.new(2026, 5, 1) }   # 金曜
  let(:fiscal_year) { org.fiscal_year_for(start_date) }

  def leave(type:, half: :none, days: 1)
    create(:leave_request, requester: user, leave_type: type, start_date:, end_date: start_date,
           half_day_type: half, days_requested: days, approval_status: :withdrawal_requested, withdrawal_reason: "誤申請")
  end
  def withdraw(lr) = described_class.call(leave_request: lr, acting_user: approver)

  it "paid 撤回で used_days を減算（往復で 0 復帰）" do
    bal = create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, granted_days: 20, used_days: 1)
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    withdraw(leave(type: paid_type, days: 1))
    expect(bal.reload.used_days).to eq(BigDecimal("0"))
  end

  it "代休（compensatory・paid_leave=false）撤回でも減算（R2・balance_tracked?）" do
    bal = create(:leave_balance, user:, leave_type: comp_type, fiscal_year:, granted_days: 5, used_days: 1)
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    withdraw(leave(type: comp_type, days: 1))
    expect(bal.reload.used_days).to eq(BigDecimal("0"))
  end

  it "無打刻 on_leave 日は AR を destroy" do
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    withdraw(leave(type: paid_type, days: 1).tap { create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1) })
    expect(AttendanceRecord.find_by(user:, work_date: start_date)).to be_nil
  end

  it "打刻が残る半休日は clocked_out へ戻し destroy しない（R3）" do
    create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
    rec = create(:attendance_record, :done, user:, work_date: start_date, status: :afternoon_half)
    withdraw(create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                    half_day_type: :afternoon, days_requested: BigDecimal("0.5"),
                    approval_status: :withdrawal_requested, withdrawal_reason: "x"))
    expect(rec.reload.status).to eq("clocked_out")
    expect(rec.clock_in).to be_present
  end

  # 同一日を覆う承認済 LR は複数あり得る（LeaveRequest に重複検証も DB 制約も無い）。
  # 「範囲内 leave-status AR = この休暇の日」という前提が崩れる（4-2c-2 レビュー C1'/C-new）
  describe "同一日を覆う他の休暇申請（重複 LR）" do
    def conversion_history(source:, reason: :illness)
      create(:attendance_history, user:, actor: approver, source:,
                                  event_type: :absence_to_paid, event_date: start_date,
                                  absence_reason: reason,
                                  previous_status: AttendanceRecord.statuses[:absent],
                                  new_status: AttendanceRecord.statuses[:on_leave])
    end

    def live_other_leave
      create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                             half_day_type: :none, days_requested: 1, approval_status: :approved)
    end

    it "他に生きた LR が覆う日の AR は destroy しない（台帳から消えない）" do
      live_other_leave
      create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)

      withdraw(leave(type: unpaid_type))

      record = AttendanceRecord.find_by(user_id: user.id, work_date: start_date)
      expect(record).to be_present
      expect(record.status).to eq("on_leave")
    end

    it "他に生きた LR が覆う日は absent へ復元しない（承認済の休暇日を無届欠勤に化けさせない）" do
      live_other_leave
      record = create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
      lr = leave(type: unpaid_type)
      conversion_history(source: lr)

      withdraw(lr)

      expect(record.reload.status).to eq("on_leave")
      expect(record.absence_reason).to be_nil
      expect(AttendanceHistory.where(event_type: :absence_restored)).not_to exist
    end

    it "自分の absence_to_paid を持たない 2 件目の撤回でも、1 件目の conversion で absent へ復元する" do
      # 2 件目の承認は was_absent=false ゆえ absence_to_paid を書かない。source で絞ると
      # 「自分の履歴が無い＝自分が作った AR」と誤推論して destroy し、欠勤が台帳から消える
      create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
      first_lr = create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                                        half_day_type: :none, days_requested: 1, approval_status: :withdrawn)
      conversion_history(source: first_lr)

      withdraw(leave(type: unpaid_type))

      restored = AttendanceRecord.find_by(user_id: user.id, work_date: start_date)
      expect(restored).to be_present
      expect(restored.status).to eq("absent")
      expect(restored.absence_reason).to eq("illness")
    end

    # LIVE_LEAVE_STATUSES の 2 つの境界判断を固定する（4-2c-2 approval-engine 再レビュー W2）
    it "他の LR が withdrawal_requested でも AR を触らない（副作用は未反転・reject_withdrawal で approved へ戻り得る）" do
      create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                             half_day_type: :none, days_requested: 1,
                             approval_status: :withdrawal_requested, withdrawal_reason: "他の申請")
      create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)

      withdraw(leave(type: unpaid_type))

      record = AttendanceRecord.find_by(user_id: user.id, work_date: start_date)
      expect(record).to be_present
      expect(record.status).to eq("on_leave")
    end

    it "他の LR が applying なら従来どおり destroy する（ApplyApproval 未通過ゆえ AR を所有していない）" do
      # applying を LIVE に含めると、唯一の承認済 LR を撤回した際に分岐①が誤発火し、
      # 承認された休暇が存在しない日に on_leave の AR が残留する
      create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                             half_day_type: :none, days_requested: 1, approval_status: :applying)
      create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)

      withdraw(leave(type: unpaid_type))

      expect(AttendanceRecord.find_by(user_id: user.id, work_date: start_date)).to be_nil
    end

    it "既に absence_restored 済みの日は二重復元せず destroy する（最終状態で判定）" do
      create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
      old_lr = create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                                      half_day_type: :none, days_requested: 1, approval_status: :withdrawn)
      conversion_history(source: old_lr)
      create(:attendance_history, user:, actor: approver, source: old_lr,
                                  event_type: :absence_restored, event_date: start_date,
                                  absence_reason: :illness,
                                  previous_status: AttendanceRecord.statuses[:on_leave],
                                  new_status: AttendanceRecord.statuses[:absent])

      withdraw(leave(type: unpaid_type))

      expect(AttendanceRecord.find_by(user_id: user.id, work_date: start_date)).to be_nil
    end
  end

  describe "テナント境界（with_tenant へ入る前に操作者の組織を検証）" do
    it "操作者が別テナントなら ArgumentError（昇格前に拒否）" do
      other_org = create(:organization, subdomain: "other")
      outsider = ActsAsTenant.with_tenant(other_org) { create(:user, organization: other_org) }
      lr = leave(type: unpaid_type)

      expect { described_class.call(leave_request: lr, acting_user: outsider) }
        .to raise_error(ArgumentError, /組織が一致しません/)
    end
  end

  it "leave_withdrawn 履歴を 1 行記録" do
    create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
    create(:attendance_record, user:, work_date: start_date, status: :on_leave, clock_in: nil)
    expect { withdraw(leave(type: paid_type, days: 1)) }
      .to change { AttendanceHistory.where(event_type: :leave_withdrawn).count }.by(1)
  end

  describe "leave_type_id クリア（3-3a・F3）" do
    it "打刻ありの半休戻しで leave_type_id を nil に戻す" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
      rec = create(:attendance_record, :done, user:, work_date: start_date,
                   status: :afternoon_half, leave_type: paid_type)
      withdraw(create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                      half_day_type: :afternoon, days_requested: BigDecimal("0.5"),
                      approval_status: :withdrawal_requested, withdrawal_reason: "x"))
      rec.reload
      expect(rec.status).to eq("clocked_out")
      expect(rec.leave_type_id).to be_nil
    end

    it "clocked 済日への全休 stale 戻しでも leave_type_id クリア（line-104）" do
      create(:leave_balance, user:, leave_type: paid_type, fiscal_year:, used_days: 1)
      rec = create(:attendance_record, :done, user:, work_date: start_date,
                   status: :on_leave, leave_type: paid_type)
      withdraw(leave(type: paid_type, days: 1))
      rec.reload
      expect(rec.status).to eq("clocked_out")
      expect(rec.leave_type_id).to be_nil
    end
  end

  describe "absent 由来の AR の復元（4-2c-2 レビュー C1）" do
    it "事後有給の撤回で AR を destroy せず absent へ復元し、欠勤理由と自由記述を戻す" do
      record = create(:attendance_record, user:, work_date: start_date, status: :absent,
                                          absence_reason: :other, note: "私用のため", clock_in: nil)
      lr = leave(type: unpaid_type)
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
      lr = leave(type: unpaid_type)
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
      lr = leave(type: unpaid_type)
      LeaveRequests::ApplyApproval.call(leave_request: lr, acting_user: approver)
      expect(AttendanceRecord.find_by(user_id: user.id, work_date: start_date)).to be_present

      described_class.call(leave_request: lr, acting_user: approver)

      expect(AttendanceRecord.find_by(user_id: user.id, work_date: start_date)).to be_nil
      expect(AttendanceHistory.where(event_type: :absence_restored)).not_to exist
    end

    it "半休の事後承認を撤回しても absent へ復元される（復元条件は status でなく absence_to_paid 履歴の実在）" do
      create(:attendance_record, user:, work_date: start_date, status: :absent,
                                 absence_reason: :illness, clock_in: nil)
      lr = leave(type: unpaid_type, half: :morning)
      LeaveRequests::ApplyApproval.call(leave_request: lr, acting_user: approver)
      expect(AttendanceRecord.find_by(user_id: user.id, work_date: start_date).status).to eq("morning_half")

      described_class.call(leave_request: lr, acting_user: approver)

      restored = AttendanceRecord.find_by(user_id: user.id, work_date: start_date)
      expect(restored).to be_present
      expect(restored.status).to eq("absent")
      expect(restored.absence_reason).to eq("illness")

      history = AttendanceHistory.find_by(user_id: user.id, event_type: :absence_restored)
      expect(history.previous_status).to eq(AttendanceRecord.statuses[:morning_half])
    end
  end

  describe "行ロック（4-2c-3a・判定に使う AR を lock! で掴む・2 接続判別）" do
    include ConcurrencyHelpers
    self.use_transactional_tests = false

    # Withdraw は leave_withdrawn（§4.14 追記専用）を書くため truncate では片付かない。
    # Task 2 で集約した purge_append_only_and_truncate! を使う（安全性は helper spec が固定）。
    after { purge_append_only_and_truncate! }

    it "復元対象 AR を別 tx が削除中に撤回すると、lock! が RecordNotFound で fail-closed（0 行 UPDATE を踏まない）" do
      org2 = create(:organization, subdomain: "wd-lock-#{SecureRandom.hex(4)}")
      u = mgr = ptype = rec = lr = nil
      ActsAsTenant.with_tenant(org2) do
        mgr   = create(:user, :manager_role)
        u     = create(:user)
        ptype = create(:leave_type, system_type: :annual, paid_leave: true)
        create(:leave_balance, user: u, leave_type: ptype,
               fiscal_year: org2.fiscal_year_for(Date.new(2026, 5, 1)), granted_days: 20, used_days: 1)
        # branch ②: 実打刻のある on_leave 日
        rec = create(:attendance_record, user: u, work_date: Date.new(2026, 5, 1),
                     status: :on_leave, leave_type: ptype,
                     clock_in: Time.utc(2026, 5, 1, 0), clock_out: Time.utc(2026, 5, 1, 9))
        lr  = create(:leave_request, requester: u, leave_type: ptype,
                     start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 1),
                     half_day_type: :none, days_requested: 1,
                     approval_status: :withdrawal_requested, withdrawal_reason: "誤申請")
      end

      locked = Queue.new
      deleter = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActsAsTenant.with_tenant(org2) do
            AttendanceRecord.transaction do
              AttendanceRecord.where(id: rec.id).delete_all
              locked << :ok
              sleep 0.3 # 未コミットのまま保持し、Withdraw の lock! をロック待ちへ入れる
            end
          end
        end
      end
      locked.pop

      # 修正後: restore_attendance_records の record.lock! が deleter のロックを待ち、
      #   deleter commit 後は行が無いため RecordNotFound（Withdraw は Approve の with_lock 内で
      #   走る前提ゆえ、例外伝播で撤回承認ごと atomic rollback＝fail-closed が正しい）。
      # 修正前: lock! が無く record.update! が 0 行 UPDATE を黙認し例外を上げない（RAILS_GOTCHAS）。
      expect do
        ActsAsTenant.with_tenant(org2) do
          LeaveRequests::Withdraw.call(leave_request: lr, acting_user: mgr)
        end
      end.to raise_error(ActiveRecord::RecordNotFound)

      deleter.join
    end
  end
end
