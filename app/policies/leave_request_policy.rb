# frozen_string_literal: true

# 申請側の認可（Phase 2-2a 設計 §6）。requester=current_user 固定ゆえ本人前提。
# index でも verify_authorized が発火する本アプリ規約に合わせ index? を定義。
class LeaveRequestPolicy < ApplicationPolicy
  def index? = user.present?
  def new? = user.present?
  def create? = user.present?
  def preview? = user.present?   # 本人見積り（controller が requester を current_user に固定）

  def cancel? = record.requester_id == user.id && record.applying?

  def request_withdrawal?
    record.requester_id == user.id && record.approved? && record.no_prior_withdrawal_round?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(requester_id: user.id)
  end
end
