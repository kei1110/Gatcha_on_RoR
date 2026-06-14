# frozen_string_literal: true

class CreateReasonTemplates < ActiveRecord::Migration[8.1]
  def change
    create_table :reason_templates do |t|
      t.references :organization, null: false, foreign_key: true
      t.string :label, null: false          # 管理用識別名（SPEC §4.16）
      t.string :template_text, null: false  # 挿入テキスト
      t.integer :applies_to, null: false    # enum: clock_change(0) / leave(1) / both(2)
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :reason_templates, %i[organization_id label], unique: true # マスタ name 規約と同型
    add_index :reason_templates, %i[organization_id id], unique: true
  end
end
