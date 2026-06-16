# frozen_string_literal: true

# fx バグ修正: トリガーの schema.rb dump 順序が非決定的
#
# 原因: fx 0.11.0 の Fx::Adapters::Postgres::Triggers::TRIGGERS_WITH_DEFINITIONS_QUERY は
#   `ORDER BY pc.oid`（= トリガーが属する **テーブル** の OID）でしか並べていない。
#   同一テーブルに複数トリガーがあると pc.oid が同値になりタイブレークが無く、
#   行順は PostgreSQL の物理ヒープ順（未規定）に委ねられる。
#
# 影響: attendance_histories の no_mutate / no_truncate 2 トリガーの dump 順が
#   PG バージョン・クエリ実行ごとに揺れ、db:schema:dump で schema.rb に
#   無意味な diff（churn）が出る。PG17→18 アップグレードで実踏（同一クエリで
#   [no_mutate, no_truncate] と [no_truncate, no_mutate] の両方を観測）。
#
# 修正: ORDER BY に `pt.tgname` タイブレークを足して決定化する。
#   トリガー名は一意ゆえ版に依らず安定し、schema.rb の順序が固定される。
#
# upstream 状況: fx 0.11.0 時点で ORDER BY pc.oid のまま。本パッチは frozen 定数を
#   remove_const → const_set で同等＋タイブレーク版に置換する（self.all が
#   実行時に定数を参照するため有効）。fx 更新時に triggers.rb の ORDER BY が
#   tgname を含むよう修正されていたら本ファイルを削除すること。
#
# 参照: db/triggers/attendance_histories_no_*.sql。docs/RAILS_GOTCHAS.md に記録済み。

require "fx"

Fx::Adapters::Postgres::Triggers.tap do |klass|
  patched_query = <<~SQL.freeze
    SELECT
        pt.tgname AS name,
        pg_get_triggerdef(pt.oid) AS definition
    FROM pg_trigger pt
    JOIN pg_class pc
        ON (pc.oid = pt.tgrelid)
    JOIN pg_proc pp
        ON (pp.oid = pt.tgfoid)
    JOIN pg_namespace pn
        ON pn.oid = pc.relnamespace
    WHERE pn.nspname = ANY (current_schemas(false))
        AND pt.tgname NOT ILIKE '%constraint%'
        AND pt.tgname NOT ILIKE 'pg%'
    ORDER BY pc.oid, pt.tgname;
  SQL

  klass.send(:remove_const, :TRIGGERS_WITH_DEFINITIONS_QUERY)
  klass.const_set(:TRIGGERS_WITH_DEFINITIONS_QUERY, patched_query)
end
