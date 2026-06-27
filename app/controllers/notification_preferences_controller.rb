# frozen_string_literal: true

# 通知設定（設計 §5.3 / §9⑥）。User.email_enabled（個人メール opt-in SSOT）と
# UserNotificationPreference（抑制系）を 1 画面・単一 tx で更新。UNP の所有は current_user 固定。
class NotificationPreferencesController < ApplicationController
  def edit
    authorize :notification_preference, :edit?
    @preference = current_user.notification_preference || build_default_preference
  end

  def update
    authorize :notification_preference, :update?
    @preference = current_user.notification_preference || current_user.build_notification_preference
    ActiveRecord::Base.transaction do
      current_user.update!(user_params)          # permit は :email_enabled のみ
      @preference.update!(preference_params)      # user_id/organization_id は受けない（サーバ権威）
    end
    redirect_to edit_notification_preferences_path, status: :see_other, notice: "通知設定を更新しました"
  rescue ActiveRecord::RecordInvalid
    @preference ||= build_default_preference
    flash.now[:alert] = "通知設定を更新できませんでした"
    render :edit, status: :unprocessable_entity
  end

  private

  # UNP 未作成時の表示既定は OrganizationSetting フォールバック（§4.2）。has_one builder が user_id を設定。
  def build_default_preference
    s = ActsAsTenant.current_tenant.setting
    current_user.build_notification_preference(
      quiet_hours_enabled: s.quiet_hours_enabled,
      quiet_hours_start: s.quiet_hours_start,
      quiet_hours_end: s.quiet_hours_end,
      holiday_block_enabled: s.holiday_block_enabled
    )
  end

  def user_params
    params.require(:user).permit(:email_enabled)
  end

  def preference_params
    params.require(:notification_preference)
          .permit(:quiet_hours_enabled, :quiet_hours_start, :quiet_hours_end, :holiday_block_enabled)
  end
end
