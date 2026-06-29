#!/usr/bin/env ruby
# frozen_string_literal: true

# docs/SPEC.md 冒頭「セクション索引（progressive disclosure）」表の行番号を、
# 実ファイルの見出し位置から再計算して補正する。
#
# 設計（行番号補正方式・全自動生成ではない）:
#   - 節名・短縮名・★急所マーカーは人が育てる資産なので「保持」する。
#   - 機械が直すのは drift する数値だけ ＝ 範囲列 "A–B" と サブ節の "(行)"。
#   - 節の増減（行の追加/削除）は手で索引に行を足す運用。その後の数値はこれが整える。
# 冪等: 変更が無ければ書き込まない（フックの無駄な再書き込みを防ぐ）。
# 呼び出し: フック(scripts/claude-hooks/regen-spec-index.sh) からも手動からも。
#   使い方: ruby scripts/regen_spec_index.rb [path/to/SPEC.md]

DASH = "–" # en dash "–"（範囲列の区切り）

path = ARGV[0] || "docs/SPEC.md"
abort "regen_spec_index: not found: #{path}" unless File.file?(path)

lines = File.readlines(path, chomp: true)
total = lines.size

# --- 見出し位置を収集（1-based 行番号） ---
# "## セクション索引" は索引自身なので top に入れない（§ の連続性を壊さないため）。
top  = [] # [key, line_no] key = "0".."16" or "rev"
subs = {} # "N.M" => line_no
lines.each_with_index do |ln, i|
  no = i + 1
  if (m = ln.match(/\A## (\d+)\. /))
    top << [ m[1], no ]
  elsif ln.start_with?("## 改訂履歴")
    top << [ "rev", no ]
  elsif (m = ln.match(/\A### (\d+\.\d+) /))
    subs[m[1]] = no
  end
end

# トップレベル範囲 = [自行, 次のトップレベル見出し-1]、最後はファイル末尾。
ranges = {}
top.each_with_index do |(key, start), idx|
  finish = idx + 1 < top.size ? top[idx + 1][1] - 1 : total
  ranges[key] = [ start, finish ]
end

# --- 索引テーブルのデータ行を補正 ---
changed = false
lines.map! do |ln|
  next ln unless ln.start_with?("|")                 # 表の行のみ
  next ln if ln =~ /\A\|\s*節\s*\|/ || ln =~ /\A\|\s*-+/ # ヘッダ・区切りは除外

  key =
    if (m = ln.match(/\*\*§(\d+)\*\*/)) then m[1]
    elsif ln.include?("改訂履歴") then "rev"
    end
  next ln unless key && ranges[key]

  a, b = ranges[key]
  new_ln = ln.dup
  # 範囲列 "A–B"（行内で最初に現れる en dash 数値ペア）を補正
  new_ln = new_ln.sub(/\d+#{DASH}\d+/, "#{a}#{DASH}#{b}")
  # サブ節 "N.M <名>(行)" の (行) を実位置で補正。★や名前テキストは温存。
  new_ln = new_ln.gsub(/(\d+\.\d+)([^()|]*)\((\d+)\)/) do
    sec = ::Regexp.last_match(1)
    mid = ::Regexp.last_match(2)
    old = ::Regexp.last_match(3)
    pos = subs[sec]
    pos ? "#{sec}#{mid}(#{pos})" : "#{sec}#{mid}(#{old})"
  end

  changed ||= new_ln != ln
  new_ln
end

if changed
  File.write(path, "#{lines.join("\n")}\n")
  warn "regen_spec_index: #{path} のセクション索引の行番号を補正しました。"
end
