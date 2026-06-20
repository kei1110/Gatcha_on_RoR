# frozen_string_literal: true

module MonthlySummaries
  # 締めロック述語（query object・3-2 設計 §2.1・D4）。
  # (user, dates) の各日が属する締め期間の status が submitted/finalized なら locked。
  # 行なし＝aggregating＝unlocked（締めていないものは締まっていない＝この向きは fail-open が正）。
  class ClosingLock
    LOCKED = %w[submitted finalized].freeze

    def self.locked?(user:, dates:) = new(user:, dates:).locked?

    def initialize(user:, dates:)
      @user = user
      @dates = dates
    end

    def locked?
      ActsAsTenant.with_tenant(@user.organization) do
        MonthlyAttendanceSummary
          .where(user: @user, year_month: period_labels, status: LOCKED)
          .exists?
      end
    end

    private

    # containing(min)..containing(max) を walk して distinct labels（3-2 設計 §2.1）。
    def period_labels
      ds = Array(@dates).flatten
      org = @user.organization
      first = AttendancePeriod.containing(organization: org, date: ds.min)
      last  = AttendancePeriod.containing(organization: org, date: ds.max)
      labels = []
      period = first
      loop do
        labels << period.label
        break if period.label == last.label

        period = period.next
      end
      labels
    end
  end
end
