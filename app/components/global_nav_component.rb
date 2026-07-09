# frozen_string_literal: true

# 全画面共通のグローバルナビ（Admin::NavComponent 同型・layout に常設）。
# Phase 0a〜3 で実装した機能画面への唯一のクリック動線（Phase 3 spec-check で動線断絶を検出）。
# role 出し分け: 申請系は全社員 / 承認・代理打刻は manager|hr_admin / 管理は hr_admin。
class GlobalNavComponent < ViewComponent::Base
  def initialize(current_user:)
    @current_user = current_user
  end

  attr_reader :current_user

  # [label, path, match_path] の配列（role でフィルタ済）。match_path は active 前方一致の基準
  # （/admin 配下を一括 active にする「管理」のみ指定・他は nil＝path 自体で判定）。
  def links
    items = [
      [ "ホーム", helpers.root_path, nil ],
      [ "休暇申請", helpers.leave_requests_path, nil ],
      [ "打刻変更", helpers.clock_change_requests_path, nil ],
      [ "休日出勤", helpers.holiday_work_requests_path, nil ],
      [ "月次サマリ", helpers.monthly_attendance_summaries_path, nil ]
    ]
    if approver?
      items << [ "承認", helpers.approval_assignments_path, nil ]
      items << [ "代理打刻", helpers.proxy_clockings_path, nil ]
      items << [ "欠勤確定", helpers.absence_confirmations_path, nil ]
    end
    items << [ "管理", helpers.admin_users_path, "/admin" ] if current_user.hr_admin?
    items
  end

  # root("/") は完全一致・それ以外は前方一致（Admin::NavComponent#active? と同方針）。
  def active?(path, match_path = nil)
    target = match_path || path
    target == "/" ? helpers.request.path == "/" : helpers.request.path.start_with?(target)
  end

  private

  # 承認者になり得るのは manager_id 階層 = manager|hr_admin（ProxyClockingPolicy#manager_or_admin? 同型）
  def approver? = current_user.manager? || current_user.hr_admin?
end
