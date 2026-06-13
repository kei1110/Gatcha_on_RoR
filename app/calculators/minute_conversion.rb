# 丸め規則の単一ソース（1-2 設計 §3.5・SPEC §5 前文）。
# 中間計算は整数分・最終値のみ時間化（HALF_UP）— 各 calculator へ複製しないこと。
# 第 3 のメソッドは消費者が現れてから足す（YAGNI）
module MinuteConversion
  module_function

  # 全ての分換算は「差分秒 ÷ 60 の整数除算（floor）」で統一（1-2 設計 §0）。
  # TimeWithZone の減算は Float 秒だが、打刻は usec=0 保証（ClockIn/ClockOut で切り詰め）ゆえ
  # 分境界一致時の差分は整数で正確 — floor は安全
  def minutes_between(from, to) = ((to - from) / 60).floor

  def to_hours(minutes) = (minutes.to_d / 60).round(2, half: :up)
end
