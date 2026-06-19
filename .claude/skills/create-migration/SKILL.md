---
name: create-migration
description: 本リポジトリのマルチテナント migration 規約（複合 FK [organization_id, id] 標的・partial unique index・acts_as_tenant 列・index 命名）に沿った migration の作り方の参照に使う。TRIGGER - 新テーブル/カラム/index/FK を追加する migration を書くとき / テナント帰属モデルや自己参照・ユーザー参照 FK を持つテーブルを足すとき / ユーザーが「create-migration」「migration 生成」「複合 FK」「partial unique」に言及 / Claude 自身が migration を新規作成する直前。DO NOT TRIGGER - 既存 migration の軽微修正 / data-only migration（バックフィル）/ schema.rb の確認のみ。
---

# create-migration — マルチテナント複合 FK 規約に沿った migration

`block-schema-edit` フックが `db/schema.rb` の手編集を禁止しているため、スキーマ変更は**必ず migration 経由**。本リポジトリはテナント帰属を DB 最終防衛まで貫くため、通常の `t.references ... foreign_key: true` ではなく**複合 FK `[organization_id, id]` 標的**を多用する。この非自明な idiom を取りこぼすとテナント越境が DB レベルで素通りする（SPEC §3.6）。本 skill はその定型を規定する。

見本: `db/migrate/*_create_clock_change_requests.rb` / `*_create_holiday_work_requests.rb` / `*_create_leave_requests.rb`。

## 生成フロー（手編集禁止ゆえ generate → body 差し替え）

```bash
bin/rails generate migration CreateHolidayWorkRequests   # or AddXxxToYyy
# 生成された db/migrate/<ts>_*.rb の body を下記 idiom で全置換
bin/rails db:migrate && bin/rails db:test:prepare         # schema.rb は自動更新（手で触らない）
```

`db:test:prepare` を忘れると test DB に反映されず spec が落ちる。`<ts>` は generate が確定する実タイムスタンプ。

## 1. テナント帰属テーブル（最頻出の型）

```ruby
class CreateHolidayWorkRequests < ActiveRecord::Migration[8.1]
  def change
    create_table :holiday_work_requests do |t|
      t.references :organization, null: false, foreign_key: true   # テナントルートは単純 FK で可
      t.bigint :requester_id, null: false                          # ユーザー参照は複合 FK（後述）ゆえ references にしない
      t.date :work_date, null: false
      t.bigint :compensation_leave_type_id, null: false            # 他マスタ参照も複合 FK
      t.text :reason
      t.integer :approval_status, null: false, default: 0          # enum は integer・default は初期状態の整数
      t.timestamps
    end

    add_index :holiday_work_requests, %i[organization_id id], unique: true   # 複合 FK の標的（後述）
    add_index :holiday_work_requests, %i[organization_id requester_id approval_status],
              name: "idx_hwr_requester_status"                               # 長い index 名は name: で明示
    add_foreign_key :holiday_work_requests, :users,
                    column: %i[organization_id requester_id], primary_key: %i[organization_id id]
    add_foreign_key :holiday_work_requests, :leave_types,
                    column: %i[organization_id compensation_leave_type_id], primary_key: %i[organization_id id]
  end
end
```

### なぜ複合 FK `[organization_id, id]` か（最重要・SPEC §3.6）
- ユーザー参照（`requester_id` / `manager_id` / `approver_id`）や他マスタ参照を**単純 FK**（`→ users(id)`）にすると、`organization_id` は自テナントなのに `requester_id` だけ他テナントの id、という改竄 POST が DB を素通りする。
- 複合 FK `(organization_id, requester_id) → users(organization_id, id)` にすると「同一テナント内の id」しか刺さらず、DB が越境を拒否する。
- 前提: 参照先テーブル（`users` / `leave_types` 等）に `add_index [organization_id, id], unique: true`（複合 PK 相当の一意制約）が**既にある**こと。新テーブルにも自分宛て参照のために同 index を張る。
- model 側の `xxx_must_belong_to_same_organization`（ID 基点 fail-closed）と**二層**で守る（migration だけ／model だけは不可）。

## 2. partial unique index（条件付き一意・enum 整数依存に注意）

「applying / approved の間だけ重複禁止、却下・取消後は再申請可」のような条件付き一意は partial unique index で表現する:

```ruby
add_index :holiday_work_requests, %i[organization_id requester_id work_date],
          unique: true, where: "approval_status IN (0, 1)", name: "idx_hwr_active_unique"
```

- **`where` 句の生整数 `0, 1` は enum マッピングに依存**（`approval_status` の applying=0 / approved=1）。enum を append-only/凍結にしておくこと。コメントで依存を明示。
- model 側に同等の述語バリデーション（`no_duplicate_active_request` 等）を置き、**DB index = 並行 TOCTOU の真の防衛線 / model = UX 用 422** と役割を分ける。
- **これは partial unique index であり exclusion constraint ではない** → `add_exclusion_constraint` の schema dump 罠（`from(2).to(-3)` 化）は**対象外**。`add_index ..., unique: true, where:` は schema round-trip 安定。

## 3. 期間重複の排他（exclusion constraint・別物・罠あり）

「同一ユーザーの割当期間が重ならない」のような範囲排他は exclusion constraint（`btree_gist` + `tsrange`）。これは partial unique と**別物で schema dump の罠がある**（PG18 でも不変・`config/initializers` で決定化済）。見本 `db/migrate/*_user_work_patterns*`・詳細は `docs/RAILS_GOTCHAS.md`「exclusion constraint」を必ず参照。

## 4. カラム追加（既存テーブル）

```ruby
class AddIsHolidayWorkToAttendanceRecords < ActiveRecord::Migration[8.1]
  def change
    # index は「実際に引くクエリが現れてから」その形状に合わせて張る（先回り index を作らない）
    add_column :attendance_records, :is_holiday_work, :boolean, null: false, default: false
  end
end
```

- boolean は `null: false, default: false`（NULL 三値を作らない）。
- **読み手のいない index を先回りで張らない**（YAGNI。集計クエリが確定した Phase でその形状に合わせる）。

## 5. fx トリガー / 関数（追記専用監査等）

不変トリガーはバージョン付き SQL（`db/functions/*_v01.sql` 等）+ `fx` gem。dump 順の非決定性を `config/initializers/fx_trigger_dump_order_fix.rb` で決定化済。見本 `db/migrate/*attendance_histories*`・§4.14。

## チェックリスト（migration を書き終えたら）

- [ ] ユーザー参照・他マスタ参照は**複合 FK `[organization_id, xxx_id] → table(organization_id, id)`**にしたか（単純 FK にしていないか）
- [ ] テナント帰属テーブルに `add_index [organization_id, id], unique: true`（自分宛て複合 FK の標的）を張ったか
- [ ] 複合ユニーク / partial unique に `organization_id` を含めたか（DB 最終防衛）
- [ ] enum カラムは integer・partial index の `where` 整数依存をコメント明示したか
- [ ] model 側の `acts_as_tenant(:organization)` ＋ `xxx_must_belong_to_same_organization` と二層になっているか
- [ ] `bin/rails db:migrate && db:test:prepare` を実行し schema.rb が自動更新されたか（手編集していないか）
- [ ] models/migration に触れたゆえ `tenant-isolation-reviewer` を merge 前に回すか

<!-- Last verified: 2026-06-19 -->
