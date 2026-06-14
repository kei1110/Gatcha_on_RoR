# frozen_string_literal: true

# テナント整合突合（SPEC §3.1③）の一点防御。
# before_action ではなく Warden hook に置く理由: Devise のトークン経路・
# remember cookie 復元は ApplicationController の before_action を通らずに
# 認証が成立し得るため、認証確立の単一点で塞ぐ。
# 注意: User.serialize_from_session は without_tenant で復元する（devise の prepend が
# テナント解決より先に走るため）。クロステナント突合は本フックが唯一の防壁 —
# event: フィルタの追加や run_callbacks: false の使用はこの前提を壊す
Warden::Manager.after_set_user do |user, warden, opts|
  next unless user.is_a?(User)

  # 通常経路（controller 内の lazy authenticate / sign_in）では before_action 済みの
  # current_tenant を使う。Warden::Test::Helpers#login_as のように middleware 層で
  # set_user が走る経路（controller 到達前 = current_tenant 未設定）では、controller と
  # 同じ fail-closed 規則でホストのサブドメインから解決する。未知・inactive は nil の
  # まま下の突合で弾かれる（フェイルオープンにしない）
  tenant = ActsAsTenant.current_tenant ||
           Organization.find_by(subdomain: warden.request.subdomain.to_s.downcase, active: true)
  next if tenant && user.organization_id == tenant.id

  scope = opts[:scope] || :user
  warden.logout(scope)
  warden.reset_session!                                  # セッション固定対策を兼ねる
  warden.request.cookie_jar.delete(:remember_user_token) # remember 失効
  throw(:warden, scope: scope, message: :unauthenticated)
end
