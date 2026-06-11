module Admin
  module CompanyCalendars
    class LegalHolidayGenerationsController < BaseController
      def new
        authorize [ :admin, CompanyCalendar ], :generate?
      end

      def create
        authorize [ :admin, CompanyCalendar ], :generate?
        built = ::CompanyCalendars::LegalHolidayRowsBuilder.build(
          start_date: params[:start_date], end_date: params[:end_date], cwday: params[:cwday])
        if built.success?
          # 生成は legal_holiday への上書きのみ（労働者有利方向）— allow_demotion 不要
          result = ::CompanyCalendars::BulkUpserter.new(
            organization: ActsAsTenant.current_tenant).call(built.rows)
          if result.success?
            redirect_to admin_company_calendars_path, status: :see_other,
                        notice: "法定休日を登録しました（作成 #{result.created_count} 件・更新 #{result.updated_count} 件）"
            return
          end
          @errors = result.errors
        else
          @errors = built.errors
        end
        render :new, status: :unprocessable_entity
      end
    end
  end
end
