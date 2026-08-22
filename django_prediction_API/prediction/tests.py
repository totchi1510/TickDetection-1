"""CI 用のスモークテスト.

ここに置くテストは torch もモデル重みも必要としない。views.py がモデルを
遅延ロードするようになっているので、重みが無い CI 環境でも実行できる。

モデルを実際に動かす確認は、デプロイワークフローがビルドしたコンテナに対して
行う (.github/workflows/deploy.yml の smoke test ステップ)。
"""

import io
import json
import os
from pathlib import Path

from django.test import SimpleTestCase
from django.urls import reverse


class UrlRoutingTests(SimpleTestCase):
    def test_predict_endpoint_is_routed(self):
        self.assertEqual(reverse("prediction:prediction"), "/prediction/API/")


class PredictViewValidationTests(SimpleTestCase):
    """モデルに到達する前の入力バリデーションを確認する.

    どのケースもモデルのロードには進まないので、重みが無くても通る。
    """

    url = "/prediction/API/"

    def test_missing_file_returns_400(self):
        res = self.client.post(self.url, {})
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json()["code"], "no_file")

    def test_non_image_file_returns_400(self):
        broken = io.BytesIO(b"this is not an image")
        broken.name = "broken.jpg"
        res = self.client.post(self.url, {"file": broken})
        self.assertEqual(res.status_code, 400)
        self.assertEqual(res.json()["code"], "invalid_image")

    def test_get_is_not_allowed(self):
        res = self.client.get(self.url)
        self.assertEqual(res.status_code, 405)


class ClassesJsonTests(SimpleTestCase):
    """classes.json があれば整合性を検査する.

    CI には重みも classes.json も無いのでスキップされる。ローカルや
    コンテナ内では実際に検査が走る。
    """

    def setUp(self):
        from prediction import views

        self.path = views.CLASSES_JSON
        if not Path(self.path).exists():
            self.skipTest(f"classes.json not present ({self.path})")
        with open(self.path, encoding="utf-8") as f:
            self.meta = json.load(f)

    def test_classes_is_non_empty_unique_list(self):
        classes = self.meta["classes"]
        self.assertIsInstance(classes, list)
        self.assertGreater(len(classes), 0)
        self.assertEqual(len(classes), len(set(classes)), "クラス名が重複している")

    def test_species_covers_every_class(self):
        classes = self.meta["classes"]
        species = self.meta.get("species", {})
        missing = [c for c in classes if c not in species]
        self.assertEqual(missing, [], f"species の対応が無いクラス: {missing}")

    def test_feeding_keys_are_known_classes(self):
        classes = set(self.meta["classes"])
        unknown = [c for c in self.meta.get("feeding", {}) if c not in classes]
        self.assertEqual(unknown, [], f"classes に無いクラスが feeding にある: {unknown}")

    def test_feeding_values_have_labels(self):
        labels = self.meta.get("feeding_label", {})
        for cls, status in self.meta.get("feeding", {}).items():
            self.assertIn(status, labels, f"{cls} の状態 '{status}' に表示ラベルが無い")

    def test_display_label_roundtrip(self):
        """classes.json の内容で表示ラベルが組み立てられることを確認する."""
        from prediction.views import _ModelBundle

        bundle = _ModelBundle.__new__(_ModelBundle)
        bundle.classes = self.meta["classes"]
        bundle.species = self.meta.get("species", {})
        bundle.feeding = self.meta.get("feeding", {})
        bundle.feeding_label = self.meta.get("feeding_label", {})

        for cls in bundle.classes:
            label = bundle.display_label(cls)
            self.assertTrue(label, f"{cls} の表示ラベルが空")
            if cls in bundle.feeding:
                # 吸血状態を持つクラスは、表示ラベルに接尾辞が付くこと
                self.assertNotEqual(label, bundle.species[cls])


class SettingsTests(SimpleTestCase):
    def test_debug_is_off_when_env_says_so(self):
        from django.conf import settings

        if os.environ.get("DJANGO_DEBUG", "").lower() in ("false", "0", "no"):
            self.assertFalse(settings.DEBUG)

    def test_secret_key_is_not_hardcoded_placeholder(self):
        from django.conf import settings

        self.assertNotIn("django-insecure", settings.SECRET_KEY)
