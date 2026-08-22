# =============================================================================
# アプリイメージ (CI がビルドするのはこちら)
#
# 土台イメージ (Python + torch + モデル重み) の上に、アプリコードだけを載せる。
# 1回のビルドで増える層は数MBのコードだけなので、
#   - CI は重みを一切必要としない (GitHub に重みが無くてよい)
#   - Artifact Registry の容量が 1ビルドあたり ~3.4GB → ~1MB になる
#
# 土台イメージの作り方: scripts/build-base-image.sh
# =============================================================================

# 土台イメージはタグで固定する。latest は使わない。
# 重み・依存を更新したら v2, v3 と上げて、この既定値も更新する。
ARG BASE_IMAGE=asia-northeast1-docker.pkg.dev/global-sign-475613-j2/cloud-run-source-deploy/tick-runtime:v1
FROM ${BASE_IMAGE}

# アプリコード。ここだけが毎ビルドで変わる層。
COPY django_prediction_API /app/django_prediction_API

# 重みは土台イメージの /opt/models に入っている。
# views.py はこの3つの環境変数でパスを受け取る。
ENV YOLO_WEIGHTS_PATH=/opt/models/best_tick_only.pt \
    CLS_WEIGHTS_PATH=/opt/models/resnet50_yolo_crop.pth \
    CLASSES_JSON_PATH=/opt/models/classes.json

EXPOSE 8080

# $PORT は Cloud Run が注入する。ローカル docker run 用に 8080 をフォールバック。
# モデルが大きいので worker は 1 に固定 (複数だとメモリに重みが多重ロードされる)。
CMD ["sh", "-c", "gunicorn --chdir /app/django_prediction_API django_prediction_API.wsgi:application --bind 0.0.0.0:${PORT:-8080} --workers 1 --threads 4 --timeout 120"]
