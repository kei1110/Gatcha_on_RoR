# frozen_string_literal: true

module Admin
  class ReasonTemplatesController < BaseController
    include Admin::Deactivatable

    before_action :set_reason_template, only: %i[show edit update deactivate activate]

    def index
      authorize [ :admin, ReasonTemplate ]
      @reason_templates = policy_scope([ :admin, ReasonTemplate ]).order(:label)
    end

    def show
      authorize [ :admin, @reason_template ]
    end

    def new
      @reason_template = ReasonTemplate.new
      authorize [ :admin, @reason_template ]
    end

    def create
      @reason_template = ReasonTemplate.new(reason_template_params)
      authorize [ :admin, @reason_template ]
      if @reason_template.save
        redirect_to admin_reason_template_path(@reason_template), status: :see_other,
                    notice: "#{@reason_template.label} を登録しました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @reason_template ]
    end

    def update
      authorize [ :admin, @reason_template ]
      if @reason_template.update(reason_template_params)
        redirect_to admin_reason_template_path(@reason_template), status: :see_other, notice: "更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    # 他テナント id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_reason_template
      @reason_template = policy_scope([ :admin, ReasonTemplate ]).find(params[:id])
    end

    def deactivatable_record = @reason_template

    # active / organization_id は permit しない（マスタ規約）
    def reason_template_params
      params.require(:reason_template).permit(:label, :template_text, :applies_to)
    end
  end
end
