#!/bin/bash
# PreToolUse(Edit|Write) hook: Gemfile.lock の手編集を block。
# これは bundler の生成物。依存変更は Gemfile 編集 → 'bundle install' 経由に強制する
# （手編集は checksum 不整合・platform 欠落の温床。Bash の bundle 実行は妨げない）。
set -uo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE" ] && exit 0

case "$FILE" in
  */Gemfile.lock|Gemfile.lock)
    echo "BLOCKED: $FILE は bundler の生成物です。依存変更は Gemfile を編集して 'bundle install'（更新は 'bundle update <gem>'）経由で行ってください。" >&2
    exit 2 ;;
esac

exit 0
