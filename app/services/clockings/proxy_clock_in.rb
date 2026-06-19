# frozen_string_literal: true

module Clockings
  # 代理出勤（1-3 設計 §4）。自己打刻 ClockIn とは別クラス（current_user 固定の不変条件を壊さない）。
  # 打刻と履歴を同一 tx で原子的に（履歴は法的必須・証跡なき改変を作らない）。
  class ProxyClockIn
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
        next failure(:already_clocked_in) if @target_user.attendance_records.exists?(work_date: today)
        next failure(:still_working) if @target_user.attendance_records
                                                    .working_within(Clockings.window(today)).exists?

        fragment = Clockings.proxy_note_fragment(
          operator: @operator, organization: @organization, kind: "出勤", reason: @reason)
        record = nil
        ActiveRecord::Base.transaction do
          record = @target_user.attendance_records.create!(
            work_date: today,
            clock_in: Time.current.change(usec: 0),
            work_pattern_id: Clockings.snapshot_pattern_id(@target_user, today),
            status: :working,
            proxy_clock_reason: @reason,
            note: fragment,
            is_holiday_work: @target_user.holiday_work_reserved_on?(today)   # target を見る（2-4 D1）
          )
          Clockings.record_history(
            event_type: :proxy_clock, organization: @organization,
            user: @target_user, actor: @operator, source: record, note: fragment,
            previous: nil, current: record
          )
        end
        Result.new(success: true, record:, error: nil)
      end
    rescue ActiveRecord::RecordNotUnique
      failure(:already_clocked_in)
    rescue ActiveRecord::RecordInvalid, ActiveRecord::StatementInvalid => e
      Rails.error.report(e, severity: :error,
                            context: { target_user_id: @target_user.id }, source: "clockings")
      failure(:proxy_clock_failed)
    end

    private

    def failure(error) = Result.new(success: false, record: nil, error:)
  end
end
