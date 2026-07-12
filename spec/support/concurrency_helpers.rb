# frozen_string_literal: true

# 2 接続の並行テスト足場（4-2c-3a・RAILS_GOTCHAS「行ロックの競合テストは 2 接続が要る」）。
# hold_row_lock は別接続が「未コミットのロック」を取る都合上、使う側の example group で
# `self.use_transactional_tests = false` を宣言し、after で `truncate_all_tables!` する必要がある。
# truncate_all_tables! 単体は SAVEPOINT で個別 DELETE を守るため transactional test（既定）でも
# 安全に呼べる（外側 tx を汚さない・#truncate_all_tables! の raise 系テストで実証）。
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
  #
  # 各 DELETE は `conn.transaction(requires_new: true)`（SAVEPOINT）で個別に包む。PostgreSQL は
  # 1 文が失敗すると「囲む transaction 全体」を abort 済みにし、以後の文は ROLLBACK まで
  # 全滅する。SAVEPOINT 無しだと、削除できない行（attendance_histories 等）に当たった時点で
  # 後続のテーブルも「たまたま同じ tx にいた」だけで巻き添えを食い、raise 時の一覧が不正確に
  # なる。加えて、この helper が transactional test（既定の use_transactional_tests = true）の
  # 中で呼ばれた場合、SAVEPOINT 無しでは外側の transaction そのものが汚染され、以降の
  # assertion が軒並み PG::InFailedSqlTransaction で壊れる（実測済み）。SAVEPOINT で失敗を
  # そのテーブルの DELETE だけに閉じ込め、外側 tx を無傷に保つ。
  def truncate_all_tables!
    conn = ActiveRecord::Base.connection
    remaining = conn.tables - %w[schema_migrations ar_internal_metadata]

    until remaining.empty?
      deleted_any = false

      remaining = remaining.reject do |table|
        conn.transaction(requires_new: true) do
          conn.execute("DELETE FROM #{conn.quote_table_name(table)}")
        end
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

  # truncate_all_tables! の拡張版。attendance_histories（§4.14 追記専用）に実際に行を書く
  # 非トランザクションテスト向け（4-2c-3a Task 2 レビュー Important — 各テストへ生 SQL を
  # コピペで増やさないための集約）。
  #
  # なぜ TRUNCATE でなくこの手順か: attendance_histories_no_mutate（FOR EACH ROW）は
  # UPDATE/DELETE を無条件に拒否する。truncate_all_tables! 単体は DELETE ベースだが、
  # このトリガーがある限り attendance_histories 自体は削除できず、それを参照する
  # organizations/users も FK でテーブルごと削除不能になり残り続ける（truncate_all_tables!
  # のコメント・docs/RAILS_GOTCHAS.md 194 行）。
  #
  # なぜ単一 transaction が安全か: DISABLE TRIGGER → DELETE → ENABLE TRIGGER を 1 つの
  # `conn.transaction do ... end` に収め、成功時のみ commit する。ALTER TABLE ... TRIGGER は
  # PostgreSQL では transactional DDL のため、途中で例外が起きれば DISABLE も含めて丸ごと
  # ROLLBACK され、無効化した状態のまま残ることはない。接続断（kill 等）で commit に届かな
  # かった場合も同様に未コミットのまま破棄される。これは `disable_referential_integrity` を
  # 素の（transaction で囲わない）DISABLE として使う罠（docs/RAILS_GOTCHAS.md 187〜191 行 —
  # 例外時に無効化だけが永続し以後の run で FK 検証テストが理由不明で赤くなる）とは異なる。
  #
  # 対象はテスト用データのみ。本番の 5 年法定保存（労基法 109 条・§4.14）には一切関与しない。
  #
  # spec/support/tenant.rb の before(:each) が作る環境 tenant（本 helper を使うテストでは
  # 通常未使用）も、何にも参照されないうちに個別削除しておく。truncate_all_tables! は
  # テーブル単位の一括 DELETE のため、追記専用テーブルを参照する行が organizations に
  # 1 つでも残っていると、無関係な環境 tenant までテーブルごと削除不能になり、連番
  # subdomain が別 spec の let(:org) と衝突し得る（4-2c-3a で実測）。
  def purge_append_only_and_truncate!
    Organization.where(id: ActsAsTenant.test_tenant&.id).delete_all

    conn = ActiveRecord::Base.connection
    conn.transaction do
      conn.execute("ALTER TABLE attendance_histories DISABLE TRIGGER attendance_histories_no_mutate")
      conn.execute("DELETE FROM attendance_histories")
      conn.execute("ALTER TABLE attendance_histories ENABLE TRIGGER attendance_histories_no_mutate")
    end

    truncate_all_tables!
  end
end
