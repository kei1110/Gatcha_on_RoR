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

    # FOR UPDATE で取得（lock.first は 2-2b add_to_balance と同型）。無ければ本パターン新規の
    # savepoint-create で行を作る（2-2b は paid 種別の残高行が無ければ over-balance で弾く＝create しないため
    # savepoint-create に前例なし）。create-race の敗者は savepoint のみ rollback し外側 with_lock の
    # 同一 tx を毒さず（設計 R2）、再 find で勝者行へ合流して +1 する。
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
        # 真の INSERT レース（validation SELECT も勝者行を見落とした狭い sub-window）。savepoint のみ
        # rollback され親 tx は健全。再 find で合流。
      rescue ActiveRecord::RecordInvalid => e
        # 現実的な create-race の主経路: validation SELECT が勝者行を先に見て :taken を上げる同レース。
        # :taken 以外（numericality・テナント検証 §3.6 等の本物の失敗）は握り潰さず再 raise。
        raise unless e.record.errors.details[:fiscal_year]&.any? { |d| d[:error] == :taken }
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
