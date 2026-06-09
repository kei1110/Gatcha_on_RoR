#!/bin/bash
# PreToolUse(Edit|Write) hook: db/schema.rb / db/structure.sql の手編集を block。
# これらは生成物。スキーマ変更はマイグレーション経由に強制する（Rails アンチパターン防止）。
set -uo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE" ] && exit 0

case "$FILE" in
  */db/schema.rb|db/schema.rb|*/db/structure.sql|db/structure.sql)
    echo "BLOCKED: $FILE は生成物です。スキーマ変更は 'bin/rails g migration' → 'bin/rails db:migrate' 経由で行ってください。" >&2
    exit 2 ;;
esac

exit 0
