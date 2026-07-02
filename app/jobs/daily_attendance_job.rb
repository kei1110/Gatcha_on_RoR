# frozen_string_literal: true

# 日次バッチのディスパッチャ（設計 §4.1・§3.6）。current_tenant = nil 前提で
# Organization をスコープ外列挙し、子に org_id だけ渡す。既存 NotificationDispatchJob の規範に踏襲。
class DailyAttendanceJob < ApplicationJob
  def perform
    Organization.active.find_each do |org|
      DailyAttendanceTenantJob.perform_later(org.id)
    end
  end
end
