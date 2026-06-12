module Admin
  class CompanyCalendarsController < BaseController
    before_action :set_company_calendar, only: %i[edit update destroy]

    def index
      authorize [ :admin, CompanyCalendar ]
      scope = policy_scope([ :admin, CompanyCalendar ])
      @fiscal_year = params[:fiscal_year].presence || current_fiscal_year
      @fiscal_years = (scope.distinct.pluck(:fiscal_year) | [ current_fiscal_year ]).sort.reverse
      @company_calendars = scope.where(fiscal_year: @fiscal_year).order(:date)
      # 35% 保護: §4.7「legal_holiday の登録を必須運用とする」の画面側の網（0b-3 設計 §4）。
      # レコード 0 件の年度でも意図的に表示する — 未整備年度こそ登録を促す対象（レビュー I-1 の確認済み判断）
      @legal_holiday_missing = scope.where(fiscal_year: @fiscal_year, day_type: :legal_holiday).none?
    end

    def new
      @company_calendar = CompanyCalendar.new
      authorize [ :admin, @company_calendar ]
    end

    def create
      @company_calendar = CompanyCalendar.new(company_calendar_params)
      authorize [ :admin, @company_calendar ]
      if @company_calendar.save
        redirect_to admin_company_calendars_path, status: :see_other,
                    notice: "#{@company_calendar.date} を登録しました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @company_calendar ]
    end

    def update
      authorize [ :admin, @company_calendar ]
      if @company_calendar.update(company_calendar_params)
        redirect_to admin_company_calendars_path, status: :see_other, notice: "更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    # 物理削除 — イベント参照を持たない日付事実テーブル（§12.3 の無効化統一の例外・0b-3 設計 §0。
    # 締め済み月に属する日付の削除制限は Phase 1 の締めフロー導入時に課す）
    def destroy
      authorize [ :admin, @company_calendar ]
      @company_calendar.destroy!
      redirect_to admin_company_calendars_path, status: :see_other,
                  notice: "#{@company_calendar.date} を削除しました"
    end

    private

    # 他テナント id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_company_calendar
      @company_calendar = policy_scope([ :admin, CompanyCalendar ]).find(params[:id])
    end

    # Organization#today（組織 TZ）必須 — Date.current は UTC 設定下で JST 0:00〜8:59 に
    # 前日を返し、年度初日の朝に前年度を初期選択してしまう（0b-4 規約の遡及適用・外部レビュー指摘）
    def current_fiscal_year
      tenant = ActsAsTenant.current_tenant
      tenant.fiscal_year_for(tenant.today)
    end

    # fiscal_year / organization_id は permit しない（fiscal_year は date から自動導出 — 0b-3 設計 §2）
    def company_calendar_params
      params.require(:company_calendar).permit(:date, :day_type, :name, :counts_as_paid_leave)
    end
  end
end
