# frozen_string_literal: true

# 通知一覧 + 既読化（設計 §5.2 / §9⑤）。policy_scope + authorize の二層で IDOR を塞ぐ。
class NotificationsController < ApplicationController
  def index
    authorize Notification
    @notifications = policy_scope(Notification).order(created_at: :desc)
  end

  def update
    @notification = policy_scope(Notification).find(params[:id]) # 他人/他テナントは 404
    authorize @notification # update? = 本人のみ（二層目）
    @notification.update!(read_at: Time.current)
    redirect_to notifications_path, status: :see_other, notice: "既読にしました"
  end
end
