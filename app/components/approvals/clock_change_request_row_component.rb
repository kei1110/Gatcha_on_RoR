# frozen_string_literal: true

module Approvals
  # 承認インボックスの ClockChangeRequest 行（2-3 設計 §4）。approvable_type 別描画の 2 つ目。
  class ClockChangeRequestRowComponent < ViewComponent::Base
    CHANGE_LABELS = { "clock_in" => "出勤時刻", "clock_out" => "退勤時刻", "both" => "両方" }.freeze

    def initialize(assignment:)
      @assignment = assignment
      @ccr = assignment.approvable
    end

    def stage_label
      @ccr.single_stage? ? "単段（独立性なし）" : "第 #{@assignment.position} 段階"
    end

    def change_type_label = CHANGE_LABELS.fetch(@ccr.change_type, @ccr.change_type)

    def fmt(time) = time&.in_time_zone(@ccr.organization.time_zone)&.strftime("%H:%M")
  end
end
