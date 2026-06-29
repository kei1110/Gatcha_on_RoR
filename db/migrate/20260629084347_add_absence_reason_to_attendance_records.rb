# frozen_string_literal: true

class AddAbsenceReasonToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    # enum・null 可（status: absent の時のみ非 null・§6.10）。consumer クエリ未確定ゆえ index は張らない（YAGNI）
    add_column :attendance_records, :absence_reason, :integer
  end
end
