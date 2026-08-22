"""マダニ画像の検出 + 分類 API.

パイプライン:
    アップロード画像 → YOLO で個体を検出 → bbox で crop → 分類器 → ラベル

クラス定義はこのファイルにハードコードしない。学習時に書き出した
classes.json (重みと同じ場所に置く) を起動時に読む。フォルダを増やすと
ImageFolder のクラス番号がズレるため、番号は必ず学習側の出力を正本とする。

モデルは初回リクエスト時に遅延ロードする。import 時にロードしないので、
重みが無い環境 (CI など) でも Django のテストや manage.py check が通る。
"""

import base64
import io
import json
import logging
import os
import threading
from pathlib import Path

from PIL import Image, ImageDraw
from django.http import JsonResponse
from django.utils.decorators import method_decorator
from django.views.decorators.csrf import csrf_exempt
from rest_framework.views import APIView

# === パス設定 (Dockerfile が /opt/models を指す環境変数を注入する) ===
BASE_DIR = Path(__file__).resolve().parent
MODELS_DIR = BASE_DIR / "models"
YOLO_WEIGHTS = Path(os.environ.get("YOLO_WEIGHTS_PATH", MODELS_DIR / "best_tick_only.pt"))
CLS_WEIGHTS = Path(os.environ.get("CLS_WEIGHTS_PATH", MODELS_DIR / "resnet50_yolo_crop.pth"))
CLASSES_JSON = Path(os.environ.get("CLASSES_JSON_PATH", MODELS_DIR / "classes.json"))

# 分類器のアーキテクチャ (timm の名前)。重みを別アーキに差し替えたとき用。
CLS_ARCH = os.environ.get("CLS_ARCH", "resnet50d")

# この softmax スコアを下回ったら判定不能として返す
CLS_CONF_THRESHOLD = float(os.environ.get("CLS_CONF_THRESHOLD", "0.6"))

logger = logging.getLogger(__name__)


class _ModelBundle:
    """ロード済みのモデルとクラス定義をまとめて持つ."""

    def __init__(self, torch, yolo, classifier, transform, device, yolo_device, meta):
        self.torch = torch
        self.yolo = yolo
        self.classifier = classifier
        self.transform = transform
        self.device = device
        self.yolo_device = yolo_device
        self.classes = meta["classes"]
        self.species = meta.get("species", {})
        self.feeding = meta.get("feeding", {})
        self.feeding_label = meta.get("feeding_label", {})
        self.version = meta.get("version", "unknown")

    def display_label(self, class_name: str) -> str:
        """クラス名を利用者向けの表示文字列にする.

        例: "タカサゴキララマダニ_吸血" → "タカサゴキララマダニ（吸血）"
        """
        species = self.species.get(class_name, class_name)
        feeding = self.feeding.get(class_name)
        if feeding:
            return species + self.feeding_label.get(feeding, "")
        return species


_bundle = None
_bundle_lock = threading.Lock()


def _load_bundle() -> _ModelBundle:
    """モデルとクラス定義を遅延ロードする (プロセス内で1回だけ)."""
    global _bundle
    if _bundle is not None:
        return _bundle

    with _bundle_lock:
        if _bundle is not None:  # 別スレッドが先にロードし終えた場合
            return _bundle

        # 重い依存はここで初めて import する (import 時のロードを避けるため)
        import timm
        import torch
        import torchvision.transforms as transforms
        from ultralytics import YOLO

        with CLASSES_JSON.open(encoding="utf-8") as f:
            meta = json.load(f)

        classes = meta["classes"]
        missing = [c for c in classes if c not in meta.get("species", {})]
        if missing:
            # 種の対応が抜けていても display_label がクラス名を素通しするので
            # 致命的ではない。気付けるようにログだけ出す。
            logger.warning("classes.json: species mapping missing for %s", missing)

        device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
        yolo_device = "0" if torch.cuda.is_available() else "cpu"

        # num_classes が重みと食い違っていれば strict=True がここで例外を投げる。
        # 黙って誤ったラベルを返すより、起動時に落ちる方が安全。
        classifier = timm.create_model(CLS_ARCH, pretrained=False, num_classes=len(classes))
        state = torch.load(CLS_WEIGHTS, map_location=device)
        classifier.load_state_dict(state, strict=True)
        classifier = classifier.to(device).eval()

        yolo = YOLO(str(YOLO_WEIGHTS)).to(device)

        transform = transforms.Compose([
            transforms.Resize(256),
            transforms.CenterCrop(224),
            transforms.ToTensor(),
            transforms.Normalize(
                mean=[0.485, 0.456, 0.406],
                std=[0.229, 0.224, 0.225],
            ),
        ])

        _bundle = _ModelBundle(
            torch=torch,
            yolo=yolo,
            classifier=classifier,
            transform=transform,
            device=device,
            yolo_device=yolo_device,
            meta=meta,
        )
        logger.info(
            "models loaded: version=%s classes=%s device=%s",
            _bundle.version, classes, device,
        )

    return _bundle


def _encode_base64_image(pil_image: Image.Image) -> str:
    buffer = io.BytesIO()
    pil_image.save(buffer, format="JPEG")
    return base64.b64encode(buffer.getvalue()).decode("utf-8")


def _draw_boxes(image: Image.Image, boxes_with_labels):
    """検出・分類結果を画像に描き込む (デバッグ表示用)."""
    draw = ImageDraw.Draw(image)
    for item in boxes_with_labels:
        x1, y1, x2, y2 = item["bbox"]
        draw.rectangle([x1, y1, x2, y2], outline="red", width=3)
        draw.text((x1 + 2, y1 + 2), f"{item['label']} ({item['score']:.2f})", fill="red")
    return image


@method_decorator(csrf_exempt, name='dispatch')
class PredictView(APIView):
    def post(self, request):
        uploaded_file = request.FILES.get("file")
        if not uploaded_file:
            return JsonResponse(
                {"code": "no_file", "error": "No file supplied"},
                status=400,
            )

        try:
            pil_image = Image.open(uploaded_file).convert("RGB")
        except Exception:
            return JsonResponse(
                {"code": "invalid_image", "error": "File could not be read as an image"},
                status=400,
            )

        try:
            bundle = _load_bundle()
            torch = bundle.torch

            # === YOLO 検出 ===
            det_result = bundle.yolo.predict(
                pil_image,
                device=bundle.yolo_device,
                verbose=False,
            )[0]
            boxes = det_result.boxes

            if boxes is None or len(boxes) == 0:
                return JsonResponse(
                    {"code": "no_tick_detected", "error": "No tick detected in the image"},
                    status=422,
                )

            classifications = []
            for box in boxes:
                x1, y1, x2, y2 = box.xyxy[0].tolist()
                crop = pil_image.crop((x1, y1, x2, y2))
                tensor = bundle.transform(crop).unsqueeze(0).to(bundle.device)
                with torch.no_grad():
                    logits = bundle.classifier(tensor)
                    probs = torch.softmax(logits, dim=1)
                    score, idx = torch.max(probs, dim=1)

                class_name = bundle.classes[idx.item()]
                classifications.append({
                    "bbox": [float(x1), float(y1), float(x2), float(y2)],
                    "class_id": class_name,
                    "label": bundle.display_label(class_name),
                    "species": bundle.species.get(class_name, class_name),
                    "feeding_status": bundle.feeding.get(class_name),
                    "score": float(score.item()),
                })

            # 最もスコアの高い検出を最終結果として採用する
            top_cls = max(classifications, key=lambda c: c["score"])

            if top_cls["score"] < CLS_CONF_THRESHOLD:
                return JsonResponse(
                    {
                        "code": "low_confidence",
                        "error": "Classification confidence below threshold",
                        "threshold": CLS_CONF_THRESHOLD,
                        "raw_result": {"classifications": classifications},
                    },
                    status=422,
                    json_dumps_params={"ensure_ascii": False},
                )

            vis_image = _draw_boxes(pil_image.copy(), classifications)

            return JsonResponse({
                "code": "ok",
                # prediction は表示用の文字列。Flutter はこれをそのまま表示する。
                "prediction": top_cls["label"],
                # 以下は機械処理用の内訳。
                "class_id": top_cls["class_id"],
                "species": top_cls["species"],
                "feeding_status": top_cls["feeding_status"],
                "score": top_cls["score"],
                "model_version": bundle.version,
                "output_image": _encode_base64_image(vis_image),
                "raw_result": {"classifications": classifications},
            }, json_dumps_params={"ensure_ascii": False})

        except Exception:
            logger.exception("Prediction failed")
            return JsonResponse(
                {"code": "server_error", "error": "Internal server error"},
                status=500,
            )
