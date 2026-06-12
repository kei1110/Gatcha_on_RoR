module Clockings
  # 退勤打刻（1-1 設計 §2）。対象は「window 内の最新 working」— work_date でなく status 起点に
  # するのが夜勤対応の要（日付跨ぎ退勤が前日の出勤レコードに合流する・SPEC §4.8 出勤日統一)。
  # window 外の取り残し working は触らない（4-2 打刻漏れバッチの検出対象として温存）。
  # 退勤済み後の再打刻は不可 — 時刻修正は 2-3 打刻変更申請に一本化（§0 時刻不変条件）
  class ClockOut
    def self.call(user:) = new(user).call

    def initialize(user)
      @user = user
      @organization = user.organization
    end

    def call
      ActsAsTenant.with_tenant(@organization) do
        window = Clockings.window(@organization.today)
        record = @user.attendance_records.working_within(window).order(work_date: :desc).first
        next failure(:not_working) if record.nil?

        record.with_lock do
          # 同時タブ race: ロック待ちの間に他方が退勤済みへ変えていたら敗北（先勝ちの時刻を保持）
          if record.working?
            record.update!(clock_out: Time.current, status: :clocked_out)
            Result.new(success: true, record:, error: nil)
          else
            failure(:not_working)
          end
        end
      end
    end

    private

    def failure(error) = Result.new(success: false, record: nil, error:)
  end
end
