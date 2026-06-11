module ApplicationHelper
  ROLE_LABELS = { "employee" => "社員", "manager" => "マネージャー", "hr_admin" => "人事管理者" }.freeze

  def t_role(role) = ROLE_LABELS.fetch(role, role)
end
