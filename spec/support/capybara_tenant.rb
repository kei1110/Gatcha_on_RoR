# frozen_string_literal: true

module CapybaraTenantHelpers
  # サブドメイン切替。rack_test ゆえ DNS 不要
  def switch_tenant(org)
    Capybara.app_host = "http://#{org.subdomain}.example.com"
  end
end

RSpec.configure do |config|
  config.include CapybaraTenantHelpers, type: :system
  config.after(:each, type: :system) { Capybara.app_host = nil }
end
