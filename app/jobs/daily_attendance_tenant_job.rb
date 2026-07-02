# frozen_string_literal: true

# ディスパッチャの子（設計 §4.1・§3.6・§11⑪）。with_tenant で当該テナントの前日分を検知する。
class DailyAttendanceTenantJob < ApplicationJob
  def perform(organization_id)
    org = Organization.find_by(id: organization_id)
    return if org.nil? # §11⑪ dispatch→実行間の org 削除レース耐性

    ActsAsTenant.with_tenant(org) do # §3.6 必須（リクエスト文脈なし）
      AttendanceAnomalies::Detect.call(date: org.today.prev_day)
    end
  end
end
