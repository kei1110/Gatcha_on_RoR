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
    it "他の LR が withdrawal_requested でも AR を destroy しない（副作用は未反転・reject_withdrawal で approved へ戻り得る）" do
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

    # 分岐①は「AR を触らない」だと撤回された側の status / leave_type_id が残る。
    # LeaveAggregator#paid_weight / #weight がこれを直読するため §8.6 の有給 5 日義務が過少に振れる
    # （4-2c-2 approval-engine W1 / labor-law W-f）。生存 LR が一意に決まる場合だけ貼り直す
    describe "生存 LR への貼り直し" do
      def reassign_scenario
        create(:attendance_record, user:, work_date: start_date, status: :morning_half,
                                   leave_type: unpaid_type, clock_in: nil)
      end

      it "生きた LR がちょうど 1 件なら AR をその LR の属性へ貼り直す" do
        live_other_leave # paid_type・全休
        record = reassign_scenario

        withdraw(leave(type: unpaid_type, half: :morning, days: BigDecimal("0.5")))

        record.reload
        expect(record.status).to eq("on_leave")             # 生存 LR の half_day_type: none 由来
        expect(record.leave_type_id).to eq(paid_type.id)
      end

      it "生きた LR が 2 件以上なら貼り直さない（どちらが所有者か決められない）" do
        live_other_leave
        create(:leave_request, requester: user, leave_type: paid_type, start_date:, end_date: start_date,
                               half_day_type: :none, days_requested: 1, approval_status: :approved)
        record = reassign_scenario

        withdraw(leave(type: unpaid_type, half: :morning, days: BigDecimal("0.5")))

        record.reload
        expect(record.status).to eq("morning_half")
        expect(record.leave_type_id).to eq(unpaid_type.id)
      end

      it "貼り直しは leave_reassigned 履歴を残す（台帳の変更を追える・§4.14）" do
        surviving = live_other_leave
        reassign_scenario

        withdraw(leave(type: unpaid_type, half: :morning, days: BigDecimal("0.5")))

        history = AttendanceHistory.find_by(event_type: :leave_reassigned, event_date: start_date)
        expect(history).to be_present
        expect(history.actor_id).to eq(approver.id)
        expect(history.previous_status).to eq(AttendanceRecord.statuses[:morning_half])
        expect(history.new_status).to eq(AttendanceRecord.statuses[:on_leave])
        expect(history.note).to include(surviving.id.to_s) # その日を「今どの申請が所有するか」
      end

      # 打刻のある日を全休へ再分類すると Aggregate の WORKED_STATUSES から外れ、実労働が
      # 総労働時間・時間外・60h 超の母数から丸ごと消える（打刻列は行に残るのに集計から落ちる）。
      # 同 service の分岐②「実打刻がある → 実労働を欠勤として記録しない」と同じ原則を守り、
      # status の変更は未打刻日に限る。帰属（leave_type_id）は常に直す（labor-law レビュー C1）
      it "打刻のある日は status を保ち leave_type_id だけ貼り直す（実労働を集計から落とさない）" do
        live_other_leave # paid_type・全休
        record = create(:attendance_record, :done, user:, work_date: start_date,
                                                   clock_in: Time.utc(2026, 5, 1, 0), # JST 09:00
                                                   status: :afternoon_half, leave_type: unpaid_type,
                                                   work_pattern: create(:work_pattern),
                                                   late_minutes: 30, actual_work_hours: BigDecimal("4"))

        withdraw(leave(type: unpaid_type, half: :afternoon, days: BigDecimal("0.5")))

        record.reload
        expect(record.status).to eq("afternoon_half")                      # 集計母数に残り続ける
        expect(MonthlySummaries::Aggregate::WORKED_STATUSES).to include(:afternoon_half)
        expect(record.leave_type_id).to eq(paid_type.id)                   # 帰属だけ直る
        expect(record.late_minutes).to eq(30)                              # 計算列も動かさない
      end

      it "既に生存 LR の属性と一致する日は履歴を作らない（append-only の台帳にノイズを残さない）" do
        # 撤回対象が複数日・生存 LR が単日で後から承認された日は、既に生存 LR の属性になっている
        live_other_leave # paid_type・全休
        create(:attendance_record, user:, work_date: start_date, status: :on_leave,
                                   leave_type: paid_type, clock_in: nil)

        withdraw(leave(type: unpaid_type))

        expect(AttendanceHistory.where(event_type: :leave_reassigned)).not_to exist
      end

      # 実害は AR の属性ではなく §8.6 監視の数字ゆえ、集計レベルで固定する
      it "貼り直し後の paid_leave_days_used が生存する年休 1.0 を計上する（§8.6）" do
        org.setting.update!(closing_day: 31)
        create(:user_work_pattern, user:, start_date: Date.new(2026, 1, 1),
                                   work_pattern: create(:work_pattern, standard_work_hours: 8))
        live_other_leave
        reassign_scenario

        withdraw(leave(type: unpaid_type, half: :morning, days: BigDecimal("0.5")))

        result = MonthlySummaries::LeaveAggregator.call(
          user:, period: AttendancePeriod.new(organization: org, year_month: "2026-05")
        )
        expect(result[:paid_leave_days_used]).to eq(BigDecimal("1"))
      end
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
              sleep 0.3 # 未コミットのまま保持する。この窓が Withdraw の初回 SELECT を
              # deleter commit 前に確実に走らせ、後続の lock! をロック待ちへ入れる
            end
          end
        end
      end
      locked.pop

      # sleep 0.3 の保持窓は「lock! がどちらのタイミングで発行されても RecordNotFound に収束する」
      # ことを保証するものではない。厳密には restore_attendance_records の対象 AR を取る初回 SELECT
      # （remove_from_balance → 本クエリ、いずれも数 ms）が deleter commit 前に走ることが前提。
      # 初回 SELECT がその窓に収まって走れば、削除済み予定の行がまだ結果セットに含まれた状態で
      # lock!（SELECT ... FOR UPDATE）が発行され、deleter commit を境に「行はもう無い」と判明して
      # RecordNotFound で fail-closed になる（逆に初回 SELECT 自体が deleter commit 後にずれ込むと、
      # 削除済み行はそもそも結果セットに現れず lock! が呼ばれないため、この判別は成立しない）。
      # 修正前: lock! が無く record.update! が削除済み行への 0 行 UPDATE を黙認し例外を上げない（RAILS_GOTCHAS）。
      expect do
        ActsAsTenant.with_tenant(org2) do
          LeaveRequests::Withdraw.call(leave_request: lr, acting_user: mgr)
        end
      end.to raise_error(ActiveRecord::RecordNotFound)

      deleter.join
    end
  end
end
