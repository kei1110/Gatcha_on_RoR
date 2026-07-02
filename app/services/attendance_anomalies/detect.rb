# frozen_string_literal: true

module AttendanceAnomalies
  # 日次バッチの検知オーケストレーター（設計 §4・§10・§11）。with_tenant 前提（fail-closed）。
  # pass 1: 前日分を検知（退勤忘れ即時通知 / 休暇申請中無打刻 即時通知 / 欠勤候補 upsert）
  # pass 2: 既存候補を走査（AR/LR 出現で resolve・本人稼働日 run で notify-once）
  # 純粋判定は Detector（PORO）へ委譲（§10③）。副作用オーケストレーションに専念。
  class Detect
    # 休日集合の正（= Notifier::HOLIDAY_DAY_TYPES）。稼働日 = day_type ∉ この集合。
    HOLIDAY_DAY_TYPES = Notifier::HOLIDAY_DAY_TYPES

    def self.call(date:) = new(date:).call

    def initialize(date:)
      @date = date                      # 検知対象日（前日・org.today.prev_day）
      @org = ActsAsTenant.current_tenant # with_tenant 前提
    end

    def call
      raise ActsAsTenant::Errors::NoTenant, "Detect は with_tenant 内で呼ぶこと（§3.6）" if @org.nil?

      detect_prev_day
      process_candidates
      nil
    end

    private

    # ---- pass 1: 前日分の検知（§4.2） ----
    def detect_prev_day
      working = working_day?(@date)
      rows = []
      User.active.find_each do |user|
        ar = AttendanceRecord.find_by(user_id: user.id, work_date: @date)
        if ar
          notify_clock_out_missing(user) if clock_out_missing?(ar)
        else
          case no_clock_anomaly(user, working)
          when :leave_pending_no_clock then notify_leave_pending(user)
          when :absence_candidate then rows << candidate_row(user)
          end
        end
      rescue StandardError => e
        report(e, "detect_prev_day user_id=#{user.id}")
      end
      upsert_candidates(rows)
    end

    def clock_out_missing?(attendance_record)
      Detector.clock_out_missing?(
        status: attendance_record.status,
        clock_in_present: attendance_record.clock_in.present?,
        clock_out_present: attendance_record.clock_out.present?,
        night_shift: attendance_record.work_pattern&.night_shift? || false
      )
    end

    def no_clock_anomaly(user, working)
      lrs = covering_leave_requests(user.id, @date)
      Detector.no_clock_anomaly(
        covering_leave_applying: lrs.where(approval_status: :applying).exists?,
        has_covering_leave_request: lrs.exists?,
        working_day: working
      )
    end

    def upsert_candidates(rows)
      return if rows.empty?

      # §10⑨ atomic upsert / §11⑤ organization_id 明示（insert_all は acts_as_tenant 注入・検証を bypass）
      AbsenceCandidate.insert_all(rows, unique_by: %i[organization_id user_id target_date])
    end

    def candidate_row(user)
      now = Time.current
      { organization_id: @org.id, user_id: user.id, target_date: @date,
        notified_on: nil, created_at: now, updated_at: now }
    end

    # ---- pass 2: 既存候補の resolve / notify（§4.3/§4.4） ----
    def process_candidates
      today = @org.today
      today_working = working_day?(today)
      AbsenceCandidate.find_each do |candidate|
        if covered?(candidate)
          candidate.destroy
        elsif candidate.notified_on.nil? && today_working
          notify_candidate(candidate, today)
        end
      rescue StandardError => e
        report(e, "process_candidates candidate_id=#{candidate.id}")
      end
    end

    def covered?(candidate)
      AttendanceRecord.exists?(user_id: candidate.user_id, work_date: candidate.target_date) ||
        covering_leave_requests(candidate.user_id, candidate.target_date).exists?
    end

    def notify_candidate(candidate, today)
      user = candidate.user
      Notifier.call(
        target_user: user, priority: :informational, source_type: :absence_candidate,
        title: "出勤記録がありません",
        body: "#{candidate.target_date} の出勤記録がありません。打刻漏れの場合は打刻変更申請を提出してください。"
      )
      candidate.update!(notified_on: today) # §11⑧ 本人 Notifier 成功後に確定（猶予起算アンカー保護）
      notify_candidate_manager(user, candidate.target_date) # 管理者は best-effort（notified_on の条件にしない）
    end

    def notify_candidate_manager(user, target_date)
      manager = user.manager
      return if manager.nil?

      Notifier.call(
        target_user: manager, subject_user: user,
        priority: :informational, source_type: :absence_candidate,
        title: "部下の出勤記録がありません",
        body: "#{user.name} さんの #{target_date} の出勤記録がありません。"
      )
    end

    # ---- pass 1 の即時通知 ----
    def notify_clock_out_missing(user)
      Notifier.call(
        target_user: user, priority: :reference, source_type: :clock_out_missing,
        title: "退勤打刻がありません",
        body: "#{@date} の退勤打刻が記録されていません。退勤時刻の打刻変更申請をご確認ください。"
      )
    end

    def notify_leave_pending(user)
      manager = user.manager
      return if manager.nil?

      Notifier.call(
        target_user: manager, subject_user: user,
        priority: :informational, source_type: :leave_pending_no_clock,
        title: "部下の打刻がありません（休暇申請中）",
        body: "#{user.name} さんの #{@date} の出勤記録がありません（休暇申請が承認待ちです）。"
      )
    end

    # ---- 共通 ----
    # 対象日を覆う LR（start_date <= date <= end_date・status 不問）
    def covering_leave_requests(user_id, date)
      LeaveRequest.where(requester_id: user_id).where(start_date: ..date).where(end_date: date..)
    end

    def working_day?(date)
      !CompanyCalendarResolver.new(organization: @org).day_type(date).in?(HOLIDAY_DAY_TYPES)
    end

    def report(error, context)
      Rails.logger.error("[AttendanceAnomalies::Detect] #{context}: #{error.class} #{error.message}")
      Rails.error.report(error, handled: true) # 運用可視化（Sentry 連携前提・§10⑦）
    end
  end
end
