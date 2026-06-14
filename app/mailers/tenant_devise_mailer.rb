# frozen_string_literal: true

class TenantDeviseMailer < Devise::Mailer
  # 招待メール（Devise 標準外のカスタムアクション）。User#send_invitation_instructions から届く
  def invitation_instructions(record, token, opts = {})
    @token = token
    devise_mail(record, :invitation_instructions, opts)
  end

  protected

  # deliver_later はリクエストコンテキストを持たないため、
  # 宛先ユーザーの organization からサブドメイン込み host を組み立てる
  def devise_mail(record, action, opts = {}, &block)
    @tenant_url_options = {
      host: "#{record.organization.subdomain}.#{Rails.application.config.x.tenant_base_host}",
      port: Rails.application.config.x.tenant_base_port
    }.compact
    super
  end

  def default_url_options
    @tenant_url_options || super
  end
end
