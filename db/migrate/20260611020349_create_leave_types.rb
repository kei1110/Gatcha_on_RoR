class CreateLeaveTypes < ActiveRecord::Migration[8.1]
  def change
    create_table :leave_types do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :name, null: false
      t.integer :system_type, null: false
      t.boolean :allow_half_day, null: false, default: false
      t.boolean :paid_leave, null: false, default: false
      t.text :description
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    # テナント内一意（SPEC §3.1）
    add_index :leave_types, [ :organization_id, :name ], unique: true
    # 複合 FK の前提となる unique index（この順序が必須 — Phase 2 の LeaveRequest 等が参照）
    add_index :leave_types, [ :organization_id, :id ], unique: true
  end
end
