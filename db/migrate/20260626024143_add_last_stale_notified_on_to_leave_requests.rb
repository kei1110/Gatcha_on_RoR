# frozen_string_literal: true

class AddLastStaleNotifiedOnToLeaveRequests < ActiveRecord::Migration[8.1]
  def change
    # 承認滞留アラートの重複防止（SPEC §4.9）。CCR §4.11 との非対称解消（ROADMAP #113）。
    # 消費は 4-2（滞留アラート §7.5）— 本スライスは列のみ・検証/ロジックは掛けない
    add_column :leave_requests, :last_stale_notified_on, :date
  end
end
