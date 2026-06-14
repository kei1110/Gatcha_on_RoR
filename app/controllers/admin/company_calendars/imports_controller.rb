# frozen_string_literal: true

module Admin
  module CompanyCalendars
    class ImportsController < BaseController
      def new
        authorize [ :admin, CompanyCalendar ], :import? # レコード不在 → クラス authorize（0b-3 設計 §4）
      end

      def create
        authorize [ :admin, CompanyCalendar ], :import?
        @allow_demotion = params[:allow_demotion] == "1" # 422 再描画時の checkbox 状態保持
        parsed = ::CompanyCalendars::CsvParser.parse(params[:file])
        if parsed.success?
          result = ::CompanyCalendars::BulkUpserter.new(
            organization: ActsAsTenant.current_tenant,
            allow_demotion: @allow_demotion).call(parsed.rows)
          if result.success?
            redirect_to admin_company_calendars_path, status: :see_other,
                        notice: "取り込みました（作成 #{result.created_count} 件・更新 #{result.updated_count} 件）"
            return
          end
          @errors = result.errors
        else
          @errors = parsed.errors
        end
        render :new, status: :unprocessable_entity
      end
    end
  end
end
