# frozen_string_literal: true

class AddWithdrawalReasonToLeaveRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :leave_requests, :withdrawal_reason, :text
  end
end
