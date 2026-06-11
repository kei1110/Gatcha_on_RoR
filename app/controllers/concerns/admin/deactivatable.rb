module Admin
  # deactivate / activate の共通実装（User / WorkPattern / LeaveType — 0b-2 設計 §1）。
  # 契約: include 側は member アクションの before_action でレコードをセットし、
  # deactivatable_record で返すこと。本 concern は finder を一切持たない
  # （fail-closed — policy_scope 経由 find は各コントローラの set_* の責務）
  module Deactivatable
    extend ActiveSupport::Concern

    def deactivate
      record = deactivatable_record
      authorize [ :admin, record ]
      if record.update(active: false)
        redirect_to [ :admin, record ], status: :see_other, notice: "#{record.name} を無効化しました"
      else
        redirect_to [ :admin, record ], status: :see_other,
                    alert: record.errors.full_messages.join("。")
      end
    end

    def activate
      record = deactivatable_record
      authorize [ :admin, record ]
      if record.update(active: true)
        redirect_to [ :admin, record ], status: :see_other, notice: "#{record.name} を再有効化しました"
      else
        redirect_to [ :admin, record ], status: :see_other,
                    alert: record.errors.full_messages.join("。")
      end
    end

    private

    def deactivatable_record = raise NotImplementedError
  end
end
