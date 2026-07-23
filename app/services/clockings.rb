# frozen_string_literal: true

# 打刻系サービスの共有部品（1-1 設計 §2）
module Clockings
  # 0b-5 OrganizationSettings::Updater と同型の戻り値規約
  Result = Data.define(:success, :record, :error) do
    def success? = success
  end

  # 退勤探索・出勤ガードの window 幅（日）。夜勤の日付跨ぎ退勤を前日レコードへ合流させ、
  # それより前の取り残し working は 4-2 打刻漏れバッチの検出対象として温存する（SPEC §4.8）
  WINDOW_DAYS = 1

  # 打刻状態の探索範囲。ClockIn ガード・ClockOut 対象・State 表示で共有（述語の単一ソース）
  def self.window(today) = (today - WINDOW_DAYS)..today

  # 出勤打刻のパターンスナップショット単一ソース（ClockIn / ProxyClockIn 共有・§4.8）
  def self.snapshot_pattern_id(user, date)
    user.user_work_patterns.effective_on(date).pick(:work_pattern_id)
  end

  # note の ； 連結（SPEC §6.1・代理打刻 / 4-2 インターバル不足が共有）
  def self.append_note(existing, fragment)
    existing.present? ? "#{existing}；#{fragment}" : fragment
  end

  # 計算 8 列の再計算を打刻保全しつつ実行（ClockOut / ProxyClockOut 共有）。
  # 例外 = 実装バグだが打刻はブロックしない（8 列 NULL に閉じ Sentry へ・1-2 設計 R4）。恒久は 4-2 バッチ
  def self.recalculate_safely(record)
    Clockings::Recalculate.call(record:)
  rescue StandardError => e
    Rails.error.report(e, severity: :error,
                          context: { attendance_record_id: record.id }, source: "clockings")
  end

  # 代理打刻 note 断片の単一実装（§6.1 の定型文・永続データ）
  def self.proxy_note_fragment(operator:, organization:, kind:, reason:)
    zone = ActiveSupport::TimeZone[organization.time_zone]
    at = Time.current.in_time_zone(zone).strftime("%Y-%m-%d %H:%M")
    label = I18n.t("activerecord.attributes.attendance_record.proxy_clock_reasons.#{reason}")
    "代理打刻（#{kind}）：#{operator.name} が #{at} に実施（理由: #{label}）"
  end

  # AttendanceHistory 追記の単一入口（proxy_clock・将来の承認系が合流・§4.14）。
  # status は AttendanceRecord.statuses で整数化（文字列誤投入防止）。
  # previous = 変更前スナップショット（create は nil）/ current = 確定後レコード
  # 呼び出し側は update! の前に record.dup で previous を取ること（同一オブジェクトを update! 後に渡すと before-values が壊れる）
  def self.record_history(event_type:, organization:, user:, actor:, source:, note:, previous:, current:)
    AttendanceHistory.create!(
      organization:, user:, actor:, source:, event_type:, note:,
      event_date: current.work_date,
      previous_status: previous && AttendanceRecord.statuses[previous.status],
      new_status: AttendanceRecord.statuses[current.status],
      previous_clock_in: previous&.clock_in,  new_clock_in: current.clock_in,
      previous_clock_out: previous&.clock_out, new_clock_out: current.clock_out,
      previous_is_late: previous&.is_late, new_is_late: current.is_late,
      previous_late_minutes: previous&.late_minutes, new_late_minutes: current.late_minutes,
      previous_is_early_leave: previous&.is_early_leave, new_is_early_leave: current.is_early_leave,
      previous_early_leave_minutes: previous&.early_leave_minutes,
      new_early_leave_minutes: current.early_leave_minutes
    )
  end

  # インターバル判定を打刻保全しつつ実行（ClockingsController / ProxyClockingsController が共有）。
  # 例外 = 実装バグだが打刻はブロックしない（recalculate_safely と同型・鉄則 6）。nil = 判定不能
  def self.check_interval_safely(record:, actor:)
    Clockings::IntervalCheck.call(record:, actor:)
  rescue StandardError => e
    Rails.error.report(e, severity: :error,
                          context: { attendance_record_id: record.id }, source: "clockings")
    nil
  end
end
