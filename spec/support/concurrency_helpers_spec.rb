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
  end
end
