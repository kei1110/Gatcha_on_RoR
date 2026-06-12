class CreateUserWorkPatterns < ActiveRecord::Migration[8.1]
  def change
    # bigint の = と daterange の && を 1 つの GiST インデックスに同居させるため必須
    enable_extension "btree_gist"

    create_table :user_work_patterns do |t|
      t.references :organization, null: false, foreign_key: true
      t.bigint :user_id, null: false
      t.bigint :work_pattern_id, null: false
      t.date :start_date, null: false
      t.date :end_date # null = 無期限（SPEC §4.6）
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    # クロステナント割当を DB 層で構造的に遮断（users.manager_id と同じ複合 FK パターン・SPEC §3.6）
    add_foreign_key :user_work_patterns, :users,
                    column: [ :organization_id, :user_id ], primary_key: [ :organization_id, :id ]
    add_foreign_key :user_work_patterns, :work_patterns,
                    column: [ :organization_id, :work_pattern_id ], primary_key: [ :organization_id, :id ]

    add_index :user_work_patterns, :user_id
    add_index :user_work_patterns, :work_pattern_id # WorkPattern 無効化ガードの参照クエリ用
    # プロジェクト規約（将来の複合 FK 参照先）。被参照予定は現状なし — 規約準拠のため（0b-4 設計 §1）
    add_index :user_work_patterns, %i[organization_id id], unique: true

    # 期間重複の最終防衛（TOCTOU 競合窓・mismatched with_tenant 時のモデル検証取りこぼしを拾う）。
    # organization_id WITH = は意味論上冗長（user_id 全域一意 + 複合 FK で単一テナント保証）だが
    # 「複合一意制約に organization_id を必ず含める」規約（SPEC §2.2）に整合させる。
    # daterange(s, e, '[]') は [s, e+1day) に正規化・end_date NULL は上限無限。
    # WHERE (active) で無効割当（誤登録の論理削除）は対象外 — 作り直しを妨げない
    add_exclusion_constraint :user_work_patterns,
      "organization_id WITH =, user_id WITH =, daterange(start_date, end_date, '[]') WITH &&",
      using: :gist, where: "active", name: "user_work_patterns_no_overlap"
  end
end
