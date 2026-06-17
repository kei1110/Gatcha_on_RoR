# frozen_string_literal: true

class CreateLeaveBalances < ActiveRecord::Migration[8.1]
  def change
    create_table :leave_balances do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.bigint :leave_type_id, null: false
      t.string :fiscal_year, null: false
      t.decimal :granted_days, precision: 6, scale: 2, null: false, default: 0
      t.decimal :carry_over_days, precision: 6, scale: 2, null: false, default: 0
      t.decimal :used_days, precision: 6, scale: 2, null: false, default: 0   # 2-2b approve の専有 writer
      t.date :granted_on   # 5 日義務起点（§8.6）。paid×annual はモデル検証で必須

      t.timestamps
    end

    # クロステナント参照を DB 層で遮断（user_work_patterns と同じ複合 FK・§3.6）
    add_foreign_key :leave_balances, :users,
                    column: [ :organization_id, :user_id ], primary_key: [ :organization_id, :id ]
    add_foreign_key :leave_balances, :leave_types,
                    column: [ :organization_id, :leave_type_id ], primary_key: [ :organization_id, :id ]

    add_index :leave_balances, %i[organization_id id], unique: true   # 規約（将来の複合 FK 参照先）
    add_index :leave_balances, %i[organization_id user_id leave_type_id fiscal_year],
              unique: true, name: "index_leave_balances_unique"
    add_index :leave_balances, %i[organization_id user_id]
  end
end
