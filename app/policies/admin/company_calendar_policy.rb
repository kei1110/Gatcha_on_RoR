module Admin
  # MasterPolicy 継承 + 異型 3 アクション（基底コメントの「0b-3 は個別判断」の実行 — 0b-3 設計 §4）。
  # Scope は基底の organization_id 明示（without_tenant fail-open 遮断の二重防衛）をそのまま継承
  class CompanyCalendarPolicy < MasterPolicy
    def destroy? = hr_admin? # 物理削除 — イベント参照を持たない日付事実テーブル（§12.3 の例外・設計 §0）
    def import? = hr_admin?
    def generate? = hr_admin?
  end
end
