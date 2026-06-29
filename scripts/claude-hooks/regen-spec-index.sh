#!/bin/bash
# PostToolUse(Edit|Write) hook: docs/SPEC.md が編集されたら、冒頭のセクション索引
# （progressive disclosure 用の行番号表）を実ファイルの見出し位置から自動補正する。
# 本文編集で索引の行番号が drift するのを防ぐ。整形器であり gate ではないので常に exit 0。
set -uo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE" ] && exit 0

case "$FILE" in
  */docs/SPEC.md|docs/SPEC.md) ;;
  *) exit 0 ;;
esac

SPEC="$CLAUDE_PROJECT_DIR/docs/SPEC.md"
[ -f "$SPEC" ] || exit 0

# ruby は .ruby-version 解決のため project root で。整形器ゆえ失敗しても握りつぶす。
ruby "$CLAUDE_PROJECT_DIR/scripts/regen_spec_index.rb" "$SPEC" >/dev/null 2>&1 || true

exit 0
