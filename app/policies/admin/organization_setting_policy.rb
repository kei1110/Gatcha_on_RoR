# frozen_string_literal: true

module Admin
  # singleton 設定画面（0b-2 設計 §0 が予告した「異型」— MasterPolicy 非継承の個別判断）。
  # 本ポリシーは設定画面アグリゲート（OrganizationSetting + Organization.fiscal_year_end_month）の
  # 認可を所掌する — Organization 側の更新も update? が宣言的に代理（0b-5 設計 §4）。
  # Scope は定義しない: index 不在・verify_policy_scoped は index のみ強制・誤って policy_scope を
  # 呼べば Pundit::NotDefinedError で fail-closed。テナント安全の補償統制は controller の
  # current_tenant 固定取得に在る。将来 show/一覧系を足すなら Scope 追加が必須
  class OrganizationSettingPolicy < ApplicationPolicy
    def edit? = update?
    def update? = user.hr_admin?
  end
end
