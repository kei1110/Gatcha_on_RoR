class CreateAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :attendance_records do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.date :work_date, null: false
      # SPEC §4.8 は timestamptz。clock_in NOT NULL は「1-1 の全行は打刻起源」の帰結 —
      # on_leave/absent の NULL 意味論は 2-2/4-2 が消費と同時に緩和する（1-1 設計 §1）
      t.timestamptz :clock_in, null: false
      t.timestamptz :clock_out
      t.bigint :work_pattern_id
      t.integer :status, null: false

      t.timestamps
    end

    # 二重打刻防止の背骨（user_id はグローバル一意 PK ゆえテナント越境なしの全域一意が安全 — ②型）
    add_index :attendance_records, %i[user_id work_date], unique: true
    # プロジェクト規約（後続スライス LeaveRequest 等の複合 FK 受け皿）
    add_index :attendance_records, %i[organization_id id], unique: true

    # 越境 FK の最終防衛（user_work_patterns と同型の確立パターン）
    add_foreign_key :attendance_records, :users,
                    column: %i[organization_id user_id], primary_key: %i[organization_id id]
    add_foreign_key :attendance_records, :work_patterns,
                    column: %i[organization_id work_pattern_id], primary_key: %i[organization_id id]
  end
end
