# frozen_string_literal: true

module Admin
  # 管理画面タブナビ。0b-3 以降のマスタはこの tabs に 1 行足すだけで乗る（0b-1 設計 §1）
  class NavComponent < ViewComponent::Base
    def tabs
      [
        [ "社員", helpers.admin_users_path ],
        [ "勤務パターン", helpers.admin_work_patterns_path ],
        [ "休暇種別", helpers.admin_leave_types_path ],
        [ "会社カレンダー", helpers.admin_company_calendars_path ],
        [ "理由テンプレート", helpers.admin_reason_templates_path ],
        # singular resource はリンク先（/edit）と PATCH 先（/edit なし）が分かれるため、
        # active 判定だけリソースルートで前方一致させる（422 再描画でもハイライト維持・Task 7 品質レビュー反映）
        [ "設定", helpers.edit_admin_organization_setting_path, helpers.admin_organization_setting_path ]
      ]
    end

    # current_page? は完全一致のため配下（show/edit）で外れる — 前方一致で判定（バックログ回収）。
    # match_path があればそちらで判定（リンク先と判定基準の分離が要る singular resource 用）
    def active?(path, match_path = nil) = helpers.request.path.start_with?(match_path || path)
  end
end
