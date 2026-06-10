RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :rack_test # 0a の system spec は JS 不要。CI に Chrome も不要になる
  end
end
