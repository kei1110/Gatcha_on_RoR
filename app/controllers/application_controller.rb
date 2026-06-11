class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  include Pundit::Authorization

  set_current_tenant_through_filter
  before_action :resolve_tenant_from_subdomain
  before_action :authenticate_user!, unless: :devise_controller?

  # Devise コントローラを除外しないとログイン画面で発火する（定番穴）
  after_action :verify_authorized, unless: :devise_controller?
  # only: :index は Rails 7.1 の raise_on_missing_callback_actions と衝突するため
  # proc 条件で等価実装（HomeController など index なしコントローラに対応）
  after_action :verify_policy_scoped, if: -> { action_name == "index" }, unless: :devise_controller?

  rescue_from Pundit::NotAuthorizedError, with: :render_forbidden
  # controller 層で 404 を返す（ShowExceptions より手前）。
  # ShowExceptions に任せると session commit が保証されず、同一テスト内の後続リクエストで
  # Warden セッションが失われて authenticate_user! がリダイレクトする（302）。
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  private

  # fail-closed: 解決失敗・inactive は 404 で打ち切り、current_tenant nil のまま進まない（SPEC §3.1）
  def resolve_tenant_from_subdomain
    subdomain = request.subdomain.to_s.downcase
    organization = subdomain.presence &&
                   Organization.find_by(subdomain: subdomain, active: true)
    unless organization
      reset_session # inactive 化後の既存セッションも遮断
      raise ActiveRecord::RecordNotFound, "tenant not found"
    end
    set_current_tenant(organization)
  end

  def render_not_found
    # rescue_from はコールバックチェーン崩壊後に走るため after_action(verify_*) はこの経路で実行されない
    render plain: "見つかりません", status: :not_found
  end

  def render_forbidden
    render plain: "アクセス権がありません", status: :forbidden
  end
end
