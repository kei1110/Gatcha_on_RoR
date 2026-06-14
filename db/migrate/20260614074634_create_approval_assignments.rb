# frozen_string_literal: true

class CreateApprovalAssignments < ActiveRecord::Migration[8.1]
  def change
    create_table :approval_assignments do |t|
      t.references :organization, null: false, foreign_key: true
      t.references :approvable, polymorphic: true, null: false
      t.integer :position, null: false
      t.bigint :approver_id, null: false
      t.integer :decision, null: false, default: 0
      t.timestamptz :acted_at
      t.text :comment

      t.timestamps
    end

    add_index :approval_assignments,
              [ :organization_id, :approvable_type, :approvable_id, :position ],
              unique: true, name: "index_approval_assignments_unique_stage"
    add_index :approval_assignments,
              [ :organization_id, :approver_id, :decision ],
              name: "index_approval_assignments_on_approver"

    # 承認者のクロステナント参照を DB レベルで排除（users の [organization_id, id] unique index へ複合 FK）
    add_foreign_key :approval_assignments, :users,
                    column: [ :organization_id, :approver_id ], primary_key: [ :organization_id, :id ]
  end
end
