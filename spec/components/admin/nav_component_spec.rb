# frozen_string_literal: true

require "rails_helper"

RSpec.describe Admin::NavComponent, type: :component do
  it "配下パス（/admin/users/123）でも社員タブが active・他タブは非 active（バックログ回収）" do
    with_request_url "/admin/users/123" do
      render_inline(described_class.new)
    end
    active = page.find("a", text: "社員")
    expect(active[:class]).to include("font-bold")
    expect(page.find("a", text: "勤務パターン")[:class]).not_to include("font-bold")
    expect(page.find("a", text: "休暇種別")[:class]).not_to include("font-bold")
  end
end
