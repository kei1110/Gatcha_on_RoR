# frozen_string_literal: true

require "rails_helper"

RSpec.describe NotificationMailer, type: :mailer do
  describe "#notify" do
    let(:org) { create(:organization, subdomain: "acme") }
    let(:user) { ActsAsTenant.with_tenant(org) { create(:user, email: "u@example.com") } }
    let(:notification) do
      ActsAsTenant.with_tenant(org) do
        create(:notification, target_user: user, title: "申請が承認されました",
                              body: "あなたの休暇申請が承認されました。")
      end
    end

    subject(:mail) { described_class.notify(notification) }

    it "宛先は target_user のメール" do
      expect(mail.to).to eq([ "u@example.com" ])
    end

    it "件名は notification.title" do
      expect(mail.subject).to eq("申請が承認されました")
    end

    it "本文に notification.body を含む" do
      expect(mail.text_part.body.to_s).to include("あなたの休暇申請が承認されました。")
      expect(mail.html_part.body.to_s).to include("あなたの休暇申請が承認されました。")
    end

    it "リンクは組織サブドメイン入り（§9⑦・job 文脈で request 無し）" do
      expect(mail.text_part.body.to_s).to include("acme.")
      expect(mail.html_part.body.to_s).to include("acme.")
    end

    it "別テナント文脈でも org のサブドメインで組む（current_tenant 由来でない・鏡像）" do
      other = create(:organization, subdomain: "other")
      ActsAsTenant.with_tenant(other) do
        expect(mail.text_part.body.to_s).to include("acme.")
        expect(mail.html_part.body.to_s).to include("acme.")
        expect(mail.text_part.body.to_s).not_to include("other.")
        expect(mail.html_part.body.to_s).not_to include("other.")
      end
    end
  end
end
