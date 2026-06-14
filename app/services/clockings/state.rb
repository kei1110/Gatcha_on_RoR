# frozen_string_literal: true

module Clockings
  # ホームのヘッダー・ボタン活性・バナー導出（読み取り専用・1-1 設計 §2）。
  # サービスのガードと同じ述語（working_within・同日行）を共有し UI とサーバー判定を割らない。
  # クエリは全て user.attendance_records 起点 + with_tenant 自己完結（サービスと同じ規約）
  class State
    def initialize(user:)
      @user = user
      @organization = user.organization
      @today = @organization.today
    end

    attr_reader :today

    # 未出勤 :off_duty / 出勤中 :working / 退勤済 :clocked_out
    def status
      if working_record
        :working
      elsif today_record&.clocked_out?
        :clocked_out
      else
        :off_duty
      end
    end

    def can_clock_in? = today_record.nil? && working_record.nil?

    def can_clock_out? = working_record.present?

    def today_record
      return @today_record if defined?(@today_record)

      @today_record = with_tenant { @user.attendance_records.find_by(work_date: @today) }
    end

    def working_record
      return @working_record if defined?(@working_record)

      @working_record = with_tenant do
        @user.attendance_records.working_within(Clockings.window(@today))
             .order(work_date: :desc).first
      end
    end

    # window より前の取り残し working（退勤忘れバナー — 労務レビュー反映・ユーザー承認）。
    # 出勤は止めない（打刻ブロック禁止の原則）— 検知バッチと是正経路は 4-2/2-3
    def stale_working_record
      return @stale_working_record if defined?(@stale_working_record)

      @stale_working_record = with_tenant do
        @user.attendance_records.working_within(..(@today - Clockings::WINDOW_DAYS - 1))
             .order(work_date: :desc).first
      end
    end

    # 未割当バナー（SPEC §5.4 透明化・0b-4 社員詳細バナーと同型の E 原則）
    def unassigned_pattern?
      return @unassigned_pattern if defined?(@unassigned_pattern)

      @unassigned_pattern = with_tenant { @user.user_work_patterns.effective_on(@today).none? }
    end

    private

    def with_tenant(&) = ActsAsTenant.with_tenant(@organization, &)
  end
end
