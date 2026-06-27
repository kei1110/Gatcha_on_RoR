# frozen_string_literal: true

# 通知設定の認可（設計 §9⑤）。current_user 自身の設定ゆえ presence で開く（headless）。
class NotificationPreferencePolicy < ApplicationPolicy
  def edit? = user.present?
  def update? = user.present?
end
