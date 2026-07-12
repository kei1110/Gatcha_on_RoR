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
end
