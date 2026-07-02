# frozen_string_literal: true

module AttendanceAnomalies
  # 前日分の単一 (user, date) を分類する純関数（設計 §4.2・§10③）。
  # DB を引かず事実だけ受け取る（Detect が DB から解決して渡す）→ DB なし単体テスト可。
  class Detector
    # 退勤打刻忘れの対象 status（§4.2①）。clocked_out/on_leave/absent は対象外。
    CLOCK_STATUSES = %w[working morning_half afternoon_half].freeze

    # AR あり: 退勤打刻忘れか（§4.2①）。夜勤は勤務中の可能性ゆえ false（翌 run へ deferral・§10⑪）。
    def self.clock_out_missing?(status:, clock_in_present:, clock_out_present:, night_shift:)
      return false unless CLOCK_STATUSES.include?(status)
      return false unless clock_in_present
      return false if clock_out_present
      return false if night_shift

      true
    end

    # AR なし: 無打刻の分類（§4.2②）。
    # 申請中 LR 有 → :leave_pending_no_clock（管理者情報提供）
    # LR 皆無（全 status）∧ 稼働日 → :absence_candidate（欠勤候補 upsert）
    # それ以外（非稼働日 / LR 有だが申請中でない）→ nil
    def self.no_clock_anomaly(covering_leave_applying:, has_covering_leave_request:, working_day:)
      return :leave_pending_no_clock if covering_leave_applying
      return :absence_candidate if working_day && !has_covering_leave_request

      nil
    end
  end
end
