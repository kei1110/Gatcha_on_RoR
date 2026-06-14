# frozen_string_literal: true

module CompanyCalendars
  # 行番号付きエラー（line nil = ファイル全体のエラー）。パーサ・アップサータ・ビルダー共通
  RowError = Data.define(:line, :message)
end
