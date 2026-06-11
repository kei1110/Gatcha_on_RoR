module ApplicationHelper
  ROLE_LABELS = { "employee" => "社員", "manager" => "マネージャー", "hr_admin" => "人事管理者" }.freeze

  def t_role(role) = ROLE_LABELS.fetch(role, role)

  # time 型は 2000-01-01 ダミー日付を持つ — 表示は HH:MM に統一（0b-2 設計 §5）
  def t_time(value) = value&.strftime("%H:%M")

  # enum 生値（annual 等）を画面に露出しない（0b-2 設計 §5）
  def t_system_type(value) = I18n.t("leave_types.system_types.#{value}")
end
