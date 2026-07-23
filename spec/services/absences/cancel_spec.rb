# frozen_string_literal: true

require "rails_helper"

RSpec.describe Absences::Cancel do
  let(:org) { create(:organization, time_zone: "Asia/Tokyo") }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:manager) { create(:user, :manager_role) }
  let(:user)    { create(:user, manager: manager) }
  let(:work_date) { Date.new(2026, 5, 1) }

  # 確定済み欠勤（Absences::Confirm が作る形）
  def absent_record(reason: :unauthorized, note: nil)
    create(:attendance_record, user:, work_date:, status: :absent, absence_reason: reason, note:)
  end

  def cancel(record:, note: "誤検知のため取消", actor: manager)
    described_class.call(target_user: user, record:, note:, actor:)
  end

  describe "正常系" do
    it "absent AR を destroy し absence_canceled 履歴を残し候補を notified_on:nil で再生成する" do
      record = absent_record(reason: :illness, note: nil)

      cancel(record:)

      expect(AttendanceRecord.where(id: record.id)).not_to exist
      history = AttendanceHistory.find_by(event_type: :absence_canceled, event_date: work_date)
      expect(history.user_id).to eq(user.id)
      expect(history.actor_id).to eq(manager.id)
      expect(history.previous_status).to eq(AttendanceRecord.statuses[:absent])
      expect(history.new_status).to be_nil
      expect(history.absence_reason).to eq("illness")   # 取り消した理由を構造化して保持
      expect(history.note).to eq("誤検知のため取消")     # 取消理由（必須）
      candidate = AbsenceCandidate.find_by(user_id: user.id, target_date: work_date)
      expect(candidate).to be_present
      expect(candidate.notified_on).to be_nil
    end

    it "other 理由の自由記述も履歴 absence_reason=other + note に取消理由を残す" do
      record = absent_record(reason: :other, note: "システム障害")

      cancel(record:, note: "打刻ミスと判明")

      history = AttendanceHistory.find_by(event_type: :absence_canceled, event_date: work_date)
      expect(history.absence_reason).to eq("other")
      expect(history.note).to eq("打刻ミスと判明")
    end
  end

  describe "ガード" do
    it "取消理由 note が空なら IneligibleError（AR は残る）" do
      record = absent_record
      expect { cancel(record:, note: " ") }.to raise_error(Absences::IneligibleError, /取消理由/)
      expect(AttendanceRecord.where(id: record.id)).to exist
    end

    it "操作者が別組織なら IneligibleError（昇格前ガード・AR は残る）" do
      record = absent_record
      other_actor = ActsAsTenant.with_tenant(create(:organization)) { create(:user, :manager_role) }
      expect { cancel(record:, actor: other_actor) }.to raise_error(Absences::IneligibleError, /組織/)
      expect(AttendanceRecord.where(id: record.id)).to exist
    end

    it "record が target_user のものでなければ IneligibleError" do
      other_user = create(:user, manager: manager)
      record = create(:attendance_record, user: other_user, work_date:, status: :absent,
                      absence_reason: :unauthorized)
      expect { described_class.call(target_user: user, record:, note: "x", actor: manager) }
        .to raise_error(Absences::IneligibleError, /対象社員のもの/)
    end

    it "締め済み（finalized）月は ClosingLockedError（AR は残る）" do
      record = absent_record
      create(:monthly_attendance_summary, user:,
             year_month: AttendancePeriod.containing(organization: org, date: work_date).label,
             status: :finalized)
      expect { cancel(record:) }.to raise_error(Absences::ClosingLockedError)
      expect(AttendanceRecord.where(id: record.id)).to exist
    end

    it "締め済み（submitted）月も ClosingLockedError（AR は残る・finalized と対称）" do
      record = absent_record
      create(:monthly_attendance_summary, user:,
             year_month: AttendancePeriod.containing(organization: org, date: work_date).label,
             status: :submitted)
      expect { cancel(record:) }.to raise_error(Absences::ClosingLockedError)
      expect(AttendanceRecord.where(id: record.id)).to exist
    end
  end

  describe "不変条件（設計 §5・4-2c-3a 前提）" do
    it "ロック後に status が absent でなければ IneligibleError（事後有給の振替を取消が destroy しない）" do
      record = absent_record
      # with_lock の内側で「別 tx が事後有給の振替を書き込んだ」状況を再現する
      # （spec/services/clockings/clock_out_spec.rb:79-96 と同型）。全インスタンス一様に absent?
      # を差し替えるのではなく、with_lock の block 実行**前**に対象行だけ status を書き換えることで、
      # guard_still_absent! が with_lock の内側にあるときだけ検出できる形にする。
      # 外に出すと update_columns 前（まだ absent）の @record.status で判定してしまい、この it は FAIL する
      # （判別性は 2026-07-23 の修正で実測 — 一時的に guard_still_absent! を with_lock 外へ移し FAIL を確認済み）。
      # absence_reason は nil クリア（実変換パス ApplyApproval#call と同じ・DB CHECK
      # `absence_reason IS NULL OR status = absent` との整合が必須）
      allow_any_instance_of(AttendanceRecord).to receive(:with_lock) do |rec, &block|
        rec.update_columns(status: AttendanceRecord.statuses[:on_leave], absence_reason: nil)
        block.call
      end

      expect { cancel(record:) }.to raise_error(Absences::IneligibleError, /振り替え|欠勤ではありません/)
    end
  end

  describe "競合（設計 §4.2）" do
    it "取消前に AR が別操作で消えていれば RecordNotFound（with_lock の reload が掴めない）" do
      record = absent_record
      AttendanceRecord.where(id: record.id).delete_all

      expect { cancel(record:) }.to raise_error(ActiveRecord::RecordNotFound)
    end
  end

  describe "Confirm との往復（4-2c-3a レビュー申し送り・退行検知の強化）" do
    it "Absences::Confirm.call で確定した absent AR を Cancel で取り消せる" do
      candidate = create(:absence_candidate, user:, target_date: work_date, notified_on: work_date)
      # 猶予期限（通知翌営業日 5/4(月) 17:00 JST）経過後 = confirm_spec の after_grace と同一
      travel_to(Time.utc(2026, 5, 4, 8, 1)) do
        Absences::Confirm.call(target_user: user, dates: [ work_date ], candidates: [ candidate ],
                                absence_reason: "illness", note: nil, actor: manager)
      end
      record = AttendanceRecord.find_by!(user_id: user.id, work_date:)
      expect(record.status).to eq("absent")

      cancel(record:)

      expect(AttendanceRecord.where(id: record.id)).not_to exist
      history = AttendanceHistory.find_by(event_type: :absence_canceled, event_date: work_date)
      expect(history.absence_reason).to eq("illness")
      restored_candidate = AbsenceCandidate.find_by(user_id: user.id, target_date: work_date)
      expect(restored_candidate).to be_present
      expect(restored_candidate.notified_on).to be_nil
    end
  end
end
