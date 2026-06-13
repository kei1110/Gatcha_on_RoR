class CreateAttendanceHistories < ActiveRecord::Migration[8.1]
  def change
    create_table :attendance_histories do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false   # 対象社員
      t.bigint :actor_id               # 操作者（NULL = Phase4 システム起因イベント）
      t.date :event_date, null: false
      t.integer :event_type, null: false
      t.string :source_type            # polymorphic 起因/被作用レコード
      t.bigint :source_id
      t.integer :previous_status
      t.integer :new_status
      t.timestamptz :previous_clock_in
      t.timestamptz :new_clock_in
      t.timestamptz :previous_clock_out
      t.timestamptz :new_clock_out
      t.boolean :previous_is_late
      t.boolean :new_is_late
      t.integer :previous_late_minutes
      t.integer :new_late_minutes
      t.boolean :previous_is_early_leave
      t.boolean :new_is_early_leave
      t.integer :previous_early_leave_minutes
      t.integer :new_early_leave_minutes
      t.text :note
      t.datetime :created_at, null: false   # 追記専用ゆえ updated_at は持たない（§4.14）
    end

    # クロステナント越境を DB 層で遮断（user_work_patterns と同じ複合 FK パターン・§3.6）
    add_foreign_key :attendance_histories, :users,
                    column: %i[organization_id user_id], primary_key: %i[organization_id id],
                    name: "ah_user_same_tenant"
    # actor は NULL 許容。MATCH SIMPLE 既定ゆえ actor_id NULL 時は非検査（Phase4 行を壊さない）。
    # MATCH FULL にしないこと（org 非NULL/actor NULL の正当な行を拒否する）
    add_foreign_key :attendance_histories, :users,
                    column: %i[organization_id actor_id], primary_key: %i[organization_id id],
                    name: "ah_actor_same_tenant"

    # organization_id index は t.references が自動生成するため重複を避ける
    add_index :attendance_histories, %i[organization_id user_id event_date],
              name: "idx_ah_user_event_date"
    add_index :attendance_histories, %i[organization_id source_type source_id],
              name: "idx_ah_source"
    add_index :attendance_histories, %i[organization_id actor_id],
              name: "idx_ah_actor"

    # 不変防御 ③（fx が schema.rb へ create_function/create_trigger をダンプ）
    create_function :attendance_histories_immutable
    create_trigger :attendance_histories_no_mutate, on: :attendance_histories
    create_trigger :attendance_histories_no_truncate, on: :attendance_histories
  end
end
