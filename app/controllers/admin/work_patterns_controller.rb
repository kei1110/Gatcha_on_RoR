module Admin
  class WorkPatternsController < BaseController
    include Admin::Deactivatable

    before_action :set_work_pattern, only: %i[show edit update deactivate activate]

    def index
      authorize [ :admin, WorkPattern ]
      @work_patterns = policy_scope([ :admin, WorkPattern ]).order(:name)
    end

    def show
      authorize [ :admin, @work_pattern ]
    end

    def new
      @work_pattern = WorkPattern.new
      authorize [ :admin, @work_pattern ]
    end

    def create
      @work_pattern = WorkPattern.new(work_pattern_params)
      authorize [ :admin, @work_pattern ]
      if @work_pattern.save
        redirect_to admin_work_pattern_path(@work_pattern), status: :see_other,
                    notice: "#{@work_pattern.name} を登録しました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @work_pattern ]
    end

    def update
      authorize [ :admin, @work_pattern ]
      if @work_pattern.update(work_pattern_params)
        redirect_to admin_work_pattern_path(@work_pattern), status: :see_other, notice: "更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    # 他テナント id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_work_pattern
      @work_pattern = policy_scope([ :admin, WorkPattern ]).find(params[:id])
    end

    def deactivatable_record = @work_pattern

    # active / organization_id は permit しない（active は member アクション専用・0b-2 設計 §4）
    def work_pattern_params
      params.require(:work_pattern).permit(
        :name, :start_time, :end_time, :break_minutes, :standard_work_hours,
        :night_shift, :flextime, :core_time_start, :core_time_end,
        :morning_half_break_minutes, :afternoon_half_break_minutes)
    end
  end
end
