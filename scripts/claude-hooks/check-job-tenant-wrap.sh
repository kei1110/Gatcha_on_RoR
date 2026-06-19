#!/bin/bash
# PostToolUse(Edit|Write) hook: app/jobs の Job が perform 内で ActsAsTenant.with_tenant を
# 使わず、かつディスパッチャ（Organization 列挙 → 子ジョブ enqueue）でもない場合に Claude へ警告
# （exit 2 = フィードバック）。SPEC §3.6: リクエスト文脈の無いジョブは acts_as_tenant の自動スコープが
# 効かず、with_tenant ラップ漏れはスコープ付きモデル操作の全社横断漏洩になる（不可逆の重大事故）。
# check-tenant-scope.sh（models）の対称版（jobs）。rails new 前は app/jobs が無く no-op。
set -uo pipefail

INPUT=$(cat)
FILE=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
[ -z "$FILE" ] && exit 0

# app/jobs/*.rb 以外は対象外
case "$FILE" in
  */app/jobs/*.rb|app/jobs/*.rb) ;;
  *) exit 0 ;;
esac
[ -f "$FILE" ] || exit 0

# perform を持たない（application_job.rb・基底クラス・concern 等）は対象外
grep -qE 'def[[:space:]]+perform' "$FILE" || exit 0

# 既に with_tenant でラップ済み / 明示的なテナント安全宣言（tenant-safe コメント）→ OK
grep -qE 'ActsAsTenant\.with_tenant|tenant-safe' "$FILE" && exit 0

# ディスパッチャ（Organization を列挙して子ジョブを enqueue する親）は自身のラップ不要 → OK。
# Organization はテナントルートゆえスコープ外列挙可（§3.6 のディスパッチャ→子ジョブ反復パターン）。
if grep -qE '\bOrganization\b' "$FILE" && grep -qE 'perform_later|perform_async|\.set\(' "$FILE"; then
  exit 0
fi

echo "TENANT-SAFETY (SPEC §3.6): $(basename "$FILE") の perform が ActsAsTenant.with_tenant でラップされていません。" >&2
echo "リクエスト文脈の無いジョブは acts_as_tenant の自動スコープが効かず、スコープ付きモデルの操作が" >&2
echo "全テナント横断で漏洩します。worker は ActsAsTenant.with_tenant(org) { ... } でブロックスコープしてください。" >&2
echo "（org を列挙して子ジョブを撒くディスパッチャは Organization + perform_later を含めれば対象外。" >&2
echo "意図的に全社横断で良い場合は perform 内に 'tenant-safe' コメントを添えて明示してください。）" >&2
exit 2
