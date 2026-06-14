# frozen_string_literal: true

module ApplicationHelper
  ROLE_LABELS = { "employee" => "社員", "manager" => "マネージャー", "hr_admin" => "人事管理者" }.freeze

  def t_role(role) = ROLE_LABELS.fetch(role, role)

  # time 型は 2000-01-01 ダミー日付を持つ — 表示は HH:MM に統一（0b-2 設計 §5）
  def t_time(value) = value&.strftime("%H:%M")

  # enum 生値（annual 等）を画面に露出しない（0b-2 設計 §5）
  def t_system_type(value) = I18n.t("leave_types.system_types.#{value}")

  def t_day_type(value) = I18n.t("company_calendars.day_types.#{value}")

  def t_applies_to(value) = I18n.t("reason_templates.applies_to.#{value}")

  # 割当の状態バッジ（0b-4 設計 §5 — 単一リスト + 状態バッジ。today は組織 TZ の Organization#today）
  def user_work_pattern_status(assignment, today)
    return "無効" unless assignment.active?
    return "未来" if assignment.start_date > today
    return "過去" if assignment.end_date && assignment.end_date < today

    "有効"
  end
end
