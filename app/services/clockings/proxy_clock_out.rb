# frozen_string_literal: true

module Clockings
  # 代理退勤（1-3 設計 §4）。ClockOut と同期構造（GOTCHAS「tx 内 SQL 例外 rescue → 偽 success」回避）。
  # 退勤 + 履歴を with_lock 内で原子的に・rescue は with_lock の外・再計算は commit 後。
  class ProxyClockOut
    def self.call(operator:, target_user:, reason:) = new(operator, target_user, reason).call

    def initialize(operator, target_user, reason)
      @operator = operator
      @target_user = target_user
      @reason = reason
      @organization = operator.organization
    end

    def call
      return failure(:reason_required) if @reason.blank?
      return failure(:self_proxy_forbidden) if @operator == @target_user

      ActsAsTenant.with_tenant(@organization) do
        # fail-closed テナント検証（console/将来ジョブ経路も守る・§3.6）。
        # 部下境界は controller の policy_scope 専任（service は認可境界でない）
        next failure(:cross_tenant) unless @target_user.organization_id == @operator.organization_id

        today = @organization.today
        record = @target_user.attendance_records
                             .working_within(Clockings.window(today)).order(work_date: :desc).first
        next failure(:not_working) if record.nil?

        fragment = Clockings.proxy_note_fragment(
          operator: @operator, organization: @organization, kind: "退勤", reason: @reason)

        result =
          begin
            record.with_lock do
              next failure(:not_working) unless record.working?

              previous = record.dup   # 変更前スナップショット（before-values）
              record.update!(
                clock_out: Time.current.change(usec: 0), status: :clocked_out,
                proxy_clock_reason: @reason, note: Clockings.append_note(record.note, fragment)
              )
              Clockings.record_history(
                event_type: :proxy_clock, organization: @organization,
                user: @target_user, actor: @operator, source: record, note: fragment,
                previous:, current: record
              )
              Result.new(success: true, record:, error: nil)
            end
          rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
            # rescue は with_lock の外（tx 内 rescue は偽 success + 更新消失・RAILS_GOTCHAS）
            Rails.error.report(e, severity: :error,
                                  context: { attendance_record_id: record.id }, source: "clockings")
            failure(:proxy_clock_failed)
          end

        Clockings.recalculate_safely(record) if result.success?   # commit 後（lock 外）
        result
      end
    end

    private

    def failure(error) = Result.new(success: false, record: nil, error:)
  end
end
