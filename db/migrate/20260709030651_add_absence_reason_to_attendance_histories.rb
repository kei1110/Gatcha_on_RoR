# frozen_string_literal: true

class AddAbsenceReasonToAttendanceHistories < ActiveRecord::Migration[8.1]
  def change
    # 監査に「欠勤理由」を構造化して残す（4-2c-2 レビュー: ローカライズ済みラベルを append-only 監査に
    # 焼くと機械復元できず locale 変更で壊れる）。撤回時の absent 復元（Withdraw）が本列を読む。
    # 追記専用トリガーは行レベル（UPDATE/DELETE/TRUNCATE）ゆえ ADD COLUMN は影響しない。
    add_column :attendance_histories, :absence_reason, :integer
  end
end
