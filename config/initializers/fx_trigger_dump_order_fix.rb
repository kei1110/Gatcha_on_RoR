# frozen_string_literal: true

# fx バグ修正: トリガーの schema.rb dump 順序が非決定的（同一テーブルに複数トリガーで churn）
#
# fx 0.11.0 の Triggers クエリは `ORDER BY pc.oid`（テーブルの OID）のみで並べ、
# 同一テーブルのトリガー群はタイブレークが無く、行順が PostgreSQL の物理ヒープ順
# （未規定）に揺れる。PG17→18 で実踏（同一クエリで [no_mutate, no_truncate] と
# 逆順の両方を観測）。
#
# 修正: Fx::Trigger は Comparable（`<=>` を name に委譲）ゆえ、Triggers.all の
# 戻り配列を name 昇順に sort して決定化する。SQL を複製しないため fx 本体の
# クエリ変更は透過的に流れ、fx が将来 ORDER BY を自前修正しても整列済み配列の
# 再整列（no-op）で無害（自己無害化）。既存 rails_exclusion_constraint_where_fix.rb
# と同じ prepend 流儀。
#
# 詳細・経緯は docs/RAILS_GOTCHAS.md「fx のトリガー dump 順序が非決定的」。

require "fx"

module FxTriggerStableOrder
  # @param connection [ActiveRecord::ConnectionAdapters::AbstractAdapter]
  # @return [Array<Fx::Trigger>] name 昇順で決定化したトリガー定義
  def all(connection)
    super.sort
  end
end

Fx::Adapters::Postgres::Triggers.singleton_class.prepend(FxTriggerStableOrder)
