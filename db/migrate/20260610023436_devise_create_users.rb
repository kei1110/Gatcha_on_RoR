class DeviseCreateUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :users do |t|
      t.references :organization, null: false, foreign_key: true
      ## Database authenticatable
      t.string :email, null: false
      t.string :encrypted_password, null: false, default: ""
      ## Recoverable
      t.string :reset_password_token
      t.datetime :reset_password_sent_at
      ## Rememberable
      t.datetime :remember_created_at
      ## Trackable
      t.integer :sign_in_count, null: false, default: 0
      t.datetime :current_sign_in_at
      t.datetime :last_sign_in_at
      t.string :current_sign_in_ip
      t.string :last_sign_in_ip
      ## Lockable
      t.integer :failed_attempts, null: false, default: 0
      t.string :unlock_token
      t.datetime :locked_at
      ## Domain（SPEC §4.3）
      t.string :name, null: false
      t.string :employee_code, null: false
      t.integer :role, null: false, default: 0
      t.bigint :manager_id
      t.boolean :exempt_from_overtime, null: false, default: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end

    # テナント内一意（グローバル unique は張らない・SPEC §3.2）
    add_index :users, [ :organization_id, :email ], unique: true
    add_index :users, [ :organization_id, :employee_code ], unique: true
    # トークン列はグローバル unique を維持（SPEC §3.2(3)）
    add_index :users, :reset_password_token, unique: true
    add_index :users, :unlock_token, unique: true
    # 複合 FK の前提となる unique index（この順序が必須）
    add_index :users, [ :organization_id, :id ], unique: true
    add_index :users, :manager_id
    # 上長の同一テナント強制（SPEC §3.6(2) の DB 層）
    add_foreign_key :users, :users,
                    column: [ :organization_id, :manager_id ],
                    primary_key: [ :organization_id, :id ]
  end
end
