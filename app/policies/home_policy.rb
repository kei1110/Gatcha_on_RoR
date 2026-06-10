class HomePolicy < ApplicationPolicy
  def show? = user.present?
end
