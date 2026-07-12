# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConcurrencyHelpers do
  include described_class

  describe "#hold_row_lock" do
    self.use_transactional_tests = false

    after { truncate_all_tables! }

    it "別接続で対象行の FOR UPDATE を保持し、その間の DELETE を待たせる" do
      org  = FactoryBot.create(:organization, subdomain: "helper-probe")
      rec  = nil
      ActsAsTenant.with_tenant(org) do
        user = FactoryBot.create(:user)
        rec  = FactoryBot.create(:attendance_record, user:, work_date: Date.new(2026, 7, 1),
                                                     clock_in: Time.utc(2026, 7, 1, 0))
      end

      hold_row_lock(AttendanceRecord, rec.id, org:) do
        ActsAsTenant.with_tenant(org) do
          ActiveRecord::Base.connection.execute("SET lock_timeout = '300ms'")
          expect { AttendanceRecord.where(id: rec.id).delete_all }
            .to raise_error(ActiveRecord::LockWaitTimeout)
        ensure
          ActiveRecord::Base.connection.execute("SET lock_timeout = DEFAULT")
        end
      end
    end

    it "対象行が存在しない場合はハングせず ActiveRecord::RecordNotFound を伝播する" do
      org = FactoryBot.create(:organization)

      # 保持スレッドが locked << :ok に到達する前に死ぬケース。単に raise_error だけを
      # 見ると、修正前の実装（2 queue を見比べる版）でも ensure 内の
      # `raise error.pop unless ...` が Timeout::Error を RecordNotFound にすり替えて
      # しまい discriminative でない（実測済み）。ハングの有無は経過時間で判定する。
      error   = nil
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        Timeout.timeout(2) { hold_row_lock(AttendanceRecord, 999_999, org:) { } }
      rescue StandardError => e
        error = e
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(error).to be_a(ActiveRecord::RecordNotFound)
      expect(elapsed).to be < 1 # 秒。修正前は locked.pop が Timeout(2s) までハングする
    end
  end

  describe "#truncate_all_tables!" do
    context "非トランザクションの後片付け（本来の使い方）" do
      self.use_transactional_tests = false

      it "対象の複数テーブルの行を実際に空にする" do
        org = FactoryBot.create(:organization)
        ActsAsTenant.with_tenant(org) { FactoryBot.create(:user) }

        # User は acts_as_tenant スコープ対象（既定 scope は現在の tenant のみを見る）ため、
        # truncate_all_tables! が全 org 横断で消したことを見るには unscoped で数える。
        expect { truncate_all_tables! }
          .to change(Organization, :count).to(0)
          .and change { User.unscoped.count }.to(0)
      end
    end

    context "行が実在し削除不能なテーブルが残る場合" do
      # attendance_histories は §4.14 の追記専用トリガーで DELETE も TRUNCATE も恒久的に
      # 拒否する。ここで作る行はテスト後も物理的に消せないため、恒久的にテスト DB へ
      # 残さないようあえて transactional test（既定の use_transactional_tests = true）の
      # ままにし、example 終了時の自動 ROLLBACK で後片付けする。
      it "attendance_histories に行がある場合は raise し、外側の transaction を汚さない" do
        org  = FactoryBot.create(:organization)
        user = ActsAsTenant.with_tenant(org) { FactoryBot.create(:user) }
        ActsAsTenant.with_tenant(org) do
          AttendanceHistory.create!(user:, event_date: Date.new(2026, 7, 1), event_type: :clock_in)
        end

        expect { truncate_all_tables! }
          .to raise_error(/truncate_all_tables!: 削除できないテーブルが残っています/)

        # transaction がまだ生きている（poison されていない）ことの証明。
        # ここで例外が飛ぶようだと外側の transaction が汚染されている。
        expect(Organization.count).to be >= 1
      end
    end
  end

  describe "#purge_append_only_and_truncate!" do
    self.use_transactional_tests = false

    it "attendance_histories を含め全テーブルを空にし、トリガーを再有効化した状態で終える" do
      org  = FactoryBot.create(:organization)
      user = ActsAsTenant.with_tenant(org) { FactoryBot.create(:user) }
      ActsAsTenant.with_tenant(org) do
        AttendanceHistory.create!(user:, event_date: Date.new(2026, 7, 1), event_type: :clock_in)
      end

      purge_append_only_and_truncate!

      expect(AttendanceHistory.count).to eq(0)
      expect(Organization.count).to eq(0)
      expect(User.unscoped.count).to eq(0)

      conn = ActiveRecord::Base.connection
      tgenabled = conn.select_value(
        "SELECT tgenabled FROM pg_trigger WHERE tgname = 'attendance_histories_no_mutate'"
      )
      expect(tgenabled).to eq("O")
      disabled_count = conn.select_value("SELECT count(*) FROM pg_trigger WHERE tgenabled = 'D'").to_i
      expect(disabled_count).to eq(0)
    end

    it "spec/support/tenant.rb の環境 tenant（本 helper の呼び出し元では通常未使用）も片付ける" do
      # 環境 tenant は何にも参照されないため truncate_all_tables! の一括 DELETE で本来
      # 消せるはずだが、追記専用テーブルを参照する他の org が同居すると organizations
      # テーブルごと削除不能になり巻き添えを食う（4-2c-3a で実測）。個別削除で防ぐ。
      ambient = FactoryBot.create(:organization)
      ActsAsTenant.test_tenant = ambient

      purge_append_only_and_truncate!

      expect(Organization.where(id: ambient.id)).not_to exist
    end

    it "DELETE が途中失敗してもトリガーを無効化したまま残さない（安全性の核心）" do
      # このメソッドの安全性の根拠＝「DISABLE→DELETE→ENABLE を単一 transaction に収め、
      # 例外時は DISABLE ごと ROLLBACK される」。DISABLE 後・ENABLE 前に DELETE を失敗させ、
      # 事後にトリガーが再有効化（tgenabled='O'）されていることを固定する。将来 DISABLE/DELETE/
      # ENABLE を別 transaction へ分離する等で安全性を壊すと、この example だけが赤くなる。
      conn = ActiveRecord::Base.connection
      allow(conn).to receive(:execute).and_call_original
      allow(conn).to receive(:execute)
        .with("DELETE FROM attendance_histories").and_raise(StandardError, "boom")

      expect { purge_append_only_and_truncate! }.to raise_error(StandardError, "boom")

      tgenabled = conn.select_value(
        "SELECT tgenabled FROM pg_trigger WHERE tgname = 'attendance_histories_no_mutate'"
      )
      expect(tgenabled).to eq("O")
    end
  end
end
