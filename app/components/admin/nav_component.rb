module Admin
  # 管理画面タブナビ。0b-2 以降のマスタはこの tabs に 1 行足すだけで乗る（0b-1 設計 §1）
  class NavComponent < ViewComponent::Base
    def tabs
      [ [ "社員", helpers.admin_users_path ] ]
    end
  end
end
