# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Home", type: :request do
  let!(:org)  { create(:organization, subdomain: "acme") }
  let!(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  before { sign_in user }

  def visit_home(params = {})
    get root_url(host: tenant_host(org)), params: params
  end

  it "未出勤: ステータスと出勤ボタンが出る + 未割当バナー（割当ゼロ）" do
    travel_to Time.utc(2026, 6, 1, 1) do
      visit_home

      expect(response.body).to include("未出勤")
      expect(response.body).to include("勤務パターンが割り当てられていません")
    end
  end

  it "有効割当があれば未割当バナーは出ない（対照）" do
    ActsAsTenant.with_tenant(org) do
      create(:user_work_pattern, user:, start_date: Date.new(2026, 1, 1))
    end
    travel_to Time.utc(2026, 6, 1, 1) do
      visit_home

      expect(response.body).not_to include("勤務パターンが割り当てられていません")
    end
  end

  it "出勤中: ステータスが変わる" do
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1),
             clock_in: Time.utc(2026, 6, 1, 0))
    end
    travel_to Time.utc(2026, 6, 1, 9) do
      visit_home

      expect(response.body).to include("出勤中")
    end
  end

  it "退勤済: 注記（打刻変更申請への誘導）が出る" do
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 6, 1), status: :clocked_out,
             clock_in: Time.utc(2026, 6, 1, 0), clock_out: Time.utc(2026, 6, 1, 9))
    end
    travel_to Time.utc(2026, 6, 1, 10) do
      visit_home

      expect(response.body).to include("退勤済")
      expect(response.body).to include("時刻の修正は打刻変更申請で行えます")
    end
  end

  it "退勤忘れ: window 外の取り残し working で警告バナー" do
    ActsAsTenant.with_tenant(org) do
      create(:attendance_record, user:, work_date: Date.new(2026, 5, 29),
             clock_in: Time.utc(2026, 5, 29, 0))
    end
    travel_to Time.utc(2026, 6, 1, 1) do
      visit_home

      expect(response.body).to include("2026年5月29日 の退勤記録がありません")
    end
  end

  describe "?month= パラメータ" do
    it "有効値で当該月・不正値/範囲外は当月へフォールバック" do
      travel_to Time.utc(2026, 6, 1, 1) do
        visit_home(month: "2026-05")
        expect(response.body).to include("2026年5月")

        visit_home(month: "garbage")
        expect(response.body).to include("2026年6月")

        visit_home(month: "1999-01")
        expect(response.body).to include("2026年6月")
      end
    end
  end
end
