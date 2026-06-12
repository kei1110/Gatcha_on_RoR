module Admin
  # 設定画面（singular・0b-5 設計 §4）。組織は current_tenant のインスタンスに固定 —
  # params 由来の組織解決経路を持たない（IDOR 不能 + acts_as_tenant のリーダー短絡により
  # Updater の再計算が必ず更新後の決算月を見る・Pragma レビュー Critical の回避）
  class OrganizationSettingsController < BaseController
    before_action :set_models

    def edit
      authorize [ :admin, @organization_setting ]
    end

    def update
      authorize [ :admin, @organization_setting ]
      result = OrganizationSettings::Updater.call(
        organization: @organization,
        organization_params: organization_params,
        setting_params: organization_setting_params
      )
      if result.success?
        redirect_to edit_admin_organization_setting_path, status: :see_other,
                    notice: update_notice(result)
      else
        # failure 時 @organization（= current_tenant）の dirty 値は in-memory に残るが、
        # 本画面の再描画経路で組織属性を計算に使うコードは無い（0b-5 設計 §3 で受容。
        # 将来レイアウトが組織属性を計算へ使うなら再考）
        render :edit, status: :unprocessable_entity
      end
    end

    private

    def set_models
      @organization = ActsAsTenant.current_tenant
      @organization_setting = @organization.setting
    end

    def update_notice(result)
      if result.recalculated_count.positive?
        "年度終了月を変更し、会社カレンダー #{result.recalculated_count} 件の年度を再計算しました"
      else
        "設定を保存しました"
      end
    end

    # 編集可は 3 項目のみ（allowlist）。subdomain（テナント識別子）・active（自社ロックアウト）・
    # time_zone・organization_id は構造的に不通過（0b-5 設計 §4・テナント分離レビュー High）
    def organization_params
      params.require(:organization).permit(:fiscal_year_end_month)
    end

    def organization_setting_params
      params.require(:organization_setting).permit(:closing_day, :submit_deadline_days)
    end
  end
end
