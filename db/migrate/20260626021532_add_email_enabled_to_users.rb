# frozen_string_literal: true

class AddEmailEnabledToUsers < ActiveRecord::Migration[8.1]
  def change
    # 個人メール通知 opt-in（SPEC §4.3・二重 opt-in の個人側 SSOT）。
    # 既定 false（opt-out から開始）・boolean は NULL 三値を作らない
    add_column :users, :email_enabled, :boolean, null: false, default: false
  end
end
