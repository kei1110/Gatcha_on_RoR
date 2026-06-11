module Admin
  # 管理画面タブナビ。0b-3 以降のマスタはこの tabs に 1 行足すだけで乗る（0b-1 設計 §1）
  class NavComponent < ViewComponent::Base
    def tabs
      [
        [ "社員", helpers.admin_users_path ],
        [ "勤務パターン", helpers.admin_work_patterns_path ],
        [ "休暇種別", helpers.admin_leave_types_path ]
      ]
    end

    # current_page? は完全一致のため配下（show/edit）で外れる — 前方一致で判定（バックログ回収）
    def active?(path) = helpers.request.path.start_with?(path)
  end
end
