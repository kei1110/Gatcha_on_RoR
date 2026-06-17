# frozen_string_literal: true

require "rails_helper"

RSpec.describe LeaveBalance do
  let(:org) { create(:organization) }
  around { |ex| ActsAsTenant.with_tenant(org) { ex.run } }

  def in_savepoint = ActiveRecord::Base.transaction(requires_new: true) { yield }

  describe "残日数" do
    it "granted + carry_over - used" do
      b = build(:leave_balance, granted_days: 20, carry_over_days: 5, used_days: 3)
      expect(b.remaining).to eq(BigDecimal("22"))
    end
  end

  describe "一意性（org, user, leave_type, fiscal_year）" do
    it "同一キーの重複はモデル検証で無効" do
      first = create(:leave_balance)
      dup = build(:leave_balance, user: first.user, leave_type: first.leave_type, fiscal_year: "2026")
      expect(dup).to be_invalid
    end

    it "別テナントなら同一キーでも valid（鏡像）" do
      create(:leave_balance, fiscal_year: "2026")
      other = create(:organization)
      ActsAsTenant.with_tenant(other) do
        mirror = build(:leave_balance, organization: other, fiscal_year: "2026")
        expect(mirror).to be_valid
      end
    end

    it "DB 最終防衛: validate:false でも複合 unique を弾く" do
      first = create(:leave_balance)
      expect {
        in_savepoint do
          build(:leave_balance, user: first.user, leave_type: first.leave_type, fiscal_year: "2026")
            .save!(validate: false)
        end
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "granted_on 必須（D5・paid×annual のみ）" do
    let(:annual) { create(:leave_type, system_type: :annual, paid_leave: true) }

    it "paid×annual で granted_on なしは無効" do
      b = build(:leave_balance, leave_type: annual, granted_on: nil)
      expect(b).to be_invalid
      expect(b.errors[:granted_on]).to be_present
    end

    it "paid×annual で granted_on ありは valid" do
      b = build(:leave_balance, leave_type: annual, granted_on: Date.new(2026, 4, 1))
      expect(b).to be_valid
    end

    it "非該当種別（:other）は granted_on なしでも valid" do
      expect(build(:leave_balance, granted_on: nil)).to be_valid
    end
  end

  describe "テナント越境（ID 基点 fail-closed）" do
    it "他テナントの user は無効" do
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:user) }
      b = build(:leave_balance)
      b.user = outsider
      expect(b).to be_invalid
      expect(b.errors[:user]).to be_present
    end

    it "他テナントの leave_type は無効" do
      outsider = ActsAsTenant.with_tenant(create(:organization)) { create(:leave_type) }
      b = build(:leave_balance)
      b.leave_type = outsider
      expect(b).to be_invalid
      expect(b.errors[:leave_type]).to be_present
    end
  end

  describe "DB 最終防衛（FK）" do
    it "validate:false の越境 user_id は FK 違反" do
      other_org = create(:organization)
      outsider = ActsAsTenant.with_tenant(other_org) { create(:user) }
      expect {
        in_savepoint { build(:leave_balance).tap { |b| b.user_id = outsider.id }.save!(validate: false) }
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end

    it "validate:false の越境 leave_type_id は FK 違反" do
      other_org = create(:organization)
      outsider = ActsAsTenant.with_tenant(other_org) { create(:leave_type) }
      expect {
        in_savepoint { build(:leave_balance).tap { |b| b.leave_type_id = outsider.id }.save!(validate: false) }
      }.to raise_error(ActiveRecord::InvalidForeignKey)
    end
  end
end
