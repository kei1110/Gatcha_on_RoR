module Admin
  # 0b-3 CompanyCalendarPolicy と同じく MasterPolicy 継承（0b-4 設計 §4 の判断）。
  # index/show はルートを持たない（一覧は社員詳細に同居）ため基底の index?/show? 定義は未到達
  class UserWorkPatternPolicy < MasterPolicy
  end
end
