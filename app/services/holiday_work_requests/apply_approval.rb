# frozen_string_literal: true

module HolidayWorkRequests
  # 休日出勤承認の副作用本体（SPEC §6.11・2-4 設計 §2.2）。
  # 呼び出し元: HolidayWorkRequest#apply_approval_effects!（Approvals::Approve の with_lock 内・同一 tx）。
  # 内側で rescue しない — ConflictError は raise 伝播し承認ごと atomic rollback。
  # 処理順: ① work_date 平日性 re-validate ② 代休残高 +1（lock or savepoint create）③ 既存 AR に flag。
  class ApplyApproval
    def self.call(holiday_work_request:, acting_user:)
      new(holiday_work_request:, acting_user:).call
    end

    def initialize(holiday_work_request:, acting_user:)
      @hwr = holiday_work_request
      @acting_user = acting_user
    end

    def call
      ActsAsTenant.with_tenant(@hwr.organization) do
        revalidate_holiday!          # ①
        grant_compensation_balance   # ②
        flag_existing_record         # ③
      end
      @hwr
    end

    private

    # ① 承認時にカレンダー編集で平日化していたら弾く（§7.4 哲学・D4）
    def revalidate_holiday!
      resolver = CompanyCalendarResolver.new(organization: @hwr.organization)
      raise Approvals::ConflictError if resolver.day_type(@hwr.work_date) == :weekday
    end

    # ② 代休残高 +1（付与ゆえ over-balance チェック無し）
    def grant_compensation_balance
      fiscal_year = @hwr.organization.fiscal_year_for(@hwr.work_date)   # §6.2 年度跨ぎ統一
      balance = lock_or_create_balance(@hwr.requester_id, @hwr.compensation_leave_type_id, fiscal_year)
      balance.update!(granted_days: balance.granted_days + 1)
    end

    # FOR UPDATE で取得（2-2b add_to_balance 同型）。無ければ savepoint で create し RecordNotUnique を隔離
    # （外側 with_lock の同一 tx を RecordNotUnique で毒さない・設計 R2）。
    def lock_or_create_balance(user_id, leave_type_id, fiscal_year)
      scope = LeaveBalance.where(user_id:, leave_type_id:, fiscal_year:)
      balance = scope.lock.first
      return balance if balance

      begin
        ActiveRecord::Base.transaction(requires_new: true) do
          LeaveBalance.create!(user_id:, leave_type_id:, fiscal_year:,
                               granted_days: 0, carry_over_days: 0, used_days: 0)
        end
      rescue ActiveRecord::RecordNotUnique
        # 並行 create の敗者 — 行は既に存在。savepoint のみ rollback、親 tx は健全
      end
      scope.lock.first
    end

    # ③ 既存 AR にのみ flag（予約は AR を新規作成しない）。再計算しない（§5 は is_holiday_work 非依存・D6）
    def flag_existing_record
      record = @hwr.requester.attendance_records.find_by(work_date: @hwr.work_date)
      record&.update!(is_holiday_work: true)
    end
  end
end
