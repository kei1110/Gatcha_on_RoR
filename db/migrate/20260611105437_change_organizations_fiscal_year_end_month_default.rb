class ChangeOrganizationsFiscalYearEndMonthDefault < ActiveRecord::Migration[8.1]
  # 三重既定値（§4.2 nullable / §4.15 既定 3 / コード内 nil→3）の解消 — SSOT を DB 制約へ昇格し
  # コード内 nil フォールバックを置かない（サイレント 3 月締め化の構造的排除・0b-3 設計 §0）
  def up
    execute "UPDATE organizations SET fiscal_year_end_month = 3 WHERE fiscal_year_end_month IS NULL"
    change_column_default :organizations, :fiscal_year_end_month, 3
    change_column_null :organizations, :fiscal_year_end_month, false
  end

  def down
    # NOTE: backfill した行（元 NULL）は 3 のまま — 戻すのはスキーマ制約のみ
    change_column_null :organizations, :fiscal_year_end_month, true
    change_column_default :organizations, :fiscal_year_end_month, nil
  end
end
