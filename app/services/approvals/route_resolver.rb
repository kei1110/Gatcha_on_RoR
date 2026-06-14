# frozen_string_literal: true

module Approvals
  # 固定 2 段ルート解決（SPEC §7.2）。requester → [stage1, stage2] or [stage1]（単段縮約）。
  # テナント文脈下で呼ぶこと（User#manager は acts_as_tenant スコープ）。
  class RouteResolver
    def self.call(requester:) = new(requester).call

    def initialize(requester)
      @requester = requester
    end

    def call
      stage1 = @requester.manager
      raise RouteError.new(:manager_unset) if stage1.nil?

      [ stage1, resolve_stage2(stage1) ].compact.uniq(&:id)
    end

    private

    def resolve_stage2(stage1)
      if @requester.employee?
        stage1.manager                                  # 部門長（上上長）。nil なら単段縮約
      else
        # else = manager? / hr_admin?（hr_admin 申請者は §7.2 表に無く manager ルートに準拠）
        first_hr_admin_up_chain(stage1) || raise(RouteError.new(:hr_admin_unset))
      end
    end

    # requester.manager（=stage1）から上昇し最初の hr_admin を返す。requester 自身は始点に含めない。
    # NOTE: User#manager_chain_must_not_cycle は書込時のみ動作し、並行 save の競合窓は v1 受容済みの既知限界。
    def first_hr_admin_up_chain(node)
      while node
        return node if node.hr_admin?

        node = node.manager
      end
      nil
    end
  end
end
