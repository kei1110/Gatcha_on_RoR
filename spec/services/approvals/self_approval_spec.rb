# frozen_string_literal: true

require "rails_helper"

RSpec.describe Approvals::SelfApproval do
  def violated?(req:, app:, act:)
    described_class.violated?(requester_id: req, approver_id: app, acting_user_id: act)
  end

  it "approver が requester 本人なら violated（#1 直接）" do
    expect(violated?(req: 1, app: 1, act: 1)).to be true
  end

  it "acting_user が requester 本人なら violated（#2 代理）" do
    expect(violated?(req: 1, app: 2, act: 1)).to be true
  end

  it "いずれも requester でなければ violated でない" do
    expect(violated?(req: 1, app: 2, act: 2)).to be false
  end
end
