# frozen_string_literal: true

module Approvals
  # 承認インボックスの LeaveRequest 行（2-2b 設計 §4.2）。approvable_type 別描画の最初の型。
  class LeaveRequestRowComponent < ViewComponent::Base
    def initialize(assignment:)
      @assignment = assignment
      @leave = assignment.approvable
    end

    def stage_label
      @leave.single_stage? ? "単段（独立性なし）" : "第 #{@assignment.position} 段階"
    end

    def half_day_label
      return nil if @leave.half_day_none?

      @leave.half_day_morning? ? "午前半休" : "午後半休"
    end
  end
end
