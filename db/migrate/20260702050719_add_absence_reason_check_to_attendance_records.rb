# frozen_string_literal: true

class AddAbsenceReasonCheckToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    # §12⑥ leave_type CHECK 対称の二層防御。absence_reason は status=absent(5) の時のみ非 null。
    # 既存 absent AR は無い（4-2c-2 まで writer なし）ゆえ validate なしでも既存行に非違反。
    add_check_constraint :attendance_records,
                         "absence_reason IS NULL OR status = 5",
                         name: "attendance_records_absence_reason_only_on_absent"
  end
end
