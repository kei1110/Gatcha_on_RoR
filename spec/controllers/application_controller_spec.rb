# frozen_string_literal: true

require "rails_helper"

RSpec.describe ApplicationController, type: :controller do
  controller do
    def index
      render plain: "authorize を呼ばない action"
    end
  end

  let(:org)  { create(:organization, subdomain: "acme") }
  let(:user) { ActsAsTenant.with_tenant(org) { create(:user) } }

  before do
    @request.host = "acme.example.com"
    sign_in user
  end

  it "authorize を呼ばない action は AuthorizationNotPerformedError を起こす" do
    expect { get :index }.to raise_error(Pundit::AuthorizationNotPerformedError)
  end
end
