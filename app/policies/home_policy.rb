# frozen_string_literal: true

class HomePolicy < ApplicationPolicy
  def show? = user.present?
end
