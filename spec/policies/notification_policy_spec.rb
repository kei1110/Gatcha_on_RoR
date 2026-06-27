# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationPolicy do
  let(:org)   { create(:organization) }
  let(:owner) { ActsAsTenant.with_tenant(org) { create(:user) } }
  let(:other) { ActsAsTenant.with_tenant(org) { create(:user) } }
  let(:notification) { ActsAsTenant.with_tenant(org) { create(:notification, target_user: owner) } }

  it "update?（既読化）は target_user 本人のみ true" do
    expect(described_class.new(owner, notification).update?).to be(true)
    expect(described_class.new(other, notification).update?).to be(false)
  end

  describe "Scope" do
    it "自分宛のみ解決する（同一テナント他人は除外）" do
      ActsAsTenant.with_tenant(org) do
        mine = create(:notification, target_user: owner)
        theirs = create(:notification, target_user: other)
        resolved = NotificationPolicy::Scope.new(owner, Notification).resolve
        expect(resolved).to include(mine)
        expect(resolved).not_to include(theirs)
      end
    end
  end
end
