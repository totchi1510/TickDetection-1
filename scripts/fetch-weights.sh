#!/usr/bin/env bash
# =============================================================================
# モデル重みをローカルに取得する (新しくクローンした人向け)
#
# 重みは Git に入っていない。土台イメージ (Artifact Registry) の中に入っている
# ので、そこから取り出して django_prediction_API/prediction/models/ に置く。
#
# 使い方:
#   ./scripts/fetch-weights.sh          # Dockerfile が指しているバージョンを取得
#   ./scripts/fetch-weights.sh v2       # バージョンを明示して取得
#
# 前提: docker と gcloud (GCP プロジェクトへの読み取り権限) が使えること
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-global-sign-475613-j2}"
REGION="${REGION:-asia-northeast1}"
AR_REPO="${AR_REPO:-base}"
IMAGE_NAME="${IMAGE_NAME:-tick-runtime}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$REPO_ROOT/django_prediction_API/prediction/models"

# バージョン未指定なら Dockerfile の既定値から読み取る
VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(grep -oP 'ARG BASE_IMAGE=.*:\K[^ ]+' "$REPO_ROOT/Dockerfile" || true)"
  if [[ -z "$VERSION" ]]; then
    echo "ERROR: Dockerfile からバージョンを読めませんでした。引数で指定してください。" >&2
    exit 1
  fi
  echo "--> Dockerfile の指定バージョン: $VERSION"
fi

IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}:${VERSION}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker が必要です。" >&2
  echo "       docker が使えない場合は、重みを持っている人から直接受け取ってください。" >&2
  exit 1
fi

echo "--> $IMAGE から重みを取り出します"
gcloud auth configure-docker "${REGION}-docker.pkg.dev" --quiet
docker pull "$IMAGE"

mkdir -p "$MODELS_DIR"
CID="$(docker create "$IMAGE")"
trap 'docker rm -f "$CID" >/dev/null 2>&1 || true' EXIT

# /opt/models 配下をまとめて models/ にコピー
TMP="$(mktemp -d)"
docker cp "$CID:/opt/models/." "$TMP/"
cp -v "$TMP"/* "$MODELS_DIR/"
rm -rf "$TMP"

echo
echo "=============================================="
echo " 取得完了: $MODELS_DIR"
echo "=============================================="
ls -lh "$MODELS_DIR"
echo
echo "注意: これらは .gitignore 済みです。コミットされることはありません。"
