# frozen_string_literal: true

require "rails_helper"

# silent-gap 塞ぎ（3-2 設計 §2.4・D3）。
# Approvable を include する本番モデルは ClosingRestricted も include し、
# closing_locked? の実体が ClosingRestricted 由来であることを機械検証する。
# 動的列挙（const_source_location → /app/models/）により、新規 Approvable host が
# ClosingRestricted を忘れると CI が FAIL する（固定 allowlist の silent-gap を排除）。
RSpec.describe "ClosingRestricted coverage", type: :model do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  before { Rails.application.eager_load! }

  let(:requester) { create(:user, organization: org) }

  # 本番 app/models/ 配下の Approvable host のみ列挙（spec/support の test double は除外）。
  # const_source_location で定義ファイルが /app/models/ に属するかを判定する。
  def production_approvable_hosts
    ApplicationRecord.descendants.select do |klass|
      next false unless klass.include?(Approvable)

      loc = Object.const_source_location(klass.name)&.first
      loc&.include?("/app/models/")
    end
  end

  it "本番の Approvable host は空でない（列挙ロジックの偽 green 防止）" do
    hosts = production_approvable_hosts
    expect(hosts).not_to be_empty
    expect(hosts).to include(LeaveRequest, ClockChangeRequest, HolidayWorkRequest)
  end

  it "全 Approvable host が ClosingRestricted を include する" do
    production_approvable_hosts.each do |klass|
      expect(klass.include?(ClosingRestricted)).to be(true),
        "#{klass} must include ClosingRestricted"
    end
  end

  it "closing_locked? の実体が ClosingRestricted 由来（Approvable 既定 false に勝つ）" do
    production_approvable_hosts.each do |klass|
      owner = klass.instance_method(:closing_locked?).owner
      expect(owner).to eq(ClosingRestricted),
        "#{klass}#closing_locked? は #{owner} 由来（ClosingRestricted であるべき）"
    end
  end

  it "各 host の closing_target_dates が NotImplementedError でなく呼べる" do
    # 動的: すべての production host で closing_target_dates が上書きされている（NotImplementedError でない）
    # not_to raise_error（クラス無指定）= いかなる例外も raise しないことを検証（より強い保証）
    production_approvable_hosts.each do |klass|
      expect { klass.new.closing_target_dates }
        .not_to raise_error,
                "#{klass}#closing_target_dates は未実装（NotImplementedError を raise する）"
    end

    # 既知型の回帰: 返り値の正しさを factory build で確認
    lr = build(:leave_request, requester:, start_date: Date.new(2026, 5, 1), end_date: Date.new(2026, 5, 3))
    expect(lr.closing_target_dates.to_a).to eq([ Date.new(2026, 5, 1), Date.new(2026, 5, 2), Date.new(2026, 5, 3) ])

    hwr = build(:holiday_work_request, requester:, work_date: Date.new(2026, 6, 7))
    expect(hwr.closing_target_dates).to eq([ Date.new(2026, 6, 7) ])

    ar = build(:attendance_record, :done, user: requester, work_date: Date.new(2026, 6, 1))
    ccr = build(:clock_change_request, requester:, attendance_record: ar)
    expect(ccr.closing_target_dates).to eq([ Date.new(2026, 6, 1) ])
  end
end
