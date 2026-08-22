#!/usr/bin/env bash
# =============================================================================
# 土台イメージ (Python + torch + モデル重み) をビルドして Artifact Registry に push
#
# CI ではなく手元から実行する。重みを含むため GitHub を経由させない。
#
# 使い方:
#   ./scripts/build-base-image.sh v1
#   ./scripts/build-base-image.sh v2 --cls-weights resnet50_yolo_crop_5cls.pth
#
# 実行が必要になるのは次の2ケースだけ:
#   1. requirements.txt を変更した
#   2. モデルの重み / classes.json を差し替えた
#
# push 後は Dockerfile の ARG BASE_IMAGE の既定値も同じタグに更新すること。
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-global-sign-475613-j2}"
REGION="${REGION:-asia-northeast1}"
AR_REPO="${AR_REPO:-cloud-run-source-deploy}"
IMAGE_NAME="${IMAGE_NAME:-tick-runtime}"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: $0 <version>   (例: $0 v1)" >&2
  exit 1
fi
shift || true

# 土台イメージに入れる重み。5クラス版に差し替えるときは --cls-weights で指定する。
YOLO_WEIGHTS_FILE="best_tick_only.pt"
CLS_WEIGHTS_FILE="resnet50_yolo_crop.pth"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yolo-weights) YOLO_WEIGHTS_FILE="$2"; shift 2 ;;
    --cls-weights)  CLS_WEIGHTS_FILE="$2";  shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS_DIR="$REPO_ROOT/django_prediction_API/prediction/models"
IMAGE="${REGION}-docker.pkg.dev/${PROJECT_ID}/${AR_REPO}/${IMAGE_NAME}:${VERSION}"

echo "=============================================="
echo " 土台イメージのビルド"
echo "=============================================="
echo "  image        : $IMAGE"
echo "  YOLO weights : $YOLO_WEIGHTS_FILE"
echo "  CLS weights  : $CLS_WEIGHTS_FILE"
echo

# --- 重みの存在確認 -----------------------------------------------------------
for f in "$YOLO_WEIGHTS_FILE" "$CLS_WEIGHTS_FILE" "classes.json"; do
  if [[ ! -f "$MODELS_DIR/$f" ]]; then
    echo "ERROR: $MODELS_DIR/$f が見つかりません" >&2
    echo "       重みは Git に入っていません。scripts/fetch-weights.sh で取得してください。" >&2
    exit 1
  fi
done

# --- classes.json と重みの整合を軽く検査 --------------------------------------
python3 - "$MODELS_DIR/classes.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as f:
    meta = json.load(f)
classes = meta["classes"]
assert len(classes) == len(set(classes)), "classes に重複がある"
missing = [c for c in classes if c not in meta.get("species", {})]
assert not missing, f"species の対応が無いクラス: {missing}"
print(f"  classes.json : {len(classes)} クラス (version={meta.get('version')})")
print(f"                 {classes}")
PY
echo

# --- AR リポジトリが無ければ作る ---------------------------------------------
if ! gcloud artifacts repositories describe "$AR_REPO" \
      --location="$REGION" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "--> Artifact Registry リポジトリ '$AR_REPO' を作成します"
  gcloud artifacts repositories create "$AR_REPO" \
    --repository-format=docker \
    --location="$REGION" \
    --project="$PROJECT_ID" \
    --description="ベースイメージ (依存 + モデル重み)"
fi

# --- 同じタグが既にあるなら止める (上書きすると再現性が壊れる) ----------------
if gcloud artifacts docker images describe "$IMAGE" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "ERROR: $IMAGE は既に存在します。" >&2
  echo "       タグを上書きすると『どの重みでデプロイされたか』が追えなくなります。" >&2
  echo "       新しいバージョン (例: 次の連番) を指定してください。" >&2
  exit 1
fi

# --- ステージングディレクトリを作ってビルド ----------------------------------
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/weights"
cp "$REPO_ROOT/requirements.txt"  "$STAGE/requirements.txt"
cp "$REPO_ROOT/Dockerfile.base"   "$STAGE/Dockerfile"
cp "$MODELS_DIR/$YOLO_WEIGHTS_FILE" "$STAGE/weights/"
cp "$MODELS_DIR/$CLS_WEIGHTS_FILE"  "$STAGE/weights/"
cp "$MODELS_DIR/classes.json"       "$STAGE/weights/"

# gcloud builds submit は .gcloudignore が無いと .gitignore を代わりに使うことがある。
# 重みは .gitignore で除外されているため、明示的に空の .gcloudignore を置いて
# ステージング内の全ファイルを確実にアップロードさせる。
: > "$STAGE/.gcloudignore"

echo "--> Cloud Build に送信します (重み $(du -sh "$STAGE/weights" | cut -f1) を含む)"
gcloud builds submit "$STAGE" \
  --tag "$IMAGE" \
  --region "$REGION" \
  --project "$PROJECT_ID"

# --- 参照側のタグと重みファイル名を自動で書き換える ---------------------------
# 手で2箇所更新する運用は忘れる。忘れるとビルドは通るのに起動時に落ちるため、
# スクリプト側で書き換えてしまう (コミットは人間が確認してから行う)。
DOCKERFILE="$REPO_ROOT/Dockerfile"
DEPLOY_YML="$REPO_ROOT/.github/workflows/deploy.yml"

echo
echo "--> 参照側を書き換えます"
python3 - "$DOCKERFILE" "$DEPLOY_YML" "$IMAGE" "$YOLO_WEIGHTS_FILE" "$CLS_WEIGHTS_FILE" <<'PYPATCH'
import re
import sys

dockerfile, deploy_yml, image, yolo_file, cls_file = sys.argv[1:6]
changed = []

with open(dockerfile, encoding="utf-8") as f:
    s = f.read()
before = s
s = re.sub(r"^ARG BASE_IMAGE=.*$", f"ARG BASE_IMAGE={image}", s, count=1, flags=re.M)
s = re.sub(r"^(ENV YOLO_WEIGHTS_PATH=)\S+", rf"\g<1>/opt/models/{yolo_file}", s, count=1, flags=re.M)
s = re.sub(r"^(    CLS_WEIGHTS_PATH=)\S+", rf"\g<1>/opt/models/{cls_file}", s, count=1, flags=re.M)
if s != before:
    with open(dockerfile, "w", encoding="utf-8") as f:
        f.write(s)
    changed.append("Dockerfile")

with open(deploy_yml, encoding="utf-8") as f:
    s = f.read()
before = s
s = re.sub(r"^(  BASE_IMAGE: ).*$", rf"\g<1>{image}", s, count=1, flags=re.M)
if s != before:
    with open(deploy_yml, "w", encoding="utf-8") as f:
        f.write(s)
    changed.append(".github/workflows/deploy.yml")

print("    書き換えたファイル: " + (", ".join(changed) if changed else "なし (既に一致)"))
PYPATCH

echo
echo "=============================================="
echo " 完了: $IMAGE"
echo "=============================================="
echo "この土台イメージに入っている重み:"
echo "  /opt/models/${YOLO_WEIGHTS_FILE}"
echo "  /opt/models/${CLS_WEIGHTS_FILE}"
echo "  /opt/models/classes.json"
echo
echo "次にやること:"
echo "  1. git diff で Dockerfile と deploy.yml の書き換え内容を確認"
echo "  2. コミットして main に merge → CI が新しい土台でアプリをビルドする"
