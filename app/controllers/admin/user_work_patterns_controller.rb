module Admin
  # 社員詳細ネストの割当 CRUD（0b-4 設計 §4）。index/show なし — 一覧は users#show に同居。
  # Deactivatable concern は流用しない（契約が redirect_to [:admin, record] + record.name 前提で、
  # show を持たず name も無いネストリソースと不一致）— 意図的非流用
  class UserWorkPatternsController < BaseController
    before_action :set_user
    before_action :set_user_work_pattern, only: %i[edit update deactivate activate]

    def new
      @user_work_pattern = @user.user_work_patterns.new
      authorize [ :admin, @user_work_pattern ]
    end

    def create
      @user_work_pattern = @user.user_work_patterns.new(user_work_pattern_params)
      authorize [ :admin, @user_work_pattern ]
      if rescue_exclusion_conflict { @user_work_pattern.save }
        redirect_to admin_user_path(@user), status: :see_other, notice: "勤務パターンを割り当てました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @user_work_pattern ]
    end

    def update
      authorize [ :admin, @user_work_pattern ]
      if rescue_exclusion_conflict { @user_work_pattern.update(user_work_pattern_params) }
        redirect_to admin_user_path(@user), status: :see_other, notice: "割当を更新しました"
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def deactivate
      authorize [ :admin, @user_work_pattern ]
      if @user_work_pattern.update(active: false)
        redirect_to admin_user_path(@user), status: :see_other, notice: "割当を無効化しました"
      else
        redirect_to admin_user_path(@user), status: :see_other,
                    alert: @user_work_pattern.errors.full_messages.join("。")
      end
    end

    # 再有効化は重複検証・パターン有効性検証が再実行される（モデル側の発火条件）。
    # フォームが無いため失敗は 303 + alert（create/update の 422 再描画と非対称なのは意図）
    def activate
      authorize [ :admin, @user_work_pattern ]
      if rescue_exclusion_conflict { @user_work_pattern.update(active: true) }
        redirect_to admin_user_path(@user), status: :see_other, notice: "割当を再有効化しました"
      else
        redirect_to admin_user_path(@user), status: :see_other,
                    alert: @user_work_pattern.errors.full_messages.join("。")
      end
    end

    private

    # 他テナント user_id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_user
      @user = policy_scope([ :admin, User ]).find(params[:user_id])
    end

    # user 経由 + テナント default scope の二重絞り → 他テナント/他ユーザーの割当 id は 404
    def set_user_work_pattern
      @user_work_pattern = @user.user_work_patterns.find(params[:id])
    end

    # exclusion constraint 違反（TOCTOU 競合窓）だけを拾う — 広い StatementInvalid を rescue
    # すると無関係な SQL 失敗が「競合しました」に化けてシグナルを失う（0b-4 設計 §2-4）
    def rescue_exclusion_conflict(record = @user_work_pattern)
      yield
    rescue ActiveRecord::ExclusionViolation
      record.errors.add(:base, "他の操作と競合しました。再度お試しください")
      false
    end

    # user_id は URL（ネスト）から・active はメンバーアクション専用 — 改竄代入経路を閉じる（§3.6(2)）
    def user_work_pattern_params
      params.require(:user_work_pattern).permit(:work_pattern_id, :start_date, :end_date)
    end
  end
end
