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
end
