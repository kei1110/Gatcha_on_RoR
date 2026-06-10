require "rails_helper"

RSpec.describe HomePolicy, type: :policy do
  subject { described_class.new(user, :home) }

  context "ログイン済みユーザー" do
    let(:user) { create(:user) }
    it { is_expected.to permit_action(:show) }
  end

  context "未認証（user が nil）" do
    let(:user) { nil }
    it { is_expected.to forbid_action(:show) }
  end
end
