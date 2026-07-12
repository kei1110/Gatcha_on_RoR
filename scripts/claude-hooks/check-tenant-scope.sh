#!/bin/bash
# PostToolUse(Edit|Write) hook: app/models の ActiveRecord モデルに acts_as_tenant が
# 無ければ Claude へ警告（exit 2 = フィードバック）。SPEC §3.6 のクロステナント漏洩防止。
# Edit も対象（既存モデルから acts_as_tenant を外す変更もすり抜けさせない）。
# rails new 前は app/models が無く no-op。
set -uo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE" ] && exit 0

# app/models/*.rb 以外は対象外
case "$FILE" in
  */app/models/*.rb|app/models/*.rb) ;;
  *) exit 0 ;;
esac
[ -f "$FILE" ] || exit 0

# ApplicationRecord 継承だが acts_as_tenant も abstract_class も無い → 警告
if grep -qE '<[[:space:]]*ApplicationRecord' "$FILE" \
   && ! grep -qE 'acts_as_tenant|abstract_class[[:space:]]*=[[:space:]]*true' "$FILE"; then
  echo "TENANT-SAFETY (SPEC §3.6): $(basename "$FILE") に acts_as_tenant(:organization) が見当たりません。" >&2
  echo "行レベルマルチテナントでは付与が必須です（Organization 等のテナントルートを除く）。" >&2
  echo "意図的に除外する場合は、その旨をコメントで明示してください。" >&2
  exit 2
fi

exit 0
