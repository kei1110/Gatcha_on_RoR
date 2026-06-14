# frozen_string_literal: true

class CreateWorkPatterns < ActiveRecord::Migration[8.1]
  def change
    create_table :work_patterns do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.time :start_time, null: false
      t.time :end_time, null: false
      t.integer :break_minutes, null: false
      t.decimal :standard_work_hours, precision: 4, scale: 2, null: false
      t.boolean :night_shift, null: false, default: false
      t.boolean :flextime, null: false, default: false
      t.time :core_time_start
      t.time :core_time_end
      t.integer :morning_half_break_minutes
      t.integer :afternoon_half_break_minutes
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    # テナント内一意（SPEC §3.1）
    add_index :work_patterns, [ :organization_id, :name ], unique: true
    # 複合 FK の前提となる unique index（この順序が必須 — 0b-4 の UserWorkPattern が参照）
    add_index :work_patterns, [ :organization_id, :id ], unique: true
  end
end
