# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Clockings", type: :request do
  let!(:org)  { create(:organization, subdomain: "acme") } # TZ 既定 Asia/Tokyo
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  describe "エラー文言の網羅" do
    it "Result の error シンボル全種に ja 文言が定義されている（動的キー t() の translation missing 防止）" do
      %i[already_clocked_in still_working not_working].each do |key|
        expect(I18n.exists?("clockings.errors.#{key}", :ja)).to be(true), "missing: clockings.errors.#{key}"
      end
    end
  end

  describe "POST /clocking/clock_in" do
    it "未認証はサインインへ（レコードも作成されない）" do
      expect {
        post clock_in_clocking_url(host: tenant_host(org))
      }.not_to change { AttendanceRecord.unscoped.count }
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))
    end

    it "打刻して 303 でホームへ・成功 flash（Turbo の 302 メソッド保持対策 = see_other 必須）" do
      sign_in user
      travel_to Time.utc(2026, 6, 1, 1) do
        expect {
          post clock_in_clocking_url(host: tenant_host(org))
        }.to change { AttendanceRecord.unscoped.where(user: user).count }.by(1)

        expect(response).to redirect_to(root_url(host: tenant_host(org)))
        expect(response).to have_http_status(:see_other)
        follow_redirect!
        expect(response.body).to include("出勤を記録しました")
      end
    end

    it "パラメータに他人の user_id を混ぜても current_user に記録される（SPEC §3.5 — パラメータ不受理）" do
      other = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in user
      travel_to Time.utc(2026, 6, 1, 1) do
        post clock_in_clocking_url(host: tenant_host(org)),
             params: { user_id: other.id, clocking: { user_id: other.id } }
      end

      expect(AttendanceRecord.unscoped.where(user: other)).to be_empty
      expect(AttendanceRecord.unscoped.where(user: user).count).to eq(1)
    end

    it "二重打刻は 303 + alert で合流（SPEC §6.1）" do
      sign_in user
      travel_to Time.utc(2026, 6, 1, 1) do
        post clock_in_clocking_url(host: tenant_host(org))
        post clock_in_clocking_url(host: tenant_host(org))

        expect(response).to have_http_status(:see_other)
        follow_redirect!
        expect(response.body).to include("すでに出勤済みです")
      end
    end
  end

  describe "POST /clocking/clock_out" do
    it "退勤して 303・成功 flash" do
      ActsAsTenant.with_tenant(org) do
        create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
               clock_in: Time.utc(2026, 6, 1, 0))
      end
      sign_in user
      travel_to Time.utc(2026, 6, 1, 9) do
        post clock_out_clocking_url(host: tenant_host(org))

        expect(response).to have_http_status(:see_other)
        follow_redirect!
        expect(response.body).to include("退勤を記録しました")
      end
    end

    it "working なしは 303 + alert（打刻変更申請への誘導文言）" do
      sign_in user
      travel_to Time.utc(2026, 6, 1, 9) do
        post clock_out_clocking_url(host: tenant_host(org))
        follow_redirect!
        expect(response.body).to include("出勤打刻がありません")
      end
    end
  end
end
