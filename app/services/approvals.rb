# frozen_string_literal: true

# 承認エンジンの名前空間（SPEC §7）。エラークラスをここに集約し、
# Zeitwerk がサブディレクトリの各サービスを autoload する前に定義済みにする
# （Clockings モジュールと同型の namespace-file パターン）。
module Approvals
  class Error < StandardError; end

  # ルート解決不能（manager 未設定 / チェーンに hr_admin 不在）。上位は「申請不可・セットアップ要」で握る
  class RouteError < Error
    attr_reader :reason

    def initialize(reason)
      @reason = reason
      super("approval route error: #{reason}")
    end
  end

  class SelfApprovalError < Error; end   # #1/#2 自己承認
  class NotCurrentApprover < Error; end  # 現段階の担当者でない / 段階順序違反
  class ProxyNotSupported < Error; end   # 2-1 は acting_user==approver を pin（代理は §7.5）
  class OverBalanceError < Error; end     # 承認時の残高不足（D1 ハード拒否・2-2b）
  class ConflictError < Error; end        # 打刻変更承認時の競合（§7.4・2-3）
end
