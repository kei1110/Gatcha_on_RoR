# frozen_string_literal: true

# Approvable concern を検証するためのテスト専用ホスト（Phase 2-1: 本番 approvable 不在）。
# クラス定義は load 時でよい（enum/aasm は列を introspect しない）。テーブルだけ before(:suite) で作る。
class ApprovalTestRecord < ApplicationRecord
  acts_as_tenant(:organization)
  belongs_to :requester, class_name: "User"
  include Approvable
end

RSpec.configure do |config|
  config.before(:suite) do
    conn = ActiveRecord::Base.connection
    conn.create_table(:approval_test_records, if_not_exists: true) do |t|
      t.references :organization, null: false
      t.references :requester, null: false
      t.integer :approval_status, null: false, default: 0
      t.timestamps
    end
  end
end
