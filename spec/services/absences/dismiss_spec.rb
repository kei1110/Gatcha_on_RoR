# frozen_string_literal: true

require "rails_helper"

RSpec.describe Absences::Dismiss do
  let(:org) { create(:organization, time_zone: "Asia/Tokyo") }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  let(:manager) { create(:user, :manager_role) }
  let(:user)    { create(:user, manager: manager) }
  let(:candidate) { create(:absence_candidate, user:, target_date: Date.new(2026, 5, 1)) }

  it "候補を destroy し absence_dismissed の監査行を残す" do
    described_class.call(candidate:, actor: manager)

    expect(AbsenceCandidate.where(id: candidate.id)).not_to exist
    history = AttendanceHistory.find_by(event_type: :absence_dismissed, event_date: Date.new(2026, 5, 1))
    expect(history.user_id).to eq(user.id)
    expect(history.actor_id).to eq(manager.id)
    expect(history.absence_reason).to be_nil
  end

  it "履歴 append が失敗すると候補は残る（同一 tx で束ねる）" do
    allow(AttendanceHistory).to receive(:create!)
      .and_raise(ActiveRecord::RecordInvalid.new(AttendanceHistory.new))

    expect { described_class.call(candidate:, actor: manager) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(AbsenceCandidate.where(id: candidate.id)).to exist
  end

  it "操作者が別組織なら IneligibleError（昇格前ガード）" do
    other_actor = ActsAsTenant.with_tenant(create(:organization)) { create(:user, :manager_role) }

    expect { described_class.call(candidate:, actor: other_actor) }
      .to raise_error(Absences::IneligibleError, /組織/)
    expect(AbsenceCandidate.where(id: candidate.id)).to exist
  end

  it "候補 destroy が失敗すると履歴も残らない（同一 tx で束ねる）" do
    allow_any_instance_of(AbsenceCandidate).to receive(:destroy!)
      .and_raise(ActiveRecord::RecordNotDestroyed.new("boom", candidate))

    expect { described_class.call(candidate:, actor: manager) }.to raise_error(ActiveRecord::RecordNotDestroyed)
    expect(AttendanceHistory.where(event_type: :absence_dismissed, event_date: candidate.target_date)).not_to exist
  end
end
