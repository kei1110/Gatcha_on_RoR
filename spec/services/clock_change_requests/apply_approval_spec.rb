# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClockChangeRequests::ApplyApproval do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:approver) { create(:user, :manager_role, organization: org) }
  let(:user) { create(:user, organization: org) }
  let(:pattern) { create(:work_pattern, start_time: "09:00", end_time: "18:00", break_minutes: 60) }
  # clocked_out・JST 10:00 出勤（遅刻）・JST 18:00 退勤
  let(:record) do
    create(:attendance_record, user:, work_pattern: pattern, status: :clocked_out,
           work_date: Date.new(2026, 6, 1),
           clock_in: Time.utc(2026, 6, 1, 1), clock_out: Time.utc(2026, 6, 1, 9))
      .tap { |r| Clockings::Recalculate.call(record: r) }
  end

  def ccr(**attrs)
    create(:clock_change_request, requester: user, attendance_record: record,
           original_clock_in: record.clock_in, original_clock_out: record.clock_out, **attrs)
  end

  def apply(c) = described_class.call(clock_change_request: c, acting_user: approver)

  it "clock_in を JST 09:00 へ修正 → 記録更新 + 再計算（遅刻解消）" do
    apply(ccr(change_type: :clock_in, new_clock_in: Time.utc(2026, 6, 1, 0)))  # JST 09:00
    expect(record.reload.clock_in).to eq(Time.utc(2026, 6, 1, 0))
    expect(record.is_late).to be false   # 09:00 出勤ゆえ遅刻でない
  end

  it "clock_out のみ変更（clock_in は不変）" do
    apply(ccr(change_type: :clock_out, new_clock_in: nil, new_clock_out: Time.utc(2026, 6, 1, 10)))
    expect(record.reload.clock_out).to eq(Time.utc(2026, 6, 1, 10))
    expect(record.clock_in).to eq(Time.utc(2026, 6, 1, 1))
  end

  it "前後値つき clock_change_approved 履歴を 1 行記録（actor=承認者・source=ccr）" do
    c = ccr(change_type: :clock_in, new_clock_in: Time.utc(2026, 6, 1, 0))
    expect { apply(c) }.to change { AttendanceHistory.where(event_type: :clock_change_approved).count }.by(1)
    h = AttendanceHistory.find_by(event_type: :clock_change_approved)
    expect(h).to have_attributes(actor_id: approver.id, user_id: user.id,
                                 previous_clock_in: Time.utc(2026, 6, 1, 1),
                                 new_clock_in: Time.utc(2026, 6, 1, 0),
                                 previous_is_late: true, new_is_late: false)
  end

  it "status は不変（clocked_out のまま）" do
    apply(ccr(change_type: :clock_in, new_clock_in: Time.utc(2026, 6, 1, 0)))
    expect(record.reload.status).to eq("clocked_out")
  end

  describe "§7.4 競合チェック" do
    it "original が現在と一致すれば承認成功（未変更で偽 ConflictError を出さない）" do
      expect { apply(ccr(new_clock_in: Time.utc(2026, 6, 1, 0))) }.not_to raise_error
    end

    it "申請後に記録が変わっていたら ConflictError + rollback（記録/履歴不変）" do
      c = ccr(new_clock_in: Time.utc(2026, 6, 1, 0))
      record.update_column(:clock_in, Time.utc(2026, 6, 1, 2))   # 申請後に第三者が変更（JST 11:00）
      expect { apply(c) }.to raise_error(Approvals::ConflictError)
      expect(record.reload.clock_in).to eq(Time.utc(2026, 6, 1, 2))   # 巻き戻し（CCR の変更は入らない）
      expect(AttendanceHistory.where(event_type: :clock_change_approved).count).to eq(0)
    end
  end
end
