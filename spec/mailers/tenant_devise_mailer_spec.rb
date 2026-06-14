# frozen_string_literal: true

require "rails_helper"

RSpec.describe TenantDeviseMailer, type: :mailer do
  describe "#invitation_instructions" do
    let(:org_a) { create(:organization, subdomain: "orga") }
    let(:user)  { ActsAsTenant.with_tenant(org_a) { create(:user, name: "招待 花子") } }

    it "鏡像: URL は宛先の組織サブドメインで組まれ、current_tenant に依存しない（偽テスト防止の要）" do
      org_b = create(:organization, subdomain: "orgb")
      mail = ActsAsTenant.with_tenant(org_b) do
        TenantDeviseMailer.invitation_instructions(user, "RAWTOKEN123")
      end
      body = mail.body.decoded
      expect(body).to include("orga.example.com")
      expect(body).not_to include("orgb.example.com")
    end

    it "文面に期限の案内と自己再設定（パスワードを忘れた）の導線を含む" do
      body = TenantDeviseMailer.invitation_instructions(user, "RAWTOKEN123").body.decoded
      expect(body).to include("6 時間")
      expect(body).to include("再設定")
    end

    it "本文に内部パスワード片（hex 64 文字）を含まない" do
      body = TenantDeviseMailer.invitation_instructions(user, "RAWTOKEN123").body.decoded
      expect(body).not_to match(/[0-9a-f]{64}/)
    end

    it "差出人が devise 生成時の placeholder のままでない（docs/RAILS_GOTCHAS.md「生成物・設定」）" do
      from = TenantDeviseMailer.invitation_instructions(user, "RAWTOKEN123").from.first
      expect(from).not_to include("please-change-me")
      expect(from).to match(URI::MailTo::EMAIL_REGEXP)
    end

    it "件名が ja.yml の定義どおり（humanize フォールバックでない）" do
      mail = TenantDeviseMailer.invitation_instructions(user, "RAWTOKEN123")
      expect(mail.subject).to eq("【Gatcha】アカウント登録のご案内")
    end
  end
end
