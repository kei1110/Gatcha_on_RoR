# frozen_string_literal: true

module MonthlySummaries
  # 月次一括確定（SPEC §6.6・§16.2・3-2 設計 §3.2）。初の SolidQueue ジョブ。
  # 認可境界は enqueue 時の policy_scope 交差（controller・§3.3）。ジョブ内に再認可は無い。
  # organization_id は server 由来（ActsAsTenant.current_tenant.id）で渡すこと。
  class BulkFinalizeJob < ApplicationJob
    def perform(organization_id:, summary_ids:)
      org = Organization.find(organization_id)
      ActsAsTenant.with_tenant(org) do # §3.6 必須（リクエスト文脈なし）
        MonthlyAttendanceSummary.where(id: summary_ids).find_each do |summary|
          Finalize.call(summary:) if summary.submitted? # 唯一経路・冪等（非 submitted skip）
        rescue AASM::InvalidTransition, ActiveRecord::RecordInvalid => e
          Rails.logger.warn("[BulkFinalize] skip ##{summary.id}: #{e.class}") # 1 件失敗を隔離（4-1 で通知）
        end
      end
    end
  end
end
