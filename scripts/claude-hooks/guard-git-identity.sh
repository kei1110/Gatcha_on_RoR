#!/bin/bash
# PreToolUse(Bash) hook: git commit / push を kei1110 (eoh2145@gmail.com) identity でなければ block。
#
# 経緯: 本リポジトリは author=kei1110 / 認証=sub-account のねじれで push に躓いた。
#       誤アカウントでの commit / push を機械で封じる（CLAUDE.md § Git / Gotchas 参照）。
set -uo pipefail

EXPECTED_EMAIL="eoh2145@gmail.com"
KEI_REMOTE_PATTERN="github-kei1110:"

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""')
[ -z "$CMD" ] && exit 0

# git commit / push 以外は対象外
VERB=$(echo "$CMD" | grep -oE 'git[[:space:]]+(commit|push)' | head -1 | awk '{print $2}')
[ -z "$VERB" ] && exit 0

EMAIL=$(git config user.email 2>/dev/null || echo "")
if [ "$EMAIL" != "$EXPECTED_EMAIL" ]; then
  echo "BLOCKED: git identity ガード — user.email=「${EMAIL}」(期待: ${EXPECTED_EMAIL} / kei1110)。" >&2
  echo "修正: git config user.email ${EXPECTED_EMAIL}" >&2
  exit 2
fi

# push は remote が kei1110 経路 (github-kei1110) か確認
if [ "$VERB" = "push" ]; then
  URL=$(git remote get-url origin 2>/dev/null || echo "")
  case "$URL" in
    *"$KEI_REMOTE_PATTERN"*) ;;
    *)
      echo "BLOCKED: push 先 remote が kei1110 経路 (github-kei1110) ではありません: 「${URL}」。" >&2
      echo "SSH alias を確認してください（CLAUDE.md § Gotchas / ~/.ssh/config の github-kei1110）。" >&2
      exit 2 ;;
  esac
fi

exit 0
