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

    describe "勤務間インターバル（§6.9・4-2d）" do
      let!(:manager) { ActsAsTenant.with_tenant(org) { create(:user, role: :manager) } }
      before { ActsAsTenant.with_tenant(org) { user.update!(manager: manager) } }

      def clock_in_at(time)
        travel_to(time) { post clock_in_clocking_url(host: tenant_host(org)) }
      end

      before do
        # 前日 JST 22:00 退勤（UTC 6/1 13:00）
        ActsAsTenant.with_tenant(org) do
          create(:attendance_record, :done, user:, work_date: Date.new(2026, 6, 1),
                 clock_in: Time.utc(2026, 6, 1, 4), clock_out: Time.utc(2026, 6, 1, 13))
        end
        sign_in user
      end

      it "不足時: 打刻は成功（303）+ AH 記録 + note 追記 + 警告 flash + manager へ通知（非ブロック複合 assert・§10⑧）" do
        expect {
          clock_in_at(Time.utc(2026, 6, 1, 23)) # JST 6/2 08:00 出勤 = 休息 10h
        }.to change { AttendanceRecord.unscoped.where(user:).count }.by(1)
          .and change { AttendanceHistory.unscoped.where(event_type: :interval_shortage).count }.by(1)
          .and change { Notification.unscoped.where(target_user: manager, source_type: :interval_shortage).count }.by(1)

        expect(response).to have_http_status(:see_other)
        travel_to(Time.utc(2026, 6, 1, 23)) do
          follow_redirect!
          expect(response.body).to include("出勤を記録しました")
          expect(response.body).to include("勤務間インターバルが不足")
        end
        record = AttendanceRecord.unscoped.where(user:).order(:work_date).last
        expect(record.note).to include("勤務間インターバル不足")
      end

      it "非違反（休息 11h）: AH も通知も警告も出ない（対照）" do
        expect {
          clock_in_at(Time.utc(2026, 6, 2, 0)) # JST 6/2 09:00 出勤 = 休息 11h ちょうど
        }.to change { AttendanceRecord.unscoped.where(user:).count }.by(1)
        expect(AttendanceHistory.unscoped.where(event_type: :interval_shortage).count).to eq(0)
        expect(Notification.unscoped.where(source_type: :interval_shortage).count).to eq(0)
      end

      it "manager 不在（トップ階層）でも打刻と記録は成功し、通知だけ skip" do
        ActsAsTenant.with_tenant(org) { user.update!(manager: nil) }
        expect {
          clock_in_at(Time.utc(2026, 6, 1, 23))
        }.to change { AttendanceHistory.unscoped.where(event_type: :interval_shortage).count }.by(1)
        expect(Notification.unscoped.where(source_type: :interval_shortage).count).to eq(0)
        expect(response).to have_http_status(:see_other)
      end

      it "通知が失敗しても打刻応答は覆らない（§9.5 レジリエンス）" do
        allow(Notifier).to receive(:call).and_raise(StandardError, "boom")
        expect {
          clock_in_at(Time.utc(2026, 6, 1, 23))
        }.to change { AttendanceRecord.unscoped.where(user:).count }.by(1)
        expect(response).to have_http_status(:see_other)
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
