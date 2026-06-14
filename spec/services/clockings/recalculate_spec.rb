# frozen_string_literal: true

require "rails_helper"

# 時刻リテラルは UTC・JST コメント併記（org 既定 TZ = Asia/Tokyo）
RSpec.describe Clockings::Recalculate do
  let(:org) { create(:organization) }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  def night_pattern
    ActsAsTenant.with_tenant(org) do
      create(:work_pattern, start_time: "22:00", end_time: "07:00", night_shift: true,
                            break_minutes: 60, standard_work_hours: 8)
    end
  end

  def create_record(pattern:, clock_in:, clock_out:)
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in:, clock_out:, status: :clocked_out, work_pattern: pattern)
    end
  end

  it "夜勤の 8 列を保存する（総合・HALF_UP 発火含む）" do
    record = create_record(pattern: night_pattern,
                           clock_in: Time.utc(2026, 6, 1, 13),       # JST 22:00
                           clock_out: Time.utc(2026, 6, 1, 22, 30))  # JST 翌 7:30
    described_class.call(record:)
    record.reload
    expect(record.actual_work_hours).to eq(8.5)            # 570 − 60 = 510 分
    expect(record.legal_overtime_hours).to eq(0.5)         # 510 − 480 = 30 分
    expect(record.scheduled_overtime_hours).to eq(0.5)     # 翌 7:00 終業 → 30 分
    expect(record.deep_night_hours).to eq(6.27)            # 376 分 — HALF_UP 発火（truncate なら 6.26）
    expect(record.is_late).to be(false)
    expect(record.late_minutes).to eq(0)
    expect(record.is_early_leave).to be(false)
    expect(record.early_leave_minutes).to eq(0)
  end

  it "未割当（work_pattern nil）は全列 NULL のまま skip" do
    record = create_record(pattern: nil,
                           clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 9))
    described_class.call(record:)
    record.reload
    expect(record.actual_work_hours).to be_nil
    expect(record.is_late).to be_nil
  end

  it "stale 残置 pin: 計算済みレコードのパターンが外れた後の再計算は値を変えない（2-2 で再訪）" do
    record = create_record(pattern: night_pattern,
                           clock_in: Time.utc(2026, 6, 1, 13), clock_out: Time.utc(2026, 6, 1, 22, 30))
    described_class.call(record:)
    record.update_column(:work_pattern_id, nil)
    described_class.call(record:)
    expect(record.reload.actual_work_hours).to eq(8.5)
  end

  it "呼び出し側の with_tenant に依存せず成功する（自己完結 — console/将来ジョブの単体呼び出し想定）" do
    record = create_record(pattern: night_pattern,
                           clock_in: Time.utc(2026, 6, 1, 13), clock_out: Time.utc(2026, 6, 1, 22, 30))
    # with_tenant ブロックの外（= この example の素の文脈）から直接呼ぶ
    expect { described_class.call(record:) }.not_to raise_error
    expect(record.reload.actual_work_hours).to eq(8.5)
  end
end
