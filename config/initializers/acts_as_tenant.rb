# frozen_string_literal: true

ActsAsTenant.configure do |config|
  # テナント未設定のクエリを例外化し、ラップ漏れを構造的に検出する（SPEC §2.2-6）
  config.require_tenant = true
end
