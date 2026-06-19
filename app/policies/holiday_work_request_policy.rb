# frozen_string_literal: true

# 休日出勤申請の認可（2-4 設計 §3.2・ClockChangeRequestPolicy 同型）。requester=current_user 固定。
class HolidayWorkRequestPolicy < ApplicationPolicy
  def index? = user.present?
  def new? = user.present?
  def create? = user.present?

  def cancel? = record.requester_id == user.id && record.applying?

  class Scope < ApplicationPolicy::Scope
    def resolve = scope.where(requester_id: user.id)
  end
end
