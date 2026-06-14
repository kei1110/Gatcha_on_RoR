# frozen_string_literal: true

class CreateCompanyCalendars < ActiveRecord::Migration[8.1]
  def change
    create_table :company_calendars do |t|
      t.references :organization, null: false, foreign_key: true
      t.date :date, null: false
      t.integer :day_type, null: false
      t.string :name
      t.string :fiscal_year, null: false
      t.boolean :counts_as_paid_leave, null: false, default: false

      t.timestamps
    end

    # テナント内 1 日 1 レコード（SPEC §4.7）— upsert の衝突キー。レース時も衝突相手は
    # 同一テナント内に限定され、他テナントへの書き込みは DB レベルで不可能
    add_index :company_calendars, [ :organization_id, :date ], unique: true
    # 複合 FK の前提となる unique index（この順序が必須 — プロジェクト規約・既存 3 テーブルと同型）
    add_index :company_calendars, [ :organization_id, :id ], unique: true
  end
end
