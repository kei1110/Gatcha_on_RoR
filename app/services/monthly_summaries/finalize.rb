# frozen_string_literal: true

module MonthlySummaries
  # 締め確定（SPEC §6.6・3-2 設計 §1.3）。submitted → finalized。
  # 確定の唯一経路（単一・一括 BulkFinalizeJob の両方がここを通る・divergence 防止）。
  # D7: Aggregate を呼ばない（確定値は確定後に動かさない）。
  class Finalize
    def self.call(summary:) = new(summary:).call

    def initialize(summary:)
      @summary = summary
    end

    def call
      @summary.with_lock { @summary.finalize! }
      @summary
    end
  end
end
