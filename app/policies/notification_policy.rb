# frozen_string_literal: true

# 通知の認可（設計 §9⑤）。acts_as_tenant は越境のみ遮断ゆえ同一テナント他人を Pundit で塞ぐ。
class NotificationPolicy < ApplicationPolicy
  def index? = user.present?
  def update? = record.target_user_id == user.id # 既読化は本人のみ（IDOR 防止）

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(target_user_id: user.id)
  end
end
