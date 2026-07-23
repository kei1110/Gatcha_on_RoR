# frozen_string_literal: true

module Clockings
  # 出勤打刻時の勤務間インターバル判定 + 記録（SPEC §6.9・設計 §6.1/§13）。
  # 打刻はブロックしない（鉄則 6）— controller からは Clockings.check_interval_safely 経由で呼ぶ。
  # 代理経路（ProxyClockIn 成功後）でも同一判定（§13② — 休息不足の事実は打刻経路に依らない）。
  # MAS には触れない（§13①: interval_violation_count は締め時に Aggregate が AH を count する）。
  class IntervalCheck
    Result = Data.define(:violation, :shortage_minutes) do
      def violation? = violation
    end
    NO_VIOLATION = Result.new(violation: false, shortage_minutes: nil)

    def self.call(record:, actor:) = new(record, actor).call

    def initialize(record, actor)
      @record = record
      @actor = actor
      @user = record.user
      @organization = @user.organization
    end

    def call
      guard_actor_same_organization!
      ActsAsTenant.with_tenant(@organization) do
        shortage = IntervalShortageCalculator.call(
          prev_clock_out: previous_clock_out,
          clock_in: @record.clock_in,
          threshold_hours: threshold_hours
        )
        next NO_VIOLATION if shortage.nil?

        record_violation(shortage)
        Result.new(violation: true, shortage_minutes: shortage)
      end
    end

    private

    # with_tenant 昇格前の操作者検証（RAILS_GOTCHAS「with_tenant は昇格プリミティブ」・
    # Absences::Confirm#guard_actor_same_organization! と同型 — ROADMAP 対称化 backlog 準拠）
    def guard_actor_same_organization!
      return if @actor.organization_id == @organization.id

      raise ArgumentError, "actor org mismatch: actor=#{@actor.id} record=#{@record.id}"
    end

    def threshold_hours = @organization.setting.rest_interval_hours

    # 「同一 user の直近の clock_out を持つ AR」を時刻降順で 1 件（§13④ — prev_day 固定にしない）。
    # 夜勤（前日行に日跨ぎ退勤が入る）も検索条件だけで自然に翌々日判定になる。自レコードは clock_out nil ゆえ対象外
    def previous_clock_out
      @user.attendance_records.where.not(clock_out: nil)
           .where(clock_out: ...@record.clock_in)
           .order(clock_out: :desc).pick(:clock_out)
    end

    # {note 追記 + AH(interval_shortage)} を 1 tx（設計 §6.1）。打刻直後の自レコードへの
    # update! ゆえ並行 DELETE の 0 行 UPDATE 窓は実質無い（同一リクエスト内・作成直後）
    def record_violation(shortage)
      fragment = note_fragment(shortage)
      ActiveRecord::Base.transaction do
        previous = @record.dup # record_history 規約: update! 前にスナップショット
        @record.update!(note: Clockings.append_note(@record.note, fragment))
        Clockings.record_history(
          event_type: :interval_shortage, organization: @organization,
          user: @user, actor: @actor, source: @record, note: fragment,
          previous:, current: @record
        )
      end
    end

    def note_fragment(shortage)
      rest = threshold_hours * 60 - shortage
      "勤務間インターバル不足：休息 #{rest / 60}時間#{format('%02d', rest % 60)}分" \
        "（規定 #{threshold_hours} 時間・不足 #{shortage} 分）"
    end
  end
end
