# frozen_string_literal: true

class CreateAbsenceCandidates < ActiveRecord::Migration[8.1]
  def change
    create_table :absence_candidates do |t|
      t.references :organization, null: false, foreign_key: true # テナントルートは単純 FK
      t.bigint :user_id, null: false                             # 複合 FK ゆえ references にしない
      t.date :target_date, null: false                           # 未打刻の対象日
      t.date :notified_on                                        # null = 未通知（notify-once・§4.4）
      t.timestamps                                               # created_at = 検知日（detected_on は持たない・§10④）
    end

    add_index :absence_candidates, %i[organization_id id], unique: true # 複合 FK 標的（idiom 統一）
    add_index :absence_candidates, %i[organization_id user_id target_date],
              unique: true, name: "idx_absence_candidates_unique" # 同一候補の二重生成を排除
    add_index :absence_candidates, %i[organization_id user_id],
              name: "idx_absence_candidates_org_user" # 一覧/解決スキャン
    add_foreign_key :absence_candidates, :users,
                    column: %i[organization_id user_id], primary_key: %i[organization_id id]
  end
end
