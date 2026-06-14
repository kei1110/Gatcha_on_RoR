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
end
