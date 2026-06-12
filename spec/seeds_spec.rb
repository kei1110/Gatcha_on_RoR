require "rails_helper"

RSpec.describe "db/seeds.rb", type: :model do
  it "2 回実行しても件数不変・例外なし（冪等 + seed 値が全バリデーションを通る検証を兼ねる）" do
    ActsAsTenant.test_tenant = nil # seeds は自前で with_tenant を張る
    expect { Rails.application.load_seed }.not_to raise_error

    counts = ActsAsTenant.without_tenant { [ Organization.count, User.count, WorkPattern.count, LeaveType.count, UserWorkPattern.count, OrganizationSetting.count, ReasonTemplate.count ] }
    expect { Rails.application.load_seed }.not_to raise_error
    expect(ActsAsTenant.without_tenant { [ Organization.count, User.count, WorkPattern.count, LeaveType.count, UserWorkPattern.count, OrganizationSetting.count, ReasonTemplate.count ] }).to eq(counts)
    # 割当（0b-4）: 各シード組織の社員に日勤パターンが 1 件ずつ割り当てられる
    seed_org_count = ActsAsTenant.without_tenant { Organization.where(subdomain: %w[acme globex]).count }
    expect(ActsAsTenant.without_tenant { UserWorkPattern.count }).to eq(seed_org_count)
  end
end
