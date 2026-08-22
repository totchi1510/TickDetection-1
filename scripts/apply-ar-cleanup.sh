#!/usr/bin/env bash
# =============================================================================
# Artifact Registry に保持ポリシーを設定する
#
# 現状どのリポジトリにもポリシーが無く、ビルドしたイメージが無期限に溜まる。
# AR は $0.10/GB/月 の課金があり、予算 ¥1,000/月 に対して支配的なコストに
# なっていたため、上限を設ける。
#
# ポリシー:
#   - タグ無しバージョン: 7日で削除
#   - タグ付きバージョン: 最新5世代を保持
#
# 使い方:
#   ./scripts/apply-ar-cleanup.sh --dry-run   # 何が削除されるかだけ表示
#   ./scripts/apply-ar-cleanup.sh             # 実際に適用
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-global-sign-475613-j2}"
POLICY_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ar-cleanup-policy.json"

DRY_RUN_FLAG="--no-dry-run"
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN_FLAG="--dry-run"
  echo "*** DRY RUN モード: 実際には削除しません ***"
fi

# repo:location
REPOS=(
  "cloud-run-source-deploy:asia-northeast1"
  "base:asia-northeast1"
  "ml-apps:asia-northeast2"
)

for entry in "${REPOS[@]}"; do
  repo="${entry%%:*}"
  loc="${entry##*:}"

  if ! gcloud artifacts repositories describe "$repo" \
        --location="$loc" --project="$PROJECT_ID" >/dev/null 2>&1; then
    echo "--> $repo @ $loc: 存在しないのでスキップ"
    continue
  fi

  echo "--> $repo @ $loc にポリシーを適用"
  gcloud artifacts repositories set-cleanup-policies "$repo" \
    --location="$loc" \
    --project="$PROJECT_ID" \
    --policy="$POLICY_FILE" \
    "$DRY_RUN_FLAG"
done

echo
echo "=== 適用後のサイズ ==="
for entry in "${REPOS[@]}"; do
  repo="${entry%%:*}"; loc="${entry##*:}"
  size="$(gcloud artifacts repositories describe "$repo" --location="$loc" \
          --project="$PROJECT_ID" --format='value(sizeBytes)' 2>/dev/null \
          | grep -oP 'Repository Size: \K[0-9.]+' || echo '?')"
  printf "  %-28s %s MB\n" "$repo @ $loc" "$size"
done
echo
echo "注意: ポリシーの反映は即時ではありません (数時間〜1日かかることがあります)。"
