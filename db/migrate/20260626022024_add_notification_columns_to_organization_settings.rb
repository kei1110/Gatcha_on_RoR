# frozen_string_literal: true

class AddNotificationColumnsToOrganizationSettings < ActiveRecord::Migration[8.1]
  def change
    # 通知抑制・二重 opt-in の組織側（SPEC §4.15）。4-1 が消費する 5 列のみ追加。
    # 閾値系・36 協定系は消費する Phase の PR が同梱（§4.15 注記）
    add_column :organization_settings, :quiet_hours_enabled, :boolean, null: false, default: true
    add_column :organization_settings, :quiet_hours_start, :integer, null: false, default: 19 # 時（0..23）
    add_column :organization_settings, :quiet_hours_end, :integer, null: false, default: 8    # 時（0..23）
    add_column :organization_settings, :holiday_block_enabled, :boolean, null: false, default: true
    add_column :organization_settings, :email_notification_enabled, :boolean, null: false, default: false # 二重 opt-in 組織側
  end
end
