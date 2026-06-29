# frozen_string_literal: true

require "rails_helper"

RSpec.describe AbsenceCandidate, type: :model do
  let(:org) { create(:organization) }

  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  it "有効な候補を作成できる" do
    user = create(:user)
    expect(build(:absence_candidate, user:, target_date: Date.new(2026, 5, 1))).to be_valid
  end

  it "同一 (user, target_date) は二重作成できない（テナント内 unique）" do
    user = create(:user)
    create(:absence_candidate, user:, target_date: Date.new(2026, 5, 1))
    dup = build(:absence_candidate, user:, target_date: Date.new(2026, 5, 1))
    expect { dup.save!(validate: false) }.to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "scope :unnotified は notified_on 未設定のみ" do
    user = create(:user)
    pending = create(:absence_candidate, user:, target_date: Date.new(2026, 5, 1), notified_on: nil)
    notified = create(:absence_candidate, user:, target_date: Date.new(2026, 5, 2), notified_on: Date.current)
    expect(described_class.unnotified).to include(pending)
    expect(described_class.unnotified).not_to include(notified)
  end

  describe "同一組織強制（§3.6・二層防御）" do
    let(:other) { create(:organization) }
    let(:other_user) { ActsAsTenant.with_tenant(other) { create(:user) } }

    it "他組織 user の候補は DB 複合 FK で拒否（model 層を貫通）" do
      c = build(:absence_candidate, user: nil, target_date: Date.new(2026, 5, 1))
      c.user_id = other_user.id # 他組織 id を直挿（acts_as_tenant の nil ロードを迂回）
      expect { c.save!(validate: false) }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end

  it "他テナントの候補は default scope で見えない" do
    other = create(:organization)
    ActsAsTenant.with_tenant(other) { create(:absence_candidate, user: create(:user)) }
    expect(described_class.count).to eq(0) # org 文脈では他社 0 件
  end
end
