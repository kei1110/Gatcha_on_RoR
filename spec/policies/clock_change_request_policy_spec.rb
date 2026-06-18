# frozen_string_literal: true

require "rails_helper"

RSpec.describe ClockChangeRequestPolicy, type: :policy do
  subject { described_class.new(actor, record) }

  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:owner) { create(:user, organization: org) }
  let(:other) { create(:user, organization: org) }
  let(:ar) { create(:attendance_record, :done, user: owner) }
  let(:record) { create(:clock_change_request, requester: owner, attendance_record: ar) }

  context "本人" do
    let(:actor) { owner }
    it { is_expected.to permit_actions(%i[index new create cancel]) }
  end

  context "第三者" do
    let(:actor) { other }
    it { is_expected.to forbid_actions(%i[cancel]) }
  end

  context "terminal（canceled）には cancel 不可" do
    let(:actor) { owner }
    before { record.cancel! }
    it { is_expected.to forbid_actions(%i[cancel]) }
  end

  describe "Scope" do
    it "自分の申請のみ" do
      mine = record
      others_ar = create(:attendance_record, :done, user: other)
      create(:clock_change_request, requester: other, attendance_record: others_ar)
      resolved = ClockChangeRequestPolicy::Scope.new(owner, ClockChangeRequest).resolve
      expect(resolved).to contain_exactly(mine)
    end
  end
end
