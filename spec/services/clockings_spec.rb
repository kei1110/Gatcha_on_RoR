require "rails_helper"

RSpec.describe Clockings do
  describe ".append_note" do
    it "既存が空なら断片のみ" do
      expect(described_class.append_note(nil, "A")).to eq "A"
      expect(described_class.append_note("", "A")).to eq "A"
    end

    it "既存があれば ； で連結" do
      expect(described_class.append_note("A", "B")).to eq "A；B"
    end
  end

  describe ".proxy_note_fragment の i18n drift guard" do
    it "全 proxy_clock_reason enum キーに ja ラベルが存在する" do
      # raise: true はテスト内でのみ使い drift を検出する。プロダクトの proxy_note_fragment は
      # raise を付けない（不正 reason の POST を未捕捉 500 にせず enum 検証で proxy_clock_failed へ落とす）
      AttendanceRecord.proxy_clock_reasons.each_key do |key|
        label = I18n.t("activerecord.attributes.attendance_record.proxy_clock_reasons.#{key}", raise: true)
        expect(label).to be_present
      end
    end
  end

  describe "ProxyClockIn/Out error symbol の i18n drift guard" do
    # controller は t("proxy_clockings.errors.#{result.error}") で alert 化する。
    # service に新エラーを足した際 ja.yml への追記漏れを "translation missing" にせず CI で捕捉する。
    # service の failure(:symbol) と同期させること（新 error 追加時はこのリストと ja.yml の両方を更新）
    error_symbols = %i[
      reason_required self_proxy_forbidden cross_tenant
      already_clocked_in still_working not_working proxy_clock_failed
    ]

    error_symbols.each do |sym|
      it "proxy_clockings.errors.#{sym} の ja ラベルが存在する" do
        label = I18n.t("proxy_clockings.errors.#{sym}", raise: true)
        expect(label).to be_present
      end
    end
  end

  describe ".proxy_note_fragment" do
    let(:org) { create(:organization) }
    let(:operator) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, organization: org) } }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "kind・operator.name・reason ラベル・組織 TZ 時刻が断片に入る" do
      travel_to Time.utc(2026, 6, 1, 0, 0, 0) do  # JST 09:00
        fragment = described_class.proxy_note_fragment(
          operator: operator, organization: org, kind: "出勤", reason: "system_failure")
        expect(fragment).to include("代理打刻（出勤）")
        expect(fragment).to include(operator.name)
        expect(fragment).to include("2026-06-01 09:00")  # JST (Asia/Tokyo = UTC+9)
        expect(fragment).to include("システム障害")  # i18n label for system_failure
      end
    end
  end

  describe ".record_history" do
    let(:org) { create(:organization) }
    let(:actor) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, organization: org) } }
    let(:target) { ActsAsTenant.with_tenant(org) { create(:user, organization: org) } }

    around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

    it "previous nil で previous_* が nil・current の値が new_* に入る・status 整数化" do
      record = create(:attendance_record, organization: org, user: target,
                      work_date: Date.new(2026, 6, 1),
                      clock_in: Time.utc(2026, 6, 1, 0), status: :working)
      expect {
        described_class.record_history(
          event_type: :proxy_clock, organization: org,
          user: target, actor: actor, source: record, note: "test note",
          previous: nil, current: record
        )
      }.to change(AttendanceHistory, :count).by(1)

      hist = AttendanceHistory.last
      expect(hist.previous_status).to be_nil
      expect(hist.new_status).to eq AttendanceRecord.statuses["working"]
      expect(hist.previous_clock_in).to be_nil
      expect(hist.new_clock_in).to eq record.clock_in
      expect(hist.previous_clock_out).to be_nil
      expect(hist.new_clock_out).to be_nil
      expect(hist.event_type).to eq "proxy_clock"
      expect(hist.actor).to eq actor
      expect(hist.user).to eq target
    end

    it "previous dup で before-values が入る（14 列マッピング確認）" do
      # before（dup 元）と after（update! 後）で 7 ペア全列に異なる値を持たせ、
      # previous_* には dup 時点の値・new_* には確定後の値が入ることを 14 列すべてで検証する
      record = create(:attendance_record, organization: org, user: target,
                      work_date: Date.new(2026, 6, 1),
                      clock_in: Time.utc(2026, 6, 1, 0), status: :working,
                      is_late: true, late_minutes: 15,
                      is_early_leave: false, early_leave_minutes: 0)
      previous = record.dup
      record.update!(
        clock_out: Time.utc(2026, 6, 1, 9), status: :clocked_out,
        is_late: false, late_minutes: 0,
        is_early_leave: true, early_leave_minutes: 30
      )

      described_class.record_history(
        event_type: :proxy_clock, organization: org,
        user: target, actor: actor, source: record, note: "test",
        previous: previous, current: record
      )

      hist = AttendanceHistory.last
      # status（整数化）
      expect(hist.previous_status).to eq AttendanceRecord.statuses["working"]
      expect(hist.new_status).to eq AttendanceRecord.statuses["clocked_out"]
      # clock_in（変化なし）/ clock_out（nil → 確定）
      expect(hist.previous_clock_in).to eq Time.utc(2026, 6, 1, 0)
      expect(hist.new_clock_in).to eq Time.utc(2026, 6, 1, 0)
      expect(hist.previous_clock_out).to be_nil
      expect(hist.new_clock_out).to eq Time.utc(2026, 6, 1, 9)
      # is_late / late_minutes
      expect(hist.previous_is_late).to be(true)
      expect(hist.new_is_late).to be(false)
      expect(hist.previous_late_minutes).to eq 15
      expect(hist.new_late_minutes).to eq 0
      # is_early_leave / early_leave_minutes
      expect(hist.previous_is_early_leave).to be(false)
      expect(hist.new_is_early_leave).to be(true)
      expect(hist.previous_early_leave_minutes).to eq 0
      expect(hist.new_early_leave_minutes).to eq 30
    end
  end
end
