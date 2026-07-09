# frozen_string_literal: true

# 欠勤確定の service 名前空間（Approvals 同型）。controller が rescue して 422 に落とす。
module Absences
  class Error < StandardError; end

  # 確定不可（毒入力理由 / 候補不在日 / 本人未通知 / 猶予前）。適正手続きの入口ガード（§10⑤・§12①）
  class IneligibleError < Error; end

  # 締め済み（submitted / finalized）月の日付は確定不可（§11⑦・§12⑩）
  class ClosingLockedError < Error; end
end
