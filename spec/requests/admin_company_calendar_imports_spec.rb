require "rails_helper"

RSpec.describe "Admin::CompanyCalendars::Imports", type: :request do
  let!(:org)   { create(:organization, subdomain: "acme") }
  let!(:admin) { ActsAsTenant.with_tenant(org) { create(:user, :hr_admin) } }

  def upload(content)
    file = Tempfile.new([ "calendar", ".csv" ])
    file.write(content)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, "text/csv")
  end

  let(:valid_csv) { "date,day_type,name,counts_as_paid_leave\n2026-01-01,holiday,元日,\n" }

  it "未認証はサインインへ・employee は 403（フォーム・実行とも）" do
    get new_admin_company_calendars_import_url(host: tenant_host(org))
    expect(response).to redirect_to(new_user_session_url(host: tenant_host(org)))

    employee = ActsAsTenant.with_tenant(org) { create(:user) }
    sign_in employee
    get new_admin_company_calendars_import_url(host: tenant_host(org))
    expect(response).to have_http_status(:forbidden)
    post admin_company_calendars_import_url(host: tenant_host(org)), params: { file: upload(valid_csv) }
    expect(response).to have_http_status(:forbidden)
    expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.count }).to eq(0)
  end

  describe "hr_admin" do
    before { sign_in admin }

    it "取り込み成功で一覧へ（303・作成/更新件数の notice）" do
      post admin_company_calendars_import_url(host: tenant_host(org)), params: { file: upload(valid_csv) }
      expect(response).to have_http_status(:see_other)
      expect(response).to redirect_to(admin_company_calendars_url(host: tenant_host(org)))
      follow_redirect!
      expect(response.body).to include("作成 1 件").and include("更新 0 件")
    end

    it "エラー CSV は 422 + 行番号表示 + DB 不変（全件不採用）" do
      bad = "date,day_type,name,counts_as_paid_leave\n2026-01-01,holiday,元日,\nbogus,holiday,x,\n"
      post admin_company_calendars_import_url(host: tenant_host(org)), params: { file: upload(bad) }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("3 行目")
      expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.count }).to eq(0)
    end

    it "降格 checkbox: 未チェックで 422・チェックで成功（35% 保護）" do
      ActsAsTenant.with_tenant(org) { create(:company_calendar, date: "2026-05-10", day_type: :legal_holiday) }
      demote = "date,day_type,name,counts_as_paid_leave\n2026-05-10,holiday,祝日,\n"

      post admin_company_calendars_import_url(host: tenant_host(org)), params: { file: upload(demote) }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("法定休日")

      post admin_company_calendars_import_url(host: tenant_host(org)),
           params: { file: upload(demote), allow_demotion: "1" }
      expect(response).to have_http_status(:see_other)
      expect(ActsAsTenant.with_tenant(org) { CompanyCalendar.find_by!(date: "2026-05-10").day_type }).to eq("holiday")

      # 降格チェック付きで別エラーが出ても checkbox 状態は保持される（422 再描画）
      bad = "date,day_type,name,counts_as_paid_leave\nbogus,holiday,x,\n"
      post admin_company_calendars_import_url(host: tenant_host(org)),
           params: { file: upload(bad), allow_demotion: "1" }
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include('checked="checked"')
    end

    it "file 無しは 422（500 にしない）" do
      post admin_company_calendars_import_url(host: tenant_host(org))
      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.body).to include("ファイルを選択")
    end
  end
end
