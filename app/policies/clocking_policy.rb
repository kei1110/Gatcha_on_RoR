# frozen_string_literal: true

# 打刻の headless policy（authorize :clocking, :clock_in? — 1-1 設計 §3）。
# Scope は定義しない: 操作対象はコントローラ構造で current_user 固定（パラメータ不受理・
# SPEC §3.5 の最強形 — IDOR 面が存在しない）、一覧系データ取得は current_user.attendance_records
# 起点を必須とする（補償統制）。誤って policy_scope を呼べば Pundit::NotDefinedError で fail-closed。
# 将来の一覧/管理画面（§12.2 ダッシュボード等）は AttendanceRecordPolicy + Scope を新設すること。
# 代理打刻（1-3）は別コントローラ・別ポリシーで作る。
class ClockingPolicy < ApplicationPolicy
  # 全ロール可（管理監督者も打刻記録の対象 — 深夜割増 §8.3 のためにも記録は必須）。
  # literal true にせず user.present? で深層防御（HomePolicy と同型）
  def clock_in? = user.present?
  def clock_out? = user.present?
end
