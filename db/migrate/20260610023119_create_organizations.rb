class CreateOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      t.string :subdomain, null: false
      t.string :time_zone, null: false, default: "Asia/Tokyo"
      t.integer :fiscal_year_end_month
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :organizations, :subdomain, unique: true
  end
end
