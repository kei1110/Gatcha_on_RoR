#!/bin/bash
# PreToolUse(Edit|Write) hook: シークレットの編集を block。
#   - config/master.key / config/credentials/*.key（Rails 認証情報の鍵）
#   - .env / .env.*（環境変数）
# テンプレート（.env.example / .sample / .template）は許可。
set -uo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE" ] && exit 0

# テンプレートは許可
case "$FILE" in
  *.env.example|*.env.sample|*.env.template) exit 0 ;;
esac

case "$FILE" in
  */config/master.key|config/master.key|*/config/credentials/*.key|*.env|*/.env|*/.env.*)
    echo "BLOCKED: シークレットの編集は禁止です: $FILE" >&2
    echo "master.key / credentials の鍵 / .env は手動で扱ってください（.gitignore 済み）。" >&2
    exit 2 ;;
esac

exit 0
