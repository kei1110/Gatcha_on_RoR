# frozen_string_literal: true

module MonthlySummaries
  # 締め差戻し（SPEC §6.6・3-2 設計 §1.3）。submitted/finalized → deferred。
  # deferral_reason 必須（whiny_persistence で空は RecordInvalid）。通知は 4-1（in-app バナーのみ）。
  class Defer
    def self.call(summary:, reason:) = new(summary:, reason:).call

    def initialize(summary:, reason:)
      @summary = summary
      @reason = reason
    end

    def call
      @summary.with_lock do
        @summary.deferral_reason = @reason
        @summary.defer!
      end
      @summary
    end
  end
end
