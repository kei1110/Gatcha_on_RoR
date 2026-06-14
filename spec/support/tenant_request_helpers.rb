# frozen_string_literal: true

module TenantRequestHelpers
  def tenant_host(org) = "#{org.subdomain}.example.com"
end

RSpec.configure do |config|
  config.include TenantRequestHelpers, type: :request
  config.include TenantRequestHelpers, type: :system
  config.include Devise::Test::IntegrationHelpers, type: :request
end
