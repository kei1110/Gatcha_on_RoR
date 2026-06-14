# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationPolicy, type: :policy do
  subject { described_class.new(user, record) }

  let(:user) { create(:user) }
  let(:record) { :anything }

  it { is_expected.to forbid_all_actions } # 既定 deny

  describe "Scope" do
    it "resolves to none by default（policy_scope 経由の漏洩防止）" do
      scope = ApplicationPolicy::Scope.new(user, User.all).resolve
      expect(scope).to be_empty
    end
  end
end
