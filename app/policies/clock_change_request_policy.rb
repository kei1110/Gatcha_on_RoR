# frozen_string_literal: true

# 打刻変更申請の認可（2-3 設計 §3.3・LeaveRequestPolicy 同型）。requester=current_user 固定ゆえ本人前提。
class ClockChangeRequestPolicy < ApplicationPolicy
  def index? = user.present?
  def new? = user.present?
  def create? = user.present?

  def cancel? = record.requester_id == user.id && record.applying?

  def request_withdrawal?
    record.requester_id == user.id && record.approved? && record.no_prior_withdrawal_round?
  end

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(requester_id: user.id)
  end
end
