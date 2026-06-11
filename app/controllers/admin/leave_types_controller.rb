module Admin
  class LeaveTypesController < BaseController
    include Admin::Deactivatable

    before_action :set_leave_type, only: %i[show edit update deactivate activate]

    def index
      authorize [ :admin, LeaveType ]
      @leave_types = policy_scope([ :admin, LeaveType ]).order(:name)
    end

    def show
      authorize [ :admin, @leave_type ]
    end

    def new
      @leave_type = LeaveType.new
      authorize [ :admin, @leave_type ]
    end

    def create
      @leave_type = LeaveType.new(leave_type_params)
      authorize [ :admin, @leave_type ]
      if @leave_type.save
        redirect_to admin_leave_type_path(@leave_type), status: :see_other,
                    notice: "#{@leave_type.name} を登録しました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @leave_type ]
    end

    def update
      authorize [ :admin, @leave_type ]
      if @leave_type.update(leave_type_params)
        redirect_to admin_leave_type_path(@leave_type), status: :see_other, notice: "更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    # 他テナント id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_leave_type
      @leave_type = policy_scope([ :admin, LeaveType ]).find(params[:id])
    end

    def deactivatable_record = @leave_type

    # active / organization_id は permit しない（0b-2 設計 §4）
    def leave_type_params
      params.require(:leave_type).permit(:name, :system_type, :allow_half_day, :paid_leave, :description)
    end
  end
end
