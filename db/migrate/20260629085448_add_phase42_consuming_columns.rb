# frozen_string_literal: true

class AddPhase42ConsumingColumns < ActiveRecord::Migration[8.1]
  def change
    # §6.9/§8.4 月内インターバル違反回数（打刻時インクリメント・集計列ではない）
    add_column :monthly_attendance_summaries, :interval_violation_count, :integer, null: false, default: 0
    # §6.9 勤務間インターバル閾値（既定 11h・§10④ daily_batch_hour は追加しない）
    add_column :organization_settings, :rest_interval_hours, :integer, null: false, default: 11
  end
end
