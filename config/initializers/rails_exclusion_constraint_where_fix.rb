# Rails 8 バグ修正: exclusion constraint の WHERE 句解析が 2 文字ずつ剥がして壊す
#
# 原因: schema_statements.rb の `predicate.from(2).to(-3)` は
#   pg_get_constraintdef が返す WHERE 節を常に二重括弧 `((expr))` と仮定している。
#   実際の括弧数は PG バージョンではなく **述語の形状** に依存する（PG 17.10 で確認）:
#     - 裸のカラム参照 `active` → `WHERE (active)`（単一括弧）→ from(2).to(-3) が
#       2 文字ずつ剥がして `ctiv` に壊す
#     - 演算子式 `b > 1`      → `WHERE ((b > 1))`（二重括弧）→ 既存コードでも動く
#
# 影響: 裸カラム述語（where: "active" 等）の exclusion constraint を schema:dump
#   すると where: 値が壊れ、schema:load が PG::UndefinedColumn で失敗する。
#
# 修正: `from(1).to(-2)` で外側 1 対だけ剥がす。
#   - 裸カラム: `(active)` → `active`（正しい）
#   - 演算子式: `((b > 1))` → `(b > 1)` → Rails が再度 `(...)` で包んで
#     `((b > 1))` に戻るため、ラウンドトリップは両形状で安定
#
# upstream 状況: Rails main は 2026-06-12 時点でも `from(2).to(-3)` のまま（未修正）。
#   そのためバージョンガードは「8 系なら適用」とする。upstream が修正された後に
#   本パッチが適用されても、同等の正しいロジックで上書きするだけなので無害。
#   Rails メジャーアップ時に upstream の `exclusion_constraints`
#   （schema_statements.rb の `predicate.from(2).to(-3)` 付近）を再確認し、
#   修正されていたら本ファイルを削除すること。
#
# 参照: db/migrate/20260612000100_create_user_work_patterns.rb の
#       add_exclusion_constraint で発覚。docs/RAILS_GOTCHAS.md に記録済み。

require "active_record/connection_adapters/postgresql_adapter"

if ActiveRecord::VERSION::MAJOR == 8
  module ExclusionConstraintWhereFix
    def exclusion_constraints(table_name)
      scope = quoted_scope(table_name)

      exclusion_info = internal_exec_query(<<-SQL, "SCHEMA")
        SELECT conname, pg_get_constraintdef(c.oid) AS constraintdef, c.condeferrable, c.condeferred
        FROM pg_constraint c
        JOIN pg_class t ON c.conrelid = t.oid
        JOIN pg_namespace n ON n.oid = c.connamespace
        WHERE c.contype = 'x'
          AND t.relname = #{scope[:name]}
          AND n.nspname = #{scope[:schema]}
      SQL

      exclusion_info.map do |row|
        method_and_elements, predicate = row["constraintdef"].split(" WHERE ")
        method_and_elements_parts = method_and_elements.match(/EXCLUDE(?: USING (?<using>\S+))? \((?<expression>.+)\)/)
        predicate.remove!(/ DEFERRABLE(?: INITIALLY (?:IMMEDIATE|DEFERRED))?/) if predicate
        # PATCH: 元コードは from(2).to(-3)（常に二重括弧前提）。裸カラム述語は
        #        単一括弧で返るため、外側 1 対だけ剥がす from(1).to(-2) が正解
        predicate = predicate.from(1).to(-2) if predicate # strip 1 opening and closing parenthesis

        deferrable = extract_constraint_deferrable(row["condeferrable"], row["condeferred"])

        options = {
          name: row["conname"],
          using: method_and_elements_parts["using"].to_sym,
          where: predicate,
          deferrable: deferrable
        }

        ActiveRecord::ConnectionAdapters::PostgreSQL::ExclusionConstraintDefinition.new(
          table_name, method_and_elements_parts["expression"], options
        )
      end
    end
  end

  ActiveRecord::ConnectionAdapters::PostgreSQL::SchemaStatements.prepend(ExclusionConstraintWhereFix)
end
