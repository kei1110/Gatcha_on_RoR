RSpec.configure do |config|
  config.before(:each) do |example|
    if %i[request system].include?(example.metadata[:type])
      # 解決フィルタ自身を検証するため test_tenant を立てない（偽テスト防止）
      ActsAsTenant.test_tenant = nil
    else
      ActsAsTenant.test_tenant = FactoryBot.create(:organization)
    end
  end

  config.after(:each) do
    ActsAsTenant.current_tenant = nil
    ActsAsTenant.test_tenant = nil
  end
end
