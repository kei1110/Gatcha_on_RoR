# frozen_string_literal: true

require "rails_helper"

RSpec.describe "ProxyClockings", type: :request do
  let(:org) { create(:organization, subdomain: "acme") } # TZ 既定 Asia/Tokyo
  let(:manager) { ActsAsTenant.with_tenant(org) { create(:user, :manager_role, organization: org) } }
  let(:sub)     { ActsAsTenant.with_tenant(org) { create(:user, organization: org, manager: manager) } }

  before { host! "acme.example.com" }

  describe "代理出勤（manager → 直接部下）" do
    before { sign_in manager }

    it "scope 内の部下に代理出勤できる" do
      # request spec はテナント未設定 → count は unscoped で読む（既存 clockings_spec 規約・RAILS_GOTCHAS）
      expect {
        post clock_in_proxy_clocking_path(sub), params: { proxy_clock_reason: "system_failure" }
      }.to change { AttendanceRecord.unscoped.count }.by(1)
      expect(response).to have_http_status(:see_other)
    end

    it "scope 外（非部下）は 404（IDOR 対策）" do
      stranger = ActsAsTenant.with_tenant(org) { create(:user, organization: org) }
      post clock_in_proxy_clocking_path(stranger), params: { proxy_clock_reason: "system_failure" }
      expect(response).to have_http_status(:not_found)
    end

    it "reason 欠落は無理由代理打刻を作らない" do
      post clock_in_proxy_clocking_path(sub)
      expect(AttendanceRecord.unscoped.count).to eq 0
      expect(response).to have_http_status(:see_other)
    end
  end

  describe "代理退勤（manager → open 状態の部下）" do
    before { sign_in manager }

    it "working の部下を退勤させ see_other（working → clocked_out）" do
      travel_to Time.utc(2026, 6, 1, 1) do # JST 2026-06-01 10:00 → org.today = 2026-06-01
        record = ActsAsTenant.with_tenant(org) do
          create(:attendance_record, user: sub, work_date: org.today, status: :working)
        end

        post clock_out_proxy_clocking_path(sub), params: { proxy_clock_reason: "system_failure" }

        expect(response).to have_http_status(:see_other)
        expect(AttendanceRecord.unscoped.find(record.id).status).to eq("clocked_out")
      end
    end
  end

  describe "GET index（ロスター3状態の出し分け）" do
    before { sign_in manager }

    it "未打刻=出勤ボタン / working=退勤ボタン / 当日打刻済=表示 を出し分ける" do
      travel_to Time.utc(2026, 6, 1, 1) do # JST 2026-06-01 10:00 → org.today = 2026-06-01
        sub_open = nil
        sub_done = nil
        ActsAsTenant.with_tenant(org) do
          sub # 未打刻の部下（lazy let を確定して roster に載せる）
          sub_open = create(:user, organization: org, manager: manager)
          sub_done = create(:user, organization: org, manager: manager)
          create(:attendance_record, user: sub_open, work_date: org.today, status: :working)
          create(:attendance_record, :done, user: sub_done, work_date: org.today)
        end

        get proxy_clockings_path

        expect(response).to have_http_status(:ok)
        expect(response.body).to include(clock_in_proxy_clocking_path(sub))       # 未打刻 → 出勤ボタン
        expect(response.body).to include(clock_out_proxy_clocking_path(sub_open)) # working → 退勤ボタン
        expect(response.body).to include("本日打刻済")                            # 当日打刻済 → 表示
        # 当日打刻済の行はフォームを持たない
        expect(response.body).not_to include(clock_in_proxy_clocking_path(sub_done))
        expect(response.body).not_to include(clock_out_proxy_clocking_path(sub_done))
      end
    end
  end

  describe "代理出勤（hr_admin → 非部下も対象）" do
    it "hr_admin は非部下にも代理出勤できる" do
      admin    = ActsAsTenant.with_tenant(org) { create(:user, :hr_admin, organization: org) }
      stranger = ActsAsTenant.with_tenant(org) { create(:user, organization: org) }
      sign_in admin

      expect {
        post clock_in_proxy_clocking_path(stranger), params: { proxy_clock_reason: "system_failure" }
      }.to change { AttendanceRecord.unscoped.count }.by(1)
      expect(response).to have_http_status(:see_other)
    end
  end

  describe "認可（employee は不可）" do
    it "employee は代理打刻不可で 403（既存 render_forbidden 準拠）" do
      employee = ActsAsTenant.with_tenant(org) { create(:user, organization: org) }
      sign_in employee

      post clock_in_proxy_clocking_path(sub), params: { proxy_clock_reason: "system_failure" }

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "通知とインターバル（4-2d）" do
    before { sign_in manager }

    it "代理出勤成功で本人へ proxy_clocked 通知（informational・操作者が subject）" do
      travel_to Time.utc(2026, 6, 1, 1) do
        expect {
          post clock_in_proxy_clocking_url(sub, host: tenant_host(org)),
               params: { proxy_clock_reason: "system_failure" }
        }.to change { Notification.unscoped.where(target_user: sub, source_type: :proxy_clocked).count }.by(1)
      end
      notification = Notification.unscoped.where(source_type: :proxy_clocked).last
      expect(notification.subject_user_id).to eq(manager.id)
      expect(notification.body).to include(manager.name)
    end

    it "代理退勤成功でも本人へ proxy_clocked 通知" do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, user: sub, work_date: Date.new(2026, 6, 1),
               clock_in: Time.utc(2026, 6, 1, 0), status: :working)
      end
      travel_to Time.utc(2026, 6, 1, 9) do
        expect {
          post clock_out_proxy_clocking_url(sub, host: tenant_host(org)),
               params: { proxy_clock_reason: "system_failure" }
        }.to change { Notification.unscoped.where(target_user: sub, source_type: :proxy_clocked).count }.by(1)
      end
    end

    it "代理出勤の失敗（出勤済み）では通知しない（成功時のみ・幻通知防止）" do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, user: sub, work_date: Date.new(2026, 6, 1),
               clock_in: Time.utc(2026, 6, 1, 0), status: :working)
      end
      travel_to Time.utc(2026, 6, 1, 1) do
        expect {
          post clock_in_proxy_clocking_url(sub, host: tenant_host(org)),
               params: { proxy_clock_reason: "system_failure" }
        }.not_to change { Notification.unscoped.count }
      end
    end

    it "代理出勤でもインターバル判定が走る（§13② — AH 記録 + 本人へ通知 + 操作者へ警告 flash）" do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, :done, user: sub, work_date: Date.new(2026, 6, 1),
               clock_in: Time.utc(2026, 6, 1, 4), clock_out: Time.utc(2026, 6, 1, 13)) # JST 22:00 退勤
      end
      travel_to Time.utc(2026, 6, 1, 23) do # JST 6/2 08:00 = 休息 10h
        expect {
          post clock_in_proxy_clocking_url(sub, host: tenant_host(org)),
               params: { proxy_clock_reason: "system_failure" }
        }.to change { AttendanceHistory.unscoped.where(event_type: :interval_shortage).count }.by(1)
          .and change { Notification.unscoped.where(target_user: sub, source_type: :interval_shortage).count }.by(1)

        expect(response).to have_http_status(:see_other)
        follow_redirect!
        expect(response.body).to include("勤務間インターバルが不足")
        history = AttendanceHistory.unscoped.where(event_type: :interval_shortage).last
        expect(history.actor_id).to eq(manager.id) # 打刻者 = 代理操作者
      end
    end

    it "通知が失敗しても代理打刻の応答は覆らない（§9.5）" do
      allow(Notifier).to receive(:call).and_raise(StandardError, "boom")
      travel_to Time.utc(2026, 6, 1, 1) do
        expect {
          post clock_in_proxy_clocking_url(sub, host: tenant_host(org)),
               params: { proxy_clock_reason: "system_failure" }
        }.to change { AttendanceRecord.unscoped.where(user: sub).count }.by(1)
        expect(response).to have_http_status(:see_other)
      end
    end
  end
end
