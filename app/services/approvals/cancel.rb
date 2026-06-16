# frozen_string_literal: true

module Approvals
  # 申請の取消（Phase 2-2a 設計 §3.3・2-1 後置の回収）。applying→canceled・副作用なし。
  # 認可は cancel? Pundit と service 内 by==requester の二層（§7.3 同思想）。
  # with_lock は前置（二重クリック耐性 + 2-2b approve と形を揃える seam）。
  class Cancel
    def self.call(approvable:, by:) = new(approvable, by).call

    def initialize(approvable, by)
      @approvable = approvable
      @by = by
    end

    def call
      @approvable.with_lock do
        raise SelfApprovalError unless @by.id == @approvable.requester_id

        @approvable.cancel!   # AASM applying→canceled（whiny_persistence で偽 success 化を防ぐ）
      end
      @approvable
    end
  end
end
