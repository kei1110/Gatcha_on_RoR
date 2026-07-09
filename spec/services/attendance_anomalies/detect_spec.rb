# frozen_string_literal: true

require "rails_helper"

RSpec.describe AttendanceAnomalies::Detect, type: :service do
  let(:org) { create(:organization, time_zone: "UTC") } # travel_to 決定化のため UTC 固定

  # 対象日（前日）を稼働日として登録
  def working_calendar(date)
    create(:company_calendar, date:, day_type: :weekday, name: "平日")
  end

  def holiday_calendar(date)
    create(:company_calendar, date:, day_type: :company_holiday, name: "休業")
  end

  def notifications_for(user, source_type)
    Notification.where(target_user: user, source_type:)
  end

  describe "#call pass 1: 前日検知" do
    let(:prev_day) { Date.new(2026, 5, 1) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    before { working_calendar(prev_day) }

    it "退勤打刻忘れ（working・clock_in 有・clock_out 無・非夜勤）→ 本人へ clock_out_missing を 1 件通知" do
      user = create(:user)
      create(:attendance_record, user:, work_date: prev_day, status: :working,
                                 clock_in: Time.utc(2026, 5, 1, 0), clock_out: nil)

      expect { described_class.call(date: prev_day) }
        .to change { notifications_for(user, :clock_out_missing).count }.by(1)
    end

    it "夜勤の退勤忘れは検知しない（§10⑪）" do
      user = create(:user)
      night = create(:work_pattern, night_shift: true, start_time: "22:00", end_time: "06:00")
      create(:attendance_record, user:, work_date: prev_day, status: :working,
                                 clock_in: Time.utc(2026, 5, 1, 13), clock_out: nil, work_pattern: night)

      expect { described_class.call(date: prev_day) }
        .not_to change { notifications_for(user, :clock_out_missing).count }
    end

    it "無打刻 ∧ 稼働日 ∧ LR 皆無 → 欠勤候補を作成（notified_on nil）" do
      user = create(:user)
      # pass 2（同一 call 内）が実行日の「今日」を稼働日とみなして即時通知しないよう休日固定
      # （real wall-clock 依存の flaky 回避。brief の想定は pass 1 単体の生成結果検証）
      holiday_calendar(org.today)

      expect { described_class.call(date: prev_day) }
        .to change { AbsenceCandidate.where(user:, target_date: prev_day).count }.by(1)
      expect(AbsenceCandidate.find_by(user:, target_date: prev_day).notified_on).to be_nil
    end

    it "無打刻でも休日は欠勤候補を作らない（判断 E）" do
      other_day = Date.new(2026, 5, 2)
      holiday_calendar(other_day)
      user = create(:user)

      expect { described_class.call(date: other_day) }
        .not_to change { AbsenceCandidate.count }
    end

    it "AR 有（on_leave 等）の日は欠勤候補を作らない" do
      user = create(:user)
      create(:attendance_record, user:, work_date: prev_day, status: :on_leave, clock_in: nil)

      expect { described_class.call(date: prev_day) }.not_to change { AbsenceCandidate.count }
    end

    it "申請中 LR を覆う無打刻 → 管理者へ leave_pending_no_clock、欠勤候補は作らない" do
      manager = create(:user)
      user = create(:user, manager:)
      lt = create(:leave_type)
      create(:leave_request, requester: user, leave_type: lt,
                             start_date: prev_day, end_date: prev_day, approval_status: :applying)

      expect { described_class.call(date: prev_day) }
        .to change { notifications_for(manager, :leave_pending_no_clock).count }.by(1)
      expect(AbsenceCandidate.where(user:).count).to eq(0)
    end

    it "退勤忘れは非稼働日（前日が休日）でも即時発火する（稼働日ゲートを通さない・§10①/§11⑩）" do
      holiday = Date.new(2026, 5, 3)
      holiday_calendar(holiday)
      user = create(:user)
      create(:attendance_record, user:, work_date: holiday, status: :working,
                                 clock_in: Time.utc(2026, 5, 3, 0), clock_out: nil)

      expect { described_class.call(date: holiday) }
        .to change { notifications_for(user, :clock_out_missing).count }.by(1)
    end
  end

  describe "#call pass 2: 候補の resolve / notify" do
    let(:target) { Date.new(2026, 5, 1) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    # 呼び出しの date: 引数（2026-04-30）は pass 2 起動の形式的トリガーだが、pass 1
    # も同時に走るため休日固定して無関係な候補生成・即時通知（同一 call 内の pass 2 が
    # 拾ってしまう）を防ぐ（real wall-clock 依存の flaky 回避・pass 1 側の修正と同型）
    before { holiday_calendar(Date.new(2026, 4, 30)) }

    it "AR 出現で候補を resolve（destroy）" do
      user = create(:user)
      candidate = create(:absence_candidate, user:, target_date: target)
      create(:attendance_record, user:, work_date: target, status: :clocked_out,
                                 clock_in: Time.utc(2026, 5, 1, 0), clock_out: Time.utc(2026, 5, 1, 9))

      expect { described_class.call(date: Date.new(2026, 4, 30)) }
        .to change { AbsenceCandidate.exists?(candidate.id) }.from(true).to(false)
    end

    it "LR 出現（事後申請・status 不問）で候補を resolve" do
      user = create(:user)
      lt = create(:leave_type)
      candidate = create(:absence_candidate, user:, target_date: target)
      create(:leave_request, requester: user, leave_type: lt,
                             start_date: target, end_date: target, approval_status: :applying)

      expect { described_class.call(date: Date.new(2026, 4, 30)) }
        .to change { AbsenceCandidate.exists?(candidate.id) }.from(true).to(false)
    end

    it "本人の今日が稼働日 ∧ notified_on 未設定 → 本人+管理者に通知し notified_on を設定" do
      working_calendar(org.today)
      manager = create(:user)
      user = create(:user, manager:)
      candidate = create(:absence_candidate, user:, target_date: target, notified_on: nil)

      described_class.call(date: Date.new(2026, 4, 30))

      expect(candidate.reload.notified_on).to eq(org.today)
      expect(notifications_for(user, :absence_candidate).count).to eq(1)
      expect(notifications_for(manager, :absence_candidate).count).to eq(1)
    end

    it "事前通知の body は打刻変更申請を約束しない（CCR new_entry 拒否ゆえ非機能・§12⑦）" do
      # 既存の「本人稼働日 run で candidate を通知する」例と同じ setup を用いる
      working_calendar(org.today)
      manager = create(:user)
      user = create(:user, manager:)
      create(:absence_candidate, user:, target_date: target, notified_on: nil)

      described_class.call(date: Date.new(2026, 4, 30))

      notification = notifications_for(user, :absence_candidate).first
      expect(notification.body).not_to include("打刻変更申請")
      expect(notification.body).to include("管理者")
    end

    it "本人の今日が非稼働日 → 通知せず notified_on は nil のまま（次稼働日 deferral）" do
      holiday_calendar(org.today)
      user = create(:user)
      candidate = create(:absence_candidate, user:, target_date: target, notified_on: nil)

      described_class.call(date: Date.new(2026, 4, 30))

      expect(candidate.reload.notified_on).to be_nil
      expect(notifications_for(user, :absence_candidate).count).to eq(0)
    end

    it "notify-once: notified_on 済の候補は再通知しない" do
      working_calendar(org.today)
      user = create(:user)
      create(:absence_candidate, user:, target_date: target, notified_on: org.today - 3)

      expect { described_class.call(date: Date.new(2026, 4, 30)) }
        .not_to change { notifications_for(user, :absence_candidate).count }
    end
  end

  describe "#call 次稼働日送達（travel_to 多段・§10⑧）" do
    let(:target) { Date.new(2026, 6, 5) } # 検知済み候補の対象日

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "休日 run では notify されず、次の稼働日 run で初めて notified_on が入る" do
      user = create(:user)
      candidate = create(:absence_candidate, user:, target_date: target, notified_on: nil)
      holiday_calendar(Date.new(2026, 6, 6)) # 土曜相当（org TZ=UTC ゆえ org.today = この日）
      working_calendar(Date.new(2026, 6, 8)) # 月曜相当

      # run 1: 休日 → notify されない
      travel_to(Time.utc(2026, 6, 6, 2)) do
        described_class.call(date: Date.new(2026, 6, 5))
      end
      expect(candidate.reload.notified_on).to be_nil

      # run 2: 稼働日 → notified_on 設定
      travel_to(Time.utc(2026, 6, 8, 2)) do
        described_class.call(date: Date.new(2026, 6, 7))
      end
      expect(candidate.reload.notified_on).to eq(Date.new(2026, 6, 8))
    end
  end

  describe "#call 堅牢性・分離" do
    let(:prev_day) { Date.new(2026, 5, 1) }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    before { create(:company_calendar, date: prev_day, day_type: :weekday, name: "平日") }

    it "1 ユーザーの例外でテナント全体の検知を落とさない（§10⑦ per-user rescue）" do
      good = create(:user)
      bad = create(:user)
      # bad の候補生成時のみ Notifier ではなく候補 upsert 前段で例外化するため、
      # AttendanceRecord.find_by を bad のみ raise させる
      allow(AttendanceRecord).to receive(:find_by).and_call_original
      allow(AttendanceRecord).to receive(:find_by)
        .with(user_id: bad.id, work_date: prev_day).and_raise(StandardError, "boom")

      expect { described_class.call(date: prev_day) }.not_to raise_error
      # good の欠勤候補は生成される（bad は skip）
      expect(AbsenceCandidate.where(user: good, target_date: prev_day).count).to eq(1)
    end

    it "テナント越境ゼロ: 他社の候補/通知に触れない（§10⑧）" do
      org_b = create(:organization, time_zone: "UTC")
      b_user = nil
      b_candidate = nil
      ActsAsTenant.with_tenant(org_b) do
        b_user = create(:user)
        b_candidate = create(:absence_candidate, user: b_user, target_date: prev_day, notified_on: nil)
        create(:company_calendar, date: org_b.today, day_type: :weekday, name: "平日")
      end

      # org（A）文脈で検知を実行
      described_class.call(date: prev_day)

      # B の候補は notified_on nil のまま・B ユーザー宛通知は 0（with_tenant 除去で落ちる向き）
      ActsAsTenant.with_tenant(org_b) do
        expect(b_candidate.reload.notified_on).to be_nil
        expect(Notification.where(target_user: b_user).count).to eq(0)
      end
    end
  end
end
