# frozen_string_literal: true

require "rails_helper"

RSpec.describe Absences::Confirm do
  # travel_to を決定化するため TZ 固定（RAILS_GOTCHAS「org.today 相対ロジック」）
  let(:org) { create(:organization, time_zone: "Asia/Tokyo") }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:manager) { create(:user, :manager_role) }
  let(:user)    { create(:user, manager: manager) }

  let(:target_date) { Date.new(2026, 5, 1) }   # 金曜
  let(:notified_on) { Date.new(2026, 5, 1) }   # 通知日 = 金 → 翌営業日 = 5/4(月) 17:00 が猶予期限

  # 猶予経過後（2026-05-04 17:01 JST = 08:01 UTC）
  def after_grace(&) = travel_to(Time.utc(2026, 5, 4, 8, 1), &)
  # 猶予直前（2026-05-04 16:59 JST = 07:59 UTC）
  def before_grace(&) = travel_to(Time.utc(2026, 5, 4, 7, 59), &)

  def candidate(date: target_date, notified: notified_on)
    create(:absence_candidate, user:, target_date: date, notified_on: notified)
  end

  def confirm(dates:, candidates:, reason: "unauthorized", note: nil)
    described_class.call(target_user: user, dates:, candidates:,
                         absence_reason: reason, note:, actor: manager)
  end

  describe "正常系" do
    it "候補 1 日を確定し AR(absent) / 履歴を作り候補を消す" do
      c = candidate
      result = after_grace { confirm(dates: [ target_date ], candidates: [ c ]) }

      expect(result.confirmed_dates).to eq([ target_date ])
      expect(result.skipped_dates).to be_empty

      record = AttendanceRecord.find_by(user_id: user.id, work_date: target_date)
      expect(record.status).to eq("absent")
      expect(record.absence_reason).to eq("unauthorized")
      expect(record.clock_in).to be_nil
      expect(AbsenceCandidate.where(id: c.id)).not_to exist

      history = AttendanceHistory.find_by(user_id: user.id, event_type: :absence_confirmed,
                                          event_date: target_date)
      expect(history.actor_id).to eq(manager.id)
      expect(history.new_status).to eq(AttendanceRecord.statuses[:absent])
      expect(history.note).to eq("欠勤理由: 無届欠勤") # 書式は AttendanceRecord.absence_reason_note が単一源
    end

    it "複数日を一括確定する（1 社員 × N 日付・§6.10 step 3・月境界を跨ぐ）" do
      # d2 は target_date の前日側（過去日）に取る — travel_to の「今日」は 2026-05-04 ゆえ、
      # 未来日の欠勤を確定するテストにしない。4/30(木) と 5/1(金) は締め期間が分かれ得るため
      # guard_closing! の月境界跨ぎ（§11⑦）も同時に踏む
      d2 = Date.new(2026, 4, 30)
      cs = [ candidate, candidate(date: d2) ]
      result = after_grace { confirm(dates: [ target_date, d2 ], candidates: cs) }

      expect(result.confirmed_dates).to contain_exactly(target_date, d2)
      expect(AttendanceRecord.where(user_id: user.id, status: :absent).count).to eq(2)
    end

    it "other 以外は note を保存しない（§6.10）" do
      c = candidate
      after_grace { confirm(dates: [ target_date ], candidates: [ c ], reason: "illness", note: "捨てられる") }
      expect(AttendanceRecord.find_by(work_date: target_date).note).to be_nil
    end

    it "other は note を保存する" do
      c = candidate
      after_grace { confirm(dates: [ target_date ], candidates: [ c ], reason: "other", note: "私用") }
      expect(AttendanceRecord.find_by(work_date: target_date).note).to eq("私用")
    end
  end

  describe "ガード（すべて write 前に 422）" do
    it "毒入力の absence_reason は IneligibleError（per-day rescue に握り潰させない）" do
      c = candidate
      expect { after_grace { confirm(dates: [ target_date ], candidates: [ c ], reason: "bogus") } }
        .to raise_error(Absences::IneligibleError)
      expect(AttendanceRecord.count).to eq(0)
      expect(AbsenceCandidate.where(id: c.id)).to exist # 候補は intact
    end

    it "候補の無い日付が混ざれば全件拒否（却下/撤回 LR 日・過去日の捏造・§11②/§12⑨）" do
      c = candidate
      ghost = Date.new(2026, 4, 30)
      expect { after_grace { confirm(dates: [ target_date, ghost ], candidates: [ c ]) } }
        .to raise_error(Absences::IneligibleError, /存在しない日付/)
      expect(AttendanceRecord.count).to eq(0)
    end

    it "日付が空なら IneligibleError" do
      expect { after_grace { confirm(dates: [], candidates: []) } }
        .to raise_error(Absences::IneligibleError, /選択されていません/)
    end

    it "notified_on: nil の候補は確定不可（猶予計算より先に判定・§12①）" do
      c = candidate(notified: nil)
      expect { after_grace { confirm(dates: [ target_date ], candidates: [ c ]) } }
        .to raise_error(Absences::IneligibleError, /未通知/)
      expect(AttendanceRecord.count).to eq(0)
    end

    it "猶予期限（翌営業日 17:00）前は確定不可 — 16:59 JST" do
      c = candidate
      expect { before_grace { confirm(dates: [ target_date ], candidates: [ c ]) } }
        .to raise_error(Absences::IneligibleError, /猶予期限/)
      expect(AttendanceRecord.count).to eq(0)
    end

    it "猶予期限を過ぎれば確定可 — 17:01 JST（境界の有効側）" do
      c = candidate
      expect { after_grace { confirm(dates: [ target_date ], candidates: [ c ]) } }.not_to raise_error
    end

    it "連休を跨いだ猶予期限を正しく算出する（5/4・5/5 が休業なら 5/6 17:00 が期限）" do
      create(:company_calendar, date: Date.new(2026, 5, 4), day_type: :company_holiday, name: "連休")
      create(:company_calendar, date: Date.new(2026, 5, 5), day_type: :company_holiday, name: "連休")
      c = candidate

      # 5/4 17:01 JST — 旧期限なら通るが、連休吸収後は 5/6 が期限ゆえ拒否
      expect { after_grace { confirm(dates: [ target_date ], candidates: [ c ]) } }
        .to raise_error(Absences::IneligibleError, /猶予期限/)

      # 5/6 17:01 JST（08:01 UTC）
      expect { travel_to(Time.utc(2026, 5, 6, 8, 1)) { confirm(dates: [ target_date ], candidates: [ c ]) } }
        .not_to raise_error
    end

    it "締め済み（finalized）月の日付は ClosingLockedError" do
      c = candidate
      create(:monthly_attendance_summary, user:,
             year_month: AttendancePeriod.containing(organization: org, date: target_date).label,
             status: :finalized)
      expect { after_grace { confirm(dates: [ target_date ], candidates: [ c ]) } }
        .to raise_error(Absences::ClosingLockedError)
      expect(AttendanceRecord.count).to eq(0)
    end

    it "提出済（submitted）月も遮断する（§12⑩・§5.2 より厳格・意図的）" do
      c = candidate
      create(:monthly_attendance_summary, user:,
             year_month: AttendancePeriod.containing(organization: org, date: target_date).label,
             status: :submitted)
      expect { after_grace { confirm(dates: [ target_date ], candidates: [ c ]) } }
        .to raise_error(Absences::ClosingLockedError)
    end
  end

  describe "per-day savepoint（§12⑤）" do
    it "既に AR がある日は skip し、他の日は確定される（1 日の競合が全体を殺さない）" do
      d2 = Date.new(2026, 4, 30)  # 過去日（Confirm は candidates を target_date 昇順で処理する）
      cs = [ candidate, candidate(date: d2) ]
      create(:attendance_record, user:, work_date: target_date, status: :working) # 並行 clock_in 相当

      result = after_grace { confirm(dates: [ target_date, d2 ], candidates: cs) }

      expect(result.skipped_dates).to eq([ target_date ])
      expect(result.confirmed_dates).to eq([ d2 ])
      expect(AttendanceRecord.find_by(work_date: target_date).status).to eq("working") # 上書きしない
      expect(AttendanceRecord.find_by(work_date: d2).status).to eq("absent")
    end

    it "skip 日の候補は savepoint rollback で intact に戻る（再確定可能）" do
      c = candidate
      create(:attendance_record, user:, work_date: target_date, status: :working)

      after_grace { confirm(dates: [ target_date ], candidates: [ c ]) }

      expect(AbsenceCandidate.where(id: c.id)).to exist
      expect(AttendanceHistory.where(event_type: :absence_confirmed).count).to eq(0)
    end
  end
end
