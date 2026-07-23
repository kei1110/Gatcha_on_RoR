# frozen_string_literal: true

require "rails_helper"

RSpec.describe Clockings::IntervalCheck do
  let(:org)  { create(:organization) } # TZ 既定 Asia/Tokyo・rest_interval_hours 既定 11
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  # 前日 clocked_out（clock_out 明示）→ 当日 working（clock_in 明示）を作る
  def build_pair(prev_out:, today_in:)
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, :done, user:, work_date: prev_out.in_time_zone(org.time_zone).to_date,
             clock_in: prev_out - 9.hours, clock_out: prev_out)
      create(:attendance_record, user:, work_date: today_in.in_time_zone(org.time_zone).to_date,
             clock_in: today_in, status: :working)
    end
  end

  it "不足時: AR.note 追記 + AttendanceHistory(interval_shortage・actor 付き) を記録し violation を返す" do
    record = build_pair(prev_out: Time.utc(2026, 6, 1, 13),          # JST 6/1 22:00 退勤
                        today_in: Time.utc(2026, 6, 1, 23))          # JST 6/2 08:00 出勤（休息 10h）
    result = nil
    expect {
      result = described_class.call(record:, actor: user)
    }.to change { AttendanceHistory.unscoped.where(event_type: :interval_shortage).count }.by(1)

    expect(result).to be_violation
    expect(result.shortage_minutes).to eq(60)
    history = AttendanceHistory.unscoped.where(event_type: :interval_shortage).last
    expect(history.actor_id).to eq(user.id)
    expect(history.event_date).to eq(record.work_date)
    expect(record.reload.note).to include("勤務間インターバル不足")
    expect(record.note).to include("不足 60 分")
  end

  it "非違反（11h ちょうど）: 何も記録せず violation false（AH 0 件・note 不変）" do
    record = build_pair(prev_out: Time.utc(2026, 6, 1, 12),          # JST 6/1 21:00 退勤
                        today_in: Time.utc(2026, 6, 1, 23))          # JST 6/2 08:00 出勤（休息 11h）
    result = nil
    expect {
      result = described_class.call(record:, actor: user)
    }.not_to change { AttendanceHistory.unscoped.count }

    expect(result).not_to be_violation
    expect(record.reload.note).to be_nil
  end

  it "直前退勤は「直近の clock_out を持つ AR」を時刻降順で解決する（夜勤の翌々日判定を prev_day 固定にしない・§13④）" do
    ActsAsTenant.with_tenant(org) do
      # 3 日前にも退勤があるが、直近は前日夜勤明け（6/2 08:00 JST 退勤）
      create(:attendance_record, :done, user:, work_date: Date.new(2026, 5, 30),
             clock_in: Time.utc(2026, 5, 30, 0), clock_out: Time.utc(2026, 5, 30, 9))
      create(:attendance_record, :done, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 13), clock_out: Time.utc(2026, 6, 1, 23)) # 夜勤明け JST 6/2 08:00
    end
    record = ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 3),
             clock_in: Time.utc(2026, 6, 3, 0), status: :working)                     # JST 6/3 09:00 出勤
    end
    result = described_class.call(record:, actor: user)
    # 直近退勤 JST 6/2 08:00 → 出勤 JST 6/3 09:00 = 25h ≥ 11h → 非違反（5/30 と比較したら違反になるが、それは誤り）
    expect(result).not_to be_violation
  end

  it "退勤記録が 1 件も無ければ非違反（初回出勤）" do
    record = ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 0), status: :working)
    end
    expect(described_class.call(record:, actor: user)).not_to be_violation
  end

  it "org 設定の閾値を尊重する（rest_interval_hours=8 なら休息 10h は非違反）" do
    ActsAsTenant.with_tenant(org) { org.setting.update!(rest_interval_hours: 8) }
    record = build_pair(prev_out: Time.utc(2026, 6, 1, 13), today_in: Time.utc(2026, 6, 1, 23)) # 休息 10h
    expect(described_class.call(record:, actor: user)).not_to be_violation
  end

  it "他テナントの actor は昇格前ガードで拒否（RAILS_GOTCHAS「with_tenant は昇格プリミティブ」）" do
    other_org  = create(:organization, subdomain: "other")
    other_user = ActsAsTenant.with_tenant(other_org) { create(:user) }
    record = build_pair(prev_out: Time.utc(2026, 6, 1, 13), today_in: Time.utc(2026, 6, 1, 23))
    expect {
      described_class.call(record:, actor: other_user)
    }.to raise_error(ArgumentError, /actor org mismatch/)
    expect(AttendanceHistory.unscoped.where(event_type: :interval_shortage).count).to eq(0)
  end

  it "note 追記は既存 note を保全する（Clockings.append_note の ； 連結）" do
    record = build_pair(prev_out: Time.utc(2026, 6, 1, 13), today_in: Time.utc(2026, 6, 1, 23))
    ActsAsTenant.with_tenant(org) { record.update!(note: "既存メモ") }
    described_class.call(record:, actor: user)
    expect(record.reload.note).to start_with("既存メモ；")
  end
end
