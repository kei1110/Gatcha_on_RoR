# frozen_string_literal: true

class AddPurposeToApprovalAssignments < ActiveRecord::Migration[8.1]
  def change
    add_column :approval_assignments, :purpose, :integer, null: false, default: 0  # approval:0 / withdrawal:1

    remove_index :approval_assignments, column: %i[organization_id approvable_type approvable_id position], name: "index_approval_assignments_unique_stage"
    add_index :approval_assignments,
              %i[organization_id approvable_type approvable_id purpose position],
              unique: true, name: "index_approval_assignments_unique_stage"
  end
end
