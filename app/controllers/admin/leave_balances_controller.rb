# frozen_string_literal: true

module Admin
  # 社員詳細ネストの残高 CRUD（Phase 2-2a 設計 §5・UserWorkPatternsController と同型のフラット構成）。
  # index/show なし — 一覧は users#show に同居。used_days/user_id は permit せず改竄経路を閉じる。
  class LeaveBalancesController < BaseController
    before_action :set_user
    before_action :set_leave_balance, only: %i[edit update]

    def new
      @leave_balance = @user.leave_balances.new
      authorize [ :admin, @leave_balance ]
    end

    def create
      @leave_balance = @user.leave_balances.new(leave_balance_params)
      authorize [ :admin, @leave_balance ]
      if @leave_balance.save
        redirect_to admin_user_path(@user), status: :see_other, notice: "残高を登録しました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @leave_balance ]
    end

    def update
      authorize [ :admin, @leave_balance ]
      if @leave_balance.update(leave_balance_params)
        redirect_to admin_user_path(@user), status: :see_other, notice: "残高を更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_user
      @user = policy_scope([ :admin, User ]).find(params[:user_id])
    end

    def set_leave_balance
      @leave_balance = @user.leave_balances.find(params[:id])
    end

    # user_id は URL（ネスト）から・used_days は 2-2b approve 専有 — 改竄代入経路を閉じる（§3.6(2)）
    def leave_balance_params
      params.require(:leave_balance)
            .permit(:leave_type_id, :fiscal_year, :granted_days, :carry_over_days, :granted_on)
    end
  end
end
