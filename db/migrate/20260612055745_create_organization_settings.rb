class CreateOrganizationSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :organization_settings do |t|
      # テナント毎 1 行（unique index が Organization#setting の create_or_find_by! の前提・0b-5 設計 §1）
      t.references :organization, null: false, foreign_key: true, index: { unique: true }
      t.integer :closing_day, null: false, default: 31          # 締め日（31 = 月末・SPEC §4.15）
      t.integer :submit_deadline_days, null: false, default: 5  # 翌月の提出期限（日数）

      t.timestamps
    end

    # プロジェクト規約（将来の複合 FK 参照先）
    add_index :organization_settings, %i[organization_id id], unique: true
  end
end
