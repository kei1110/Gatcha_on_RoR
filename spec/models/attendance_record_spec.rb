# frozen_string_literal: true

require "rails_helper"

RSpec.describe AttendanceRecord, type: :model do
  describe "status enum" do
    it "整数マッピングを固定する（残り 4 値は §4.8 列挙順で 2〜5 を予約 — 並べ替え事故防止）" do
      expect(described_class.statuses).to eq("working" => 0, "clocked_out" => 1)
    end
  end

  describe "検証" do
    it "work_date / clock_in / status は必須" do
      record = described_class.new
      record.valid?
      expect(record.errors[:work_date]).to be_present
      expect(record.errors[:clock_in]).to be_present
      expect(record.errors[:status]).to be_present
    end

    it "clock_out が clock_in より前なら invalid" do
      record = build(:attendance_record,
                     clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 5, 31, 23))
      expect(record).not_to be_valid
      expect(record.errors[:clock_out]).to be_present
    end

    it "clock_out 同時刻は valid（境界）・翌日に跨ぐ退勤も valid（夜勤）" do
      base = Time.utc(2026, 6, 1, 13) # JST 22:00
      expect(build(:attendance_record, clock_in: base, clock_out: base, status: :clocked_out)).to be_valid
      expect(build(:attendance_record, clock_in: base, clock_out: base + 9.hours, status: :clocked_out)).to be_valid
    end
  end

  describe "unique index [user_id, work_date]" do
    it "同一ユーザー同一日の 2 行目は RecordNotUnique（モデル検証は意図的に無し — TOCTOU）" do
      record = create(:attendance_record)
      dup = build(:attendance_record, user: record.user, work_date: record.work_date)
      expect { dup.save! }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "複合 FK（越境の最終防衛 — fail-closed 検証を意図的に置かない決定の唯一防衛を固定）" do
    it "is enforced by composite FK (organization_id, user_id) even when validation is bypassed" do
      other_org = create(:organization)
      foreign_user = ActsAsTenant.with_tenant(other_org) { create(:user) }
      record = create(:attendance_record)
      expect {
        record.update_column(:user_id, foreign_user.id)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "is enforced by composite FK (organization_id, work_pattern_id) even when validation is bypassed" do
      other_org = create(:organization)
      foreign_pattern = ActsAsTenant.with_tenant(other_org) { create(:work_pattern) }
      record = create(:attendance_record)
      expect {
        record.update_column(:work_pattern_id, foreign_pattern.id)
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  describe "acts_as_tenant" do
    it "organization はテナント文脈から自動代入される" do
      record = described_class.create!(user: create(:user), work_date: Date.new(2026, 6, 3),
                                       clock_in: Time.utc(2026, 6, 3, 0), status: :working)
      expect(record.organization).to eq(ActsAsTenant.test_tenant)
    end
  end

  describe ".working_within" do
    let(:user) { create(:user) }

    it "window 内の working のみ返す（clocked_out・window 外 working を除外）" do
      inside = create(:attendance_record, user:, work_date: Date.new(2026, 6, 2),
                      clock_in: Time.utc(2026, 6, 2, 0))
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1), status: :clocked_out,
             clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 9))
      create(:attendance_record, user:, work_date: Date.new(2026, 5, 30),
             clock_in: Time.utc(2026, 5, 30, 0))

      window = Date.new(2026, 6, 1)..Date.new(2026, 6, 2)
      expect(described_class.working_within(window)).to contain_exactly(inside)
    end

    it "端なし Range も受ける（State の stale 探索と同一述語 — 二度書き防止の前提）" do
      old = create(:attendance_record, user:, work_date: Date.new(2026, 5, 30),
                   clock_in: Time.utc(2026, 5, 30, 0))
      expect(described_class.working_within(..Date.new(2026, 5, 31))).to contain_exactly(old)
    end
  end

  describe "proxy_clock_reason enum" do
    it "整数マッピングが固定" do
      expect(AttendanceRecord.proxy_clock_reasons).to eq(
        "system_failure" => 0, "unreachable" => 1, "forgot_punch" => 2, "other" => 3
      )
    end

    it "不正値は ArgumentError でなく検証エラー（毒入力対策）" do
      rec = build(:attendance_record)
      rec.proxy_clock_reason = "bogus"
      expect(rec).to be_invalid
    end
  end

  describe "計算 8 列（1-2 設計 §1）" do
    let(:org) { create(:organization) }
    let(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

    it "numericality: 負値 invalid・nil valid（NULL = 未計算）" do
      ActsAsTenant.with_tenant(org) do
        record = build(:attendance_record, user:,
                       actual_work_hours: -1, legal_overtime_hours: -1, scheduled_overtime_hours: -1,
                       deep_night_hours: -1, late_minutes: -5, early_leave_minutes: -5)
        expect(record).not_to be_valid
        %i[actual_work_hours legal_overtime_hours scheduled_overtime_hours
           deep_night_hours late_minutes early_leave_minutes].each do |col|
          expect(record.errors[col]).to be_present
        end
        expect(build(:attendance_record, user:)).to be_valid # 8 列 nil で valid
      end
    end

    it "calculated スコープは actual_work_hours 非 NULL のみ返す（is_late 直接 where 禁止の代替経路）" do
      ActsAsTenant.with_tenant(org) do
        raw  = create(:attendance_record, user:, work_date: Date.new(2026, 6, 1))
        calc = create(:attendance_record, user:, work_date: Date.new(2026, 6, 2),
                      clock_in: Time.utc(2026, 6, 2, 0), status: :clocked_out,
                      clock_out: Time.utc(2026, 6, 2, 9), actual_work_hours: 8.0)
        expect(AttendanceRecord.calculated).to contain_exactly(calc)
        expect(AttendanceRecord.calculated).not_to include(raw)
      end
    end
  end
end
