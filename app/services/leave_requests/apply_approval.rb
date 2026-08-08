# frozen_string_literal: true

module LeaveRequests
  # 休暇承認の副作用本体（SPEC §6.2・§13.6・2-2b 設計 §1.3–1.7）。
  # 呼び出し元: LeaveRequest#apply_approval_effects!（Approvals::Approve の with_lock 内・同一 tx）。
  # 内側で rescue しない — OverBalanceError 等は raise 伝播し承認ごと atomic に rollback（§1.2）。
  # 処理順: ① 残高加算（paid のみ・lock!・over-balance 拒否）→ ② per-day AR upsert（+ 半休 clocked は recalc）
  #         → ③ AttendanceHistory(leave_approved)。
  class ApplyApproval
    def self.call(leave_request:, acting_user:) = new(leave_request:, acting_user:).call

    def initialize(leave_request:, acting_user:)
      @leave_request = leave_request
      @acting_user = acting_user
    end

    def call
      # request 文脈前提だが Recalculate 同型で明示ラップ（文脈喪失・将来バッチ化に fail-closed）
      ActsAsTenant.with_tenant(@leave_request.organization) do
        add_to_balance
        upsert_attendance_records
        record_history
      end
      @leave_request
    end

    private

    def add_to_balance
      return unless @leave_request.leave_type.balance_tracked?

      fiscal_year = @leave_request.organization.fiscal_year_for(@leave_request.start_date)  # §6.2 年度跨ぎ統一
      # UNIQUE [org,user,type,fiscal_year] が単一行を保証。.lock で FOR UPDATE（並行承認の二重加算防止）
      balance = LeaveBalance
                .where(user_id: @leave_request.requester_id,
                       leave_type_id: @leave_request.leave_type_id, fiscal_year:)
                .lock.first
      available = balance ? balance.granted_days + balance.carry_over_days : BigDecimal("0")
      used = balance ? balance.used_days : BigDecimal("0")
      # 残高行が無い paid 種別は available=0 → over-balance（D1・hr_admin が先に付与）
      raise Approvals::OverBalanceError if used + @leave_request.days_requested > available

      balance.update!(used_days: used + @leave_request.days_requested)
    end

    def upsert_attendance_records
      classifications = CompanyCalendarResolver.new(organization: @leave_request.organization)
                                               .day_classifications(@leave_request.start_date,
                                                                    @leave_request.end_date)
      LeaveDaysCalculator.counted_dates(classifications).each do |date|
        # 既存行はロックを取ってから読む（4-2c-3a）。attendance_records に lock_version が無く、
        # ロックなし SELECT → save! は削除済み行への 0 行 UPDATE を黙認する（RAILS_GOTCHAS）。
        # FOR UPDATE は削除済み行に 0 行を返すため nil に落ち INSERT 経路へ。呼び出し元 with_lock 内ゆえ保持される
        record = AttendanceRecord.lock.find_by(
          user_id: @leave_request.requester_id, work_date: date
        ) || AttendanceRecord.new(user_id: @leave_request.requester_id, work_date: date)
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
      end
    end

    def record_history
      AttendanceHistory.create!(
        user_id: @leave_request.requester_id,
        actor: @acting_user,             # §3.5 オーナー/操作者分離
        source: @leave_request,          # polymorphic
        event_type: :leave_approved,     # 既存予約 enum（整数 2）
        event_date: @leave_request.start_date   # 申請単位 1 行（per-day AR とは別粒度）
      )
    end

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

    # 半休で clock_out 済の AR のみ LateEarly を上書き。全休（打刻無）・working 中は呼ばない。
    def recalculate(record)
      return if record.on_leave?
      return if record.clock_out.blank?

      Clockings::Recalculate.call(record:)
    end

    # 対応表の正本は LeaveRequest#leave_status（Withdraw の貼り直しと共有）
    def leave_status = @leave_request.leave_status
  end
end
