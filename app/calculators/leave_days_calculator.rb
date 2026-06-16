# frozen_string_literal: true

# 取得日数の純計算（SPEC §5.5・Phase 2-2a 設計 §2.1）。値→値（DB 非依存・§2.2-1）。
# classifications = { Date => { day_type: Symbol, counts_as_paid_leave: Boolean } }（service 層が合成）。
# 計上日 = weekday、または company_holiday かつ counts_as_paid_leave=true。
# 除外日 = saturday/sunday（所定休日）・holiday・legal_holiday・company_holiday(counts_as_paid_leave=false)。
class LeaveDaysCalculator
  def self.call(classifications:, half_day_type:)
    # 防御 assert（設計 §2.1・原則整合 MPR）: 半休は単日が入力契約。上流の start==end 検証
    # バイパス時に不定値を返さない fail-closed。
    if half_day_type != :none && classifications.size > 1
      raise ArgumentError, "半休は単日のみ（classifications.size=#{classifications.size}）"
    end

    counted = classifications.count { |_date, info| counted?(info) }
    factor = half_day_type == :none ? 1 : 0.5
    BigDecimal(counted.to_s) * BigDecimal(factor.to_s)
  end

  def self.counted?(info)
    case info[:day_type]
    when :weekday then true
    when :company_holiday then info[:counts_as_paid_leave]
    else false   # saturday / sunday / holiday / legal_holiday
    end
  end
  private_class_method :counted?
end
