# frozen_string_literal: true

module Approvals
  # 自己承認規則の単一ソース（SPEC §7.3 #1/#2）。enforce はサービス層と Pundit の二層。
  module SelfApproval
    module_function

    def violated?(requester_id:, approver_id:, acting_user_id:)
      approver_id == requester_id || acting_user_id == requester_id
    end
  end
end
