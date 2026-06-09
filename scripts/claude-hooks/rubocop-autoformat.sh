#!/bin/bash
# PostToolUse(Edit|Write) hook: 編集された .rb を rubocop -A で自動整形。
# Gemfile があるとき（= rails new 後）のみ動作。rails new 前は no-op。
# 整形器であり gate ではないので常に exit 0。
set -uo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE" ] && exit 0

case "$FILE" in *.rb) ;; *) exit 0 ;; esac
[ -f Gemfile ] || exit 0     # rails new 前は no-op
[ -f "$FILE" ] || exit 0

if bundle exec rubocop --version >/dev/null 2>&1; then
  bundle exec rubocop -A "$FILE" >/dev/null 2>&1 || true
fi

exit 0
