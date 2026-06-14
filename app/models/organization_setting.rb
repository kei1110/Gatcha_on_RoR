# frozen_string_literal: true

class OrganizationSetting < ApplicationRecord
  # SPEC §4.15 の残カラム（通知系・閾値系・36 協定系・integer[]）は消費する Phase の PR が
  # 検証・既定値・意味論ごと同梱追加する（0b-5 設計 §0 — ROADMAP 4-1 email_enabled 方式）。
  # 法定値は本テーブルに置かない（§4.15 注記 — テナント改変可能になってはならない）
  acts_as_tenant(:organization)

  validates :closing_day, inclusion: { in: 1..31 } # 31 = 月末扱い（SPEC §4.15）
  # 28 = 2 月の最短月長 — どの月でも実在する日に収める
  validates :submit_deadline_days, inclusion: { in: 1..28 }
  # [organization_id] unique index の DB 例外前にフォームエラー化（テナント毎 1 行）
  validates :organization_id, uniqueness: true
end
