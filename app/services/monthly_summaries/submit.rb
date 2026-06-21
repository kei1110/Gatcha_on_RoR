# frozen_string_literal: true

module MonthlySummaries
  # 締め提出 / 再提出（SPEC §6.6・3-2 設計 §1.3・D2/D6/D7）。
  # ① 提出前チェック（in-flight 申請があれば ConflictError・再集計の前に fail-closed）
  # ② Aggregate.call（全件再集計・status 非干渉の純関数）→ ③ submit!（同一インスタンス・順序固定）。
  # 副作用→遷移の順は §13.6 の唯一の例外（D7: locked 行は再集計しない＝集計は unlocked のうちに）。
  class Submit
    def self.call(user:, period:) = new(user:, period:).call

    def initialize(user:, period:)
      @user = user
      @period = period
    end

    def call
      ActiveRecord::Base.transaction do
        raise Approvals::ConflictError if PendingRequests.new(user: @user, period: @period).any?

        summary = Aggregate.call(user: @user, period: @period)
        summary.submit!
        summary
      end
    end
  end
end
