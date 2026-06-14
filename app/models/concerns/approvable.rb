# frozen_string_literal: true

# 承認対象に業務ステータス（AASM）と段階導出を与える（SPEC §7.1・§13.2）。
# 段階情報は status に持たず ApprovalAssignment 群から導出する。
# host が満たすべき契約:
#   - acts_as_tenant(:organization) を宣言（サービス層が @approvable.organization を要求）
#   - belongs_to :requester, class_name: "User"（RouteResolver が requester.manager を遡行）
module Approvable
  extend ActiveSupport::Concern

  included do
    has_many :approval_assignments, as: :approvable, dependent: :destroy

    # enum を aasm より先に宣言（class ロード時にマッピングを解決するため）。
    # 整数 0–3 は凍結。4=withdrawal_requested / 5=withdrawn は 2-5 用に予約（§4.14 同型）。
    enum :approval_status, { applying: 0, approved: 1, rejected: 2, canceled: 3 }

    include AASM
    aasm column: :approval_status, enum: true, whiny_persistence: true do # whiny_persistence: true → bang の save 失敗を例外化（偽 success 隠蔽を防止）
      state :applying, initial: true
      state :approved
      state :rejected
      state :canceled

      event :approve do
        transitions from: :applying, to: :approved, guard: :all_stages_approved?
      end
      event :reject do
        transitions from: :applying, to: :rejected
      end
      event :cancel do
        transitions from: :applying, to: :canceled
      end
    end
  end

  # 最小の pending 段階 position（なければ nil）。association キャッシュに依存せず DB を引く
  def current_approval_position
    approval_assignments.where(decision: :pending).minimum(:position)
  end

  # 全 assignment が approved（最終 approve の guard）。assignment 皆無なら false
  # 2 クエリ（exists? 皆無チェック + where.not 存在チェック）。可読性優先
  def all_stages_approved?
    approval_assignments.exists? &&
      !approval_assignments.where.not(decision: :approved).exists?
  end
end
