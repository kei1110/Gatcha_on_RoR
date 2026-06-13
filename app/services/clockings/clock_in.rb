module Clockings
  # 出勤打刻（1-1 設計 §2）。操作対象は常に呼び出し側の current_user — user_id を外から受けない。
  # with_tenant で自己完結: console/将来ジョブから呼ばれても自社の行しか触れない（SPEC §3.6）。
  # クエリは全て user.attendance_records 起点（同一テナント内の他人に触れない — 1-1 設計 §2）
  class ClockIn
    def self.call(user:) = new(user).call

    def initialize(user)
      @user = user
      @organization = user.organization
    end

    def call
      ActsAsTenant.with_tenant(@organization) do
        today = @organization.today
        # ガードは Clockings::State と同じ述語（UI とサーバー判定を割らない）
        next failure(:already_clocked_in) if @user.attendance_records.exists?(work_date: today)
        next failure(:still_working) if @user.attendance_records
                                             .working_within(Clockings.window(today)).exists?

        record = @user.attendance_records.create!(
          work_date: today,
          clock_in: Time.current.change(usec: 0), # サブ秒切り詰め（1-2 設計 R2 — ClockOut と対）
          # パターンスナップショット（SPEC §4.8・§6.1）: 打刻時点で確定し以後の割当変更は当日に
          # 影響しない（不遡及）。未割当は NULL = 1-2 計算スキップ（SPEC §5.4）。
          # active 割当の重複は exclusion constraint（0b-4）で排除済みゆえ高々 1 件
          work_pattern_id: Clockings.snapshot_pattern_id(@user, today),
          status: :working
        )
        Result.new(success: true, record:, error: nil)
      end
    rescue ActiveRecord::RecordNotUnique
      # 同時タブ・モバイル二重タップ（SPEC §6.1）: unique index [user_id, work_date] が一次防衛。
      # 検証レースの敗者はここで「出勤済み」に合流する
      failure(:already_clocked_in)
    end

    private

    def failure(error) = Result.new(success: false, record: nil, error:)
  end
end
