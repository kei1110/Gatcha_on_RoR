# frozen_string_literal: true

# 2 接続の並行テスト足場（4-2c-3a・RAILS_GOTCHAS「行ロックの競合テストは 2 接続が要る」）。
# 使う側の example group は `self.use_transactional_tests = false` を宣言し、after で `truncate_all_tables!` する。
module ConcurrencyHelpers
  # 別スレッド・別接続で model_class#id の行を FOR UPDATE で掴んだまま yield する。
  # yield 中はロックが保持され、yield 復帰後に解放してスレッドを join する。
  # test_tenant は Thread.current 局所ゆえ、保持スレッド内で with_tenant(org) を張り直す。
  #
  # 成功（:ok）・失敗（例外オブジェクト）は同一の queue（locked）へ積む。2 つの queue を
  # 見比べる設計（locked と error を別に持つ）は、保持スレッドが lock 取得前に死んだ場合に
  # 親が「見るべき queue」を取り違えて locked.pop で永久に待ち続ける（保持スレッドは
  # 既に error へ push して終了しているため誰も起こさない）。single queue 化でこのレースを消す。
  def hold_row_lock(model_class, id, org:)
    locked  = Queue.new
    release = Queue.new

    holder = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        ActsAsTenant.with_tenant(org) do
          model_class.transaction do
            model_class.lock.find(id) # SELECT ... FOR UPDATE
            locked << :ok
            release.pop               # commit させずに保持
          end
        end
      end
    rescue Exception => e # rubocop:disable Lint/RescueException -- ロック取得失敗も含め保持スレッドの死を親へ伝える
      locked << e
    end

    msg = locked.pop # ロック取得 or 失敗のどちらかが必ず届く
    raise msg if msg.is_a?(Exception)

    yield
  ensure
    release << :go
    holder.join
  end

  # 非トランザクション文脈の後片付け。disable_referential_integrity / truncate_tables を使わない
  # （ensure 欠如で FK・追記専用トリガーを恒久破壊し得る・RAILS_GOTCHAS）。
  #
  # TRUNCATE ではなく DELETE を使う。attendance_histories は追記専用（§4.14）で、TRUNCATE を
  # 無条件に拒否する文トリガー attendance_histories_no_truncate（FOR EACH STATEMENT）を持つ。
  # PostgreSQL の TRUNCATE は「参照 FK を持つテーブルが存在する」だけで対象への追加同時指定
  # （または CASCADE）を要求し、これは行の有無を問わない構造的な要求のため、
  # organizations/users を CASCADE 付きで TRUNCATE すると attendance_histories を巻き込み
  # 必ずこの trigger に衝突する（明示的に同時指定しても同じ・実測済み）。
  # 一方 DELETE は行が実在する場合にのみ FK 違反になり、attendance_histories_no_mutate は
  # FOR EACH ROW なので 0 件なら発火しない。本 helper が対象とする非トランザクションテスト
  # （履歴書き込みを伴わない行ロック検証）では安全に完走する。
  #
  # 依存順（子 → 親）は固定リストにせず、削除できたテーブルから外す総当たりで解決する
  # （schema 変更や migration 追加順に依存させない）。
  def truncate_all_tables!
    conn = ActiveRecord::Base.connection
    remaining = conn.tables - %w[schema_migrations ar_internal_metadata]

    until remaining.empty?
      deleted_any = false

      remaining = remaining.reject do |table|
        conn.execute("DELETE FROM #{conn.quote_table_name(table)}")
        deleted_any = true
        true
      rescue ActiveRecord::StatementInvalid
        false
      end

      unless deleted_any
        raise "truncate_all_tables!: 削除できないテーブルが残っています" \
              "（行が実在する追記専用テーブル等）: #{remaining.join(', ')}"
      end
    end
  end
end
