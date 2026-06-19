# frozen_string_literal: true

module Approvals
  # 承認インボックスの HolidayWorkRequest 行（2-4 設計 §3.4）。approvable_type 別描画の 3 つ目。
  class HolidayWorkRequestRowComponent < ViewComponent::Base
    def initialize(assignment:)
      @assignment = assignment
      @hwr = assignment.approvable
    end

    def stage_label
      @hwr.single_stage? ? "単段（独立性なし）" : "第 #{@assignment.position} 段階"
    end
  end
end
