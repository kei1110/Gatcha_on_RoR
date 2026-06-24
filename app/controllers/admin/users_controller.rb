# frozen_string_literal: true

module Admin
  class UsersController < BaseController
    include Admin::Deactivatable

    before_action :set_user, only: %i[show edit update deactivate activate resend_invitation]

    def index
      authorize [ :admin, User ]
      @users = policy_scope([ :admin, User ]).includes(:manager).order(:employee_code)
    end

    def show
      authorize [ :admin, @user ]
      @user_work_patterns = @user.user_work_patterns.includes(:work_pattern)
                                 .order(start_date: :desc, id: :desc)
      @org_today = @user.organization.today
      # 述語は effective_on（Phase 1 取得条件と同一の単一ソース）— 「割当行ゼロ」で判定しない
      @no_effective_assignment = @user.user_work_patterns.effective_on(@org_today).none?
      # 残高は @user 経由（acts_as_tenant スコープ・@user は policy_scope 由来ゆえ IDOR なし・§3.6）
      @leave_balances = @user.leave_balances.includes(:leave_type)
                             .order(fiscal_year: :desc, leave_type_id: :asc)
    end

    def new
      @user = User.new
      authorize [ :admin, @user ]
    end

    def create
      @user = User.new(user_params)
      authorize [ :admin, @user ]
      if @user.save
        # rescue は send_invitation_instructions のみに絞る — redirect 側の例外を握り潰さない
        begin
          @user.send_invitation_instructions
        rescue StandardError => e
          Rails.error.report(e, handled: true) # SMTP 障害等を運用へ可視化（Sentry 連携前提）
          # 登録は完了している — 500 でシグナルを失わせず、再送導線へ誘導（0b-1 設計 §1 の回復経路）
          return redirect_to admin_user_path(@user), status: :see_other,
                 alert: "#{@user.name} を登録しましたが、招待メールの送信に失敗しました。一覧から再送してください"
        end
        redirect_to admin_user_path(@user), status: :see_other,
                    notice: "#{@user.name} を登録し、招待メールを送信しました"
      else
        render :new, status: :unprocessable_entity
      end
    end

    def edit
      authorize [ :admin, @user ]
    end

    def update
      authorize [ :admin, @user ]
      if @user.update(user_params)
        notice = "更新しました"
        # 旧トークンは email 変更で Devise が自動失効する（clear_reset_password_token?）。
        # 自動送信はせず明示操作（再送ボタン）へ誘導する（0b-1 設計 §2-6）
        if @user.email_previously_changed? && @user.sign_in_count.zero?
          notice += "。メールアドレスが変わったため、一覧から招待を再送してください"
        end
        # PATCH 後の redirect は 303 — Turbo の fetch は 302 だと PATCH のまま再リクエストする
        redirect_to admin_user_path(@user), status: :see_other, notice: notice
      else
        render :edit, status: :unprocessable_entity
      end
    end

    def resend_invitation
      authorize [ :admin, @user ] # resend_invitation? が 3 条件をサーバ側強制（policy 参照）
      begin
        @user.send_invitation_instructions
      rescue StandardError => e
        Rails.error.report(e, handled: true)
        return redirect_to admin_users_path, status: :see_other,
               alert: "#{@user.name} への招待メール再送に失敗しました。もう一度お試しください"
      end
      redirect_to admin_users_path, status: :see_other, notice: "#{@user.name} へ招待メールを再送しました"
    end

    private

    # 他テナント id は scope 経由 find で 404（IDOR・SPEC §3.4）。write 系もこの一本道
    def set_user
      @user = policy_scope([ :admin, User ]).find(params[:id])
    end

    def deactivatable_record = @user

    # role / manager_id / exempt_from_overtime の permit は Admin 名前空間限定（0b-1 設計 §0）。
    # active は permit しない — deactivate / activate メンバーアクション専用
    def user_params
      params.require(:user)
            .permit(:name, :email, :employee_code, :role, :manager_id, :exempt_from_overtime)
    end
  end
end
