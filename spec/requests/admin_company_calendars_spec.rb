require "rails_helper"

RSpec.describe "Admin::CompanyCalendars", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }
  let!(:calendar) do
    ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-05-04", name: "みどりの日") }
  end

  describe "認可" do
    it "未認証はサインインへ・employee は 403・hr_admin は 200（対照）" do
      get admin_company_calendars_url(host: tenant_host(org))
      expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

      employee = ActsAsTenant.with_tenant(org) { create(:user) }
      sign_in employee
      get admin_company_calendars_url(host: tenant_host(org))
      expect(response).to have_http_status(:forbidden)

      sign_in admin
      get admin_company_calendars_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end
  end

  describe "index（hr_admin）" do
    before { sign_in admin }

    it "年度フィルタ既定値の TZ 境界: JST 4/1 8:59（UTC 3/31）でも新年度を初期選択する（Organization#today 経由）" do
      # 3 月決算（factory 既定）: JST 2027-04-01 は 2027 年度。Date.current（UTC）だと 3/31 → 2026 年度に化ける
      travel_to Time.utc(2027, 3, 31, 23, 59) do
        get admin_company_calendars_url(host: tenant_host(org))
      end

      # legal_holiday 0 件の年度では必ず警告バナーが出る — そこに @fiscal_year が露出する
      expect(response.body).to include("2027 年度に法定休日")
    end

    it "年度フィルタ: 既定は今年度・指定年度のみ表示し enum 生値を露出しない" do
      old = ActsAsTenant.with_tenant(org) do
        create(:company_calendar, date: "2020-01-01", name: "過去の元日")
      end
      get admin_company_calendars_url(host: tenant_host(org)), params: { fiscal_year: "2026" }
      expect(response.body).to include("みどりの日")
      expect(response.body).not_to include("過去の元日")
      expect(response.body).not_to include(">holiday<") # i18n 表示ヘルパ経由

      get admin_company_calendars_url(host: tenant_host(org)), params: { fiscal_year: "2019" }
      expect(response.body).to include("過去の元日")
      expect(old.fiscal_year).to eq("2019")
    end

    it "legal_holiday 0 件で警告バナー・1 件以上で非表示（35% 保護・対照ペア）" do
      get admin_company_calendars_url(host: tenant_host(org)), params: { fiscal_year: "2026" }
      expect(response.body).to include("法定休日（legal_holiday）が 1 件も登録されていません")

      ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-05-10", day_type: :legal_holiday) }
      get admin_company_calendars_url(host: tenant_host(org)), params: { fiscal_year: "2026" }
      expect(response.body).not_to include("1 件も登録されていません")
    end
  end

  describe "CRUD（hr_admin）" do
    before { sign_in admin }

    it "new フォームが表示できる" do
      get new_admin_company_calendar_url(host: tenant_host(org))
      expect(response).to have_http_status(:ok)
    end

    it "作成できる（fiscal_year は自動導出）" do
      post admin_company_calendars_url(host: tenant_host(org)), params: { company_calendar: {
        date: "2026-08-13", day_type: "company_holiday", name: "夏季休業", counts_as_paid_leave: "1" } }
      created = ActsAsTenant.with_tenant(org) { CompanyCalendar.find_by!(date: "2026-08-13") }
      expect(response).to redirect_to(admin_company_calendars_url(host: tenant_host(org)))
      expect(response).to have_http_status(:see_other)
      expect(created.fiscal_year).to eq("2026")
    end

    it "enum 不正値・相関違反は 422 + 状態不変" do
      patch admin_company_calendar_url(calendar, host: tenant_host(org)),
            params: { company_calendar: { day_type: "bogus" } }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(calendar.reload.day_type).to eq("holiday")

      patch admin_company_calendar_url(calendar, host: tenant_host(org)),
            params: { company_calendar: { counts_as_paid_leave: "1" } } # holiday のままでは不可
      expect(response).to have_http_status(:unprocessable_entity)
      expect(calendar.reload.counts_as_paid_leave).to be(false)
    end

    it "permit 境界: fiscal_year と organization_id は無視される" do
      other_org = create(:organization)
      patch admin_company_calendar_url(calendar, host: tenant_host(org)),
            params: { company_calendar: { name: "改名", fiscal_year: "1999", organization_id: other_org.id } }
      calendar.reload
      expect(calendar.name).to eq("改名")
      expect(calendar.fiscal_year).to eq("2026") # date 由来の自動導出のまま
      expect(calendar.organization_id).to eq(org.id)
    end

    it "legal_holiday の edit には 35% 降格警告が出る・holiday には出ない（対照）" do
      lh = ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-05-17", day_type: :legal_holiday) }
      get edit_admin_company_calendar_url(lh, host: tenant_host(org))
      expect(response.body).to include("35% 割増の対象から外れます")

      get edit_admin_company_calendar_url(calendar, host: tenant_host(org))
      expect(response.body).not_to include("35% 割増の対象から外れます")
    end

    it "削除できる（303・一覧へ）" do
      delete admin_company_calendar_url(calendar, host: tenant_host(org))
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_company_calendars_url(host: tenant_host(org)))
      expect(flash[:notice]).to include("2026-05-04")
      expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.exists?(calendar.id) }).to be(false)
    end

    it "show ルートは存在しない（一覧 → edit 直行・設計 §1）" do
      expect {
        get admin_company_calendar_url(calendar, host: tenant_host(org))
      }.to raise_error(ActionController::RoutingError)
    end
  end

  describe "IDOR（全 member アクション 404）" do
    let!(:other) { ActsAsTenant.with_tenant(create(:organization, subdomain: "globex")) { create(:company_calendar) } }

    before { sign_in admin }

    it "edit / update / destroy すべて 404・副作用なし" do
      get edit_admin_company_calendar_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      patch admin_company_calendar_url(other, host: tenant_host(org)),
            params: { company_calendar: { name: "x" } }
      expect(response).to have_http_status(:not_found)
      delete admin_company_calendar_url(other, host: tenant_host(org))
      expect(response).to have_http_status(:not_found)
      expect(ActsAsTenant.without_tenant { CompanyCalendar.exists?(other.id) }).to be(true)
    end
  end
end
