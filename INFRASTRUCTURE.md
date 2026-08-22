# Tick Prediction API — Infrastructure & Operations

ダニ画像分類APIの GCP 構成と運用ドキュメント。

---

## 1. システム概要

```
[Flutter App]
     │ HTTPS POST /prediction/API/
     ▼
┌─────────────────────────────────────────────┐
│ Cloud Run service: pred-api                 │
│ region: asia-northeast1                     │
│   ├─ Django + gunicorn (1 worker / 4 threads)│
│   ├─ IPRateLimitMiddleware (per-IP制限)     │
│   ├─ YOLO detection (best_tick_only.pt)     │
│   └─ ResNet50d classification               │
│           (resnet50_yolo_crop.pth)          │
└──────────────┬──────────────────────────────┘
               │ reads
               ▼
        [Secret Manager]
        django-secret-key

予算保護フロー:
┌─────────────────────┐
│ Budget ¥1,000/月    │
└──────────┬──────────┘
           │ 50% / 80% / 100% 達成時にイベント発火
           ▼
┌─────────────────────┐
│ Pub/Sub topic       │
│ budget-alerts       │
└──────────┬──────────┘
           │
           ▼
┌─────────────────────────────────────────────┐
│ Cloud Function: budget-killer (gen2)        │
│  - threshold < 1.0 → ログ出力のみ           │
│  - threshold >= 1.0 → pred-api の          │
│    allUsers invoker IAM を剥奪 → 全403     │
└─────────────────────────────────────────────┘
```

---

## 2. GCP プロジェクト基本情報

| 項目 | 値 |
|---|---|
| Project ID | `global-sign-475613-j2` |
| Project number | `612850974245` |
| Billing account | `014F9C-CDBAF3-38853B` |
| Currency | JPY |
| Default region | `asia-northeast1` |
| Owner account | `totchi1510@gmail.com` |

### 有効化済み API

| API | 用途 |
|---|---|
| `run.googleapis.com` | Cloud Run サービス |
| `cloudbuild.googleapis.com` | コンテナイメージのビルド |
| `artifactregistry.googleapis.com` | ビルド済みイメージ保管 |
| `secretmanager.googleapis.com` | SECRET_KEY 保管 |
| `billingbudgets.googleapis.com` | 予算アラート |
| `pubsub.googleapis.com` | 予算イベント topic |
| `cloudfunctions.googleapis.com` | budget-killer 関数 |
| `eventarc.googleapis.com` | Pub/Sub → Function トリガー |

---

## 3. Cloud Run サービス: pred-api

### エンドポイント

- メインURL: https://pred-api-612850974245.asia-northeast1.run.app
- 別形式URL (同じサービス): https://pred-api-t2g2pe5o5a-an.a.run.app
- 推論エンドポイント: `POST /prediction/API/`

### リソース設定

| 項目 | 値 | 意図 |
|---|---|---|
| Memory | 4 GiB | torch + 2モデルをロード |
| CPU | 2 vCPU | CPU推論を現実的速度で |
| Concurrency | 4 | gunicorn threads=4 に合わせる |
| Timeout | 300秒 | コールドスタート時のモデルロード対応 |
| Min instances | 0 | アイドル時無課金 |
| Max instances | **2** | コスト暴騰防止 (無料枠維持) |
| Ingress | all | 公開API |
| Auth | allow-unauthenticated | 認証なし |

### 環境変数 (`--set-env-vars`)

| 変数 | 値 |
|---|---|
| `DJANGO_DEBUG` | `false` |
| `DJANGO_ALLOWED_HOSTS` | `.run.app` (両URL形式をカバー) |
| `RATELIMIT_PER_MIN` | `30` |
| `RATELIMIT_PER_HOUR` | `200` |
| `CLS_CONF_THRESHOLD` | `0.6` (分類確信度の閾値。下回ると `low_confidence` を返す) |

### API レスポンス仕様

全レスポンスに機械判別用の `code` フィールドを含む:

| HTTP | code | 意味 |
|---|---|---|
| 200 | `ok` | 成功。`prediction` に分類ラベル |
| 400 | `no_file` | `file` フィールドなし |
| 400 | `invalid_image` | 画像として読めない |
| 422 | `no_tick_detected` | YOLO がマダニを検出できず |
| 422 | `low_confidence` | 最高スコアが `CLS_CONF_THRESHOLD` 未満。`raw_result.classifications` にスコア詳細 |
| 500 | `server_error` | 内部エラー (詳細はログのみ、レスポンスには含めない) |

200 のときのフィールド:

| フィールド | 例 | 用途 |
|---|---|---|
| `prediction` | `"タカサゴキララマダニ（吸血）"` | 表示用の文字列。Flutter はこれをそのまま表示する |
| `class_id` | `"タカサゴキララマダニ_吸血"` | 学習時のクラス名 (classes.json の `classes` の要素) |
| `species` | `"タカサゴキララマダニ"` | 種のみ |
| `feeding_status` | `"engorged"` / `"unfed"` / `null` | 吸血状態。判定対象外の種は `null` |
| `score` | `0.91` | 採用した分類の softmax スコア |
| `model_version` | `"4cls-2025-05-31"` | classes.json の `version`。どの重みで判定したかの追跡用 |
| `output_image` | base64 | bbox とラベルを描き込んだ確認用画像 |
| `raw_result.classifications` | 配列 | 検出された全個体の内訳 |

### クラス定義 (classes.json)

クラス名は `views.py` にハードコードしない。学習時に `ImageFolder.classes` から
書き出した `classes.json` を重みと同じ場所に置き、起動時に読む
(`CLASSES_JSON_PATH`、コンテナ内では `/opt/models/classes.json`)。

理由: `ImageFolder` はフォルダ名をソートしてクラス番号を振るため、学習データの
フォルダを1つ増やすと後続の番号が全部ズレる。推論側で番号を手管理していると、
更新を忘れたときに**エラーも出さずに全種を誤ったラベルで返す**。

`classes.json` の生成は [classification/export_classes_json.py](classification/export_classes_json.py) を使う。
`num_classes` が重みと食い違っていれば `load_state_dict(strict=True)` が
モデルロード時に例外を投げるため、黙って誤答することはない。

現在の内容 (4クラス):

| index | class | species | feeding_status |
|---|---|---|---|
| 0 | カクマダニ | カクマダニ | null |
| 1 | タカサゴキララマダニ | タカサゴキララマダニ | null |
| 2 | チマダニ | チマダニ | null |
| 3 | マダニ | マダニ | null |

### Secret 参照 (`--set-secrets`)

| 変数 | 参照先 |
|---|---|
| `DJANGO_SECRET_KEY` | Secret Manager: `django-secret-key:latest` |

### コンテナイメージ (2層構成)

イメージを「土台」と「アプリ」の2つに分けている。

```
[土台イメージ]  .../cloud-run-source-deploy/tick-runtime:v1
  python:3.11-slim
  + apt deps (libjpeg / libgl1 等)
  + pip install -r requirements.txt        ~2.9 GB
  + モデル重み + classes.json → /opt/models  ~130 MB
        ↑ 手元から手動でビルド (scripts/build-base-image.sh)
        │ 重みを含むため GitHub を経由させない
        │
        │ FROM
        ▼
[アプリイメージ]  .../cloud-run-source-deploy/pred-api:<commit-sha>   ← 同じリポジトリ
  + COPY django_prediction_API              ~1 MB
        ↑ GitHub Actions が main への merge ごとにビルド
```

**なぜ分けているか**

1. **重みを GitHub に置かなくて済む。** CI はコードしか見ないので、重みは土台
   イメージ側にだけ存在すればよい。`vit_ticks_fold1.pth` は 343MB あり、
   GitHub の 100MB/ファイル制限で push が拒否される。
2. **Artifact Registry の容量が激減する。** 実測したところ、`--source .` での
   ビルドは毎回 torch の層 (~2.9〜4.2GB) を作り直しており、5リビジョンで
   16.7GB のうち約15.8GB が重複だった。土台を固定すれば1ビルドで増えるのは
   コードの ~1MB だけになる。
3. 予算 ¥1,000/月 に対して、AR のストレージ課金 ($0.10/GB/月) が支配的だった。

**土台イメージとアプリイメージは同じリポジトリに置く。** 別リポジトリにすると、
アプリイメージの push 時に土台のレイヤがクロスリポジトリ mount され、
両方のリポジトリのサイズに計上される (実測で 3.1GB が二重計上された)。
同一リポジトリなら重複はゼロになる。

実測したレイヤの内訳 (アプリイメージ push 時):

```
Pushed              : 1   ← コードの層のみ
Mounted from ...    : 9   ← 土台の層 (別リポジトリだったため mount)
Layer already exists: 10
```

**土台イメージの作り直しが必要なケース**

| 変更したもの | 土台の作り直し |
|---|---|
| Python のコード | 不要 (CI が自動で反映) |
| Dockerfile | 不要 |
| `requirements.txt` | **必要** |
| モデルの重み / classes.json | **必要** |

### Artifact Registry の保持ポリシー

[scripts/ar-cleanup-policy.json](scripts/ar-cleanup-policy.json) を
`scripts/apply-ar-cleanup.sh` で適用する。Keep は Delete より優先される。

| ルール | 対象 | 動作 |
|---|---|---|
| `keep-base-image` | `tick-runtime` | 常に保持（消すと以降のビルドが `FROM` で失敗する） |
| `keep-recent-app-images` | `pred-api` 最新5世代 | 保持 |
| `delete-untagged-after-7d` | タグ無し 7日超 | 削除 |
| `delete-old-after-30d` | 上記で保持されない30日超 | 削除 |

最後のルールが必要な理由: `deploy.yml` は毎ビルドで `:<コミットSHA>` を付けるため、
アプリイメージは永久にタグ付きのまま残る。「タグ無しを削除」だけでは何も掃除されない。

`requirements.txt` の変更は PR 上で警告が出る (`.github/workflows/ci.yml` の
`base-image-guard`)。作り直しを忘れた場合、ビルドは成功するがコンテナ起動時に
`ModuleNotFoundError` になる。Cloud Run は起動に失敗したリビジョンへ
トラフィックを流さないため、本番は旧リビジョンで動き続ける。

### Dockerfile

| ファイル | 誰がビルドするか | 中身 |
|---|---|---|
| [Dockerfile.base](Dockerfile.base) | 手元 (`scripts/build-base-image.sh`) | 依存 + 重み |
| [Dockerfile](Dockerfile) | GitHub Actions | 土台 + アプリコード |

起動コマンドは `gunicorn ... --workers 1 --threads 4 --timeout 120` on `$PORT`。
worker を 1 に固定しているのは、複数だと大きなモデルがメモリに多重ロードされるため。

重みのパスはアプリイメージの `ENV` で土台イメージ側 (`/opt/models`) を指す:

```
YOLO_WEIGHTS_PATH=/opt/models/best_tick_only.pt
CLS_WEIGHTS_PATH=/opt/models/resnet50_yolo_crop.pth
CLASSES_JSON_PATH=/opt/models/classes.json
```

モデルは import 時ではなく**初回リクエスト時に遅延ロード**する。重みが無い環境
(CI) でも `manage.py check` とテストが通るようにするため。

---

## 4. Secret Manager

| Secret | 用途 | 権限を付与した SA |
|---|---|---|
| `django-secret-key` | Django の cookie/CSRF/token 署名鍵 | `612850974245-compute@developer.gserviceaccount.com` (`roles/secretmanager.secretAccessor`) |

### 鍵の更新 (ローテーション)

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(50), end='')" \
  | gcloud secrets versions add django-secret-key --data-file=-
```

サービス再起動時に最新版を取得します (再デプロイなしで反映させたい場合は `gcloud run services update pred-api --region=asia-northeast1` で空デプロイ)。

---

## 5. アプリケーション層のセキュリティ

### IP ベースのレート制限

実装: [django_prediction_API/prediction/middleware.py](django_prediction_API/prediction/middleware.py)

- `/prediction/` パスのみ対象 (`/admin/` などは除外)
- IP ごとに「直近1分」「直近1時間」のリクエスト数をカウント
- 上限超過時は HTTP 429 + JSON エラー
- 状態はコンテナのメモリ内 (LRU 1万IP上限)
- インスタンスごとに独立した状態なので、`max-instances=2` の場合は実効上限が 2倍

### 設定値 (env で調整可)

| Env | デフォルト | 現在の運用値 |
|---|---|---|
| `RATELIMIT_PER_MIN` | 30 | 30 |
| `RATELIMIT_PER_HOUR` | 200 | 200 |
| `RATELIMIT_LRU_SIZE` | 10000 | 10000 |

---

## 6. 予算管理と自動停止

### 6.1 Budget

| 項目 | 値 |
|---|---|
| 名前 | `tick-prediction-1000jpy` |
| ID | `c6548de0-479d-4796-a804-b696e53a4faa` |
| 月額 | ¥1,000 |
| 対象 | プロジェクト `global-sign-475613-j2` のみ |
| 閾値 | 50% / 80% / 100% |
| メール通知 | Billing 管理者宛 |
| Pub/Sub | `projects/global-sign-475613-j2/topics/budget-alerts` |

### 6.2 Pub/Sub topic

| 項目 | 値 |
|---|---|
| Topic 名 | `budget-alerts` |
| Publisher | Cloud Billing (自動) |
| Subscriber | Eventarc trigger (budget-killer 関数経由) |

メッセージ形式 (Google が定義):

```json
{
  "budgetDisplayName": "tick-prediction-1000jpy",
  "alertThresholdExceeded": 1.0,
  "costAmount": 1000,
  "budgetAmount": 1000,
  "currencyCode": "JPY",
  "budgetAmountType": "SPECIFIED_AMOUNT"
}
```

### 6.3 Cloud Function: budget-killer

| 項目 | 値 |
|---|---|
| ソース | [budget_killer/main.py](budget_killer/main.py) |
| Generation | gen2 |
| Runtime | python311 |
| Region | asia-northeast1 |
| Memory | 256 MiB |
| Timeout | 120秒 |
| Trigger | Pub/Sub topic `budget-alerts` |
| Service Account | `612850974245-compute@developer.gserviceaccount.com` |
| 必要IAMロール | `roles/run.admin` (IAM policy書き換えのため) |

### Env vars

| 変数 | 値 | 意味 |
|---|---|---|
| `PROJECT_ID` | global-sign-475613-j2 | 対象プロジェクト |
| `REGION` | asia-northeast1 | 対象リージョン |
| `SERVICE_NAME` | pred-api | 停止対象 Cloud Run サービス |
| `STOP_THRESHOLD` | 1.0 | この閾値以上で停止実行 |

### 停止方法 (なぜ IAM 剥奪なのか)

最初は v2 API の `max_instance_count=0` を試したが、Cloud Run の v2 API では「0=未指定=デフォルト」と解釈されて意図と逆方向に動いた (デフォルト値の10へ上書き)。

代わりに **`allUsers` から `roles/run.invoker` を剥奪**する方式に変更。これで:
- 外部からのリクエストは即 403
- Cloud Run はインスタンスを起動しない (IAMチェックがインスタンス起動より前)
- 結果として compute 課金がゼロ
- サービス本体は残るので、復旧は IAM 1コマンドで完了

---

## 7. 運用手順

### 7.1 通常のコードデプロイ (CI/CD)

コードの変更は GitHub 経由で自動デプロイされる。手元から `gcloud run deploy` を
叩く必要はない。

```
ブランチを push → PR → CI (テスト) → main に merge
                                        │
                                        ▼
                          GitHub Actions (.github/workflows/deploy.yml)
                            1. WIF で GCP に認証 (キーレス)
                            2. docker build (土台イメージ + コード)
                            3. コンテナのスモークテスト
                            4. Artifact Registry に push
                            5. gcloud run deploy pred-api
                                        │
                                        ▼
                          Cloud Run が新リビジョン → トラフィック切替 (2〜4分)
```

- リポジトリ: https://github.com/totchi1510/TickDetection-1
- **push した人は GCP のアカウントを必要としない。** 認証するのはワークフロー本体。
- fork からの PR では OIDC トークンが発行されないため、merge されるまで本番には
  何も起きない。
- デプロイは `--image` のみを指定する。環境変数・シークレット・メモリ等の
  既存設定はそのまま引き継がれる (全項目を並べると書き間違い1つで本番設定が
  リセットされるため、あえて指定しない)。設定の正本はこのドキュメント。

**認証設定 (1回だけ)**

```bash
./scripts/setup-wif.sh
```

Workload Identity プール + OIDC プロバイダ + CI 用サービスアカウントを作る。
サービスアカウントの JSON キーは発行しない。スクリプトが出力する 2 つの値を
GitHub の Settings > Secrets and variables > Actions > Variables に登録する:

| 変数名 | 内容 |
|---|---|
| `WIF_PROVIDER` | `projects/612850974245/locations/global/workloadIdentityPools/github-pool/providers/github-provider` |
| `WIF_SERVICE_ACCOUNT` | `github-actions-deployer@global-sign-475613-j2.iam.gserviceaccount.com` |

CI 用サービスアカウントの権限 (最小限):

| ロール | スコープ | 用途 |
|---|---|---|
| `roles/artifactregistry.writer` | プロジェクト | イメージの push |
| `roles/run.developer` | プロジェクト | Cloud Run のデプロイ |
| `roles/iam.serviceAccountUser` | ランタイム SA のみ | リビジョンに SA を割り当てる |

**手元から緊急デプロイする場合** (CI が使えないとき)

```bash
cd /home/yuto/dsclub/tick/cloudbuild-source
IMAGE=asia-northeast1-docker.pkg.dev/global-sign-475613-j2/cloud-run-source-deploy/pred-api:manual-$(date +%Y%m%d-%H%M)
docker build -t "$IMAGE" .
docker push "$IMAGE"
gcloud run deploy pred-api --image "$IMAGE" --region asia-northeast1
```

### 7.1b 土台イメージの更新 (重み / 依存を変えたとき)

重みは Git に入っていないため、CI では更新できない。手元から実行する。

```bash
cd /home/yuto/dsclub/tick/cloudbuild-source

# 重みが手元に無い場合はまず取得
./scripts/fetch-weights.sh

# 新しいバージョンでビルド (v1 が既にある場合は v2)
./scripts/build-base-image.sh v2

# 5クラスモデルに差し替える場合
./scripts/build-base-image.sh v2 --cls-weights resnet50_yolo_crop_5cls.pth
```

push 後に**必ず2箇所のタグを更新してコミットする**:

| ファイル | 箇所 |
|---|---|
| [Dockerfile](Dockerfile) | `ARG BASE_IMAGE=...:v1` |
| [.github/workflows/deploy.yml](.github/workflows/deploy.yml) | `env.BASE_IMAGE` |

同じタグの上書きはスクリプトが拒否する (どの重みでデプロイされたかを
追えなくなるため)。

### 7.2 環境変数だけ変える (コード変更なし)

```bash
gcloud run services update pred-api --region=asia-northeast1 \
  --update-env-vars "RATELIMIT_PER_MIN=60"
```

### 7.3 ロールバック (前リビジョンに戻す)

```bash
# リビジョン一覧
gcloud run revisions list --service=pred-api --region=asia-northeast1

# 100%トラフィックを指定リビジョンに戻す
gcloud run services update-traffic pred-api \
  --region=asia-northeast1 \
  --to-revisions=pred-api-NNNNN-xxx=100
```

### 7.4 予算上限到達後の復旧

100% 到達時に Function が IAM を剥奪してます。再開するには:

```bash
gcloud run services add-iam-policy-binding pred-api \
  --region=asia-northeast1 \
  --member=allUsers \
  --role=roles/run.invoker
```

> 翌月になっても自動復旧はしません (意図的な仕様)。再発防止のため明示的な復旧操作を要求しています。

### 7.5 budget-killer 関数の更新

```bash
cd /home/yuto/dsclub/tick/cloudbuild-source/budget_killer

gcloud functions deploy budget-killer \
  --gen2 --runtime=python311 \
  --region=asia-northeast1 \
  --source=. \
  --entry-point=handle_budget_alert \
  --trigger-topic=budget-alerts \
  --memory=256Mi --timeout=120s \
  --set-env-vars="PROJECT_ID=global-sign-475613-j2,REGION=asia-northeast1,SERVICE_NAME=pred-api,STOP_THRESHOLD=1.0"
```

### 7.6 ログ確認

```bash
# pred-api のログ
gcloud run services logs read pred-api --region=asia-northeast1 --limit=50

# budget-killer のログ
gcloud functions logs read budget-killer --region=asia-northeast1 --limit=20

# レート制限のヒット数 (warning 以上)
gcloud logging read 'resource.type="cloud_run_revision" AND resource.labels.service_name="pred-api" AND severity>=WARNING' --limit=30
```

### 7.7 コスト確認

- コンソール: https://console.cloud.google.com/billing/reports?project=global-sign-475613-j2
- 無料枠の消費状況: Reports → Credits 列
- Cloud Run のメトリクス: https://console.cloud.google.com/run/detail/asia-northeast1/pred-api/metrics

---

## 8. セキュリティ修正の履歴

旧 pred-api (2026-01-06 デプロイ) からの改善点:

| 項目 | Before | After | 理由 |
|---|---|---|---|
| DEBUG mode | true | false | エラー時にスタックトレース・設定情報が漏れるのを防ぐ |
| SECRET_KEY | 平文 env var | Secret Manager 参照 | コンソール閲覧者から秘匿、audit log 化 |
| ALLOWED_HOSTS | 1つのURLのみ | `.run.app` | Host header 攻撃対策。両URL形式に対応 |
| Memory | 2Gi | 4Gi | 新モデル + YOLO で安定動作 |
| Concurrency | 80 | 4 | gunicorn threads=4 と整合、内部キュー堆積を防ぐ |
| Max instances | 20 | 2 | コスト暴騰の上限を設定 |
| レート制限 | なし | IP単位 30/分・200/時 | DoS / 課金攻撃対策 |
| 予算アラート | なし | ¥1,000/月 + 自動停止 | 想定外請求を物理的にカット |

---

## 9. 未対応・将来の課題

| 項目 | 説明 | 優先度 |
|---|---|---|
| 認証 (API key/IAP) | 現状URL知ってる人なら誰でも叩ける | 利用者増えたら |
| HSTS | HTTPSは強制だが HSTS ヘッダー未設定 | 低 |
| CORS_ALLOWED_ORIGINS | 現状空 (web browser からのアクセス不可) | Web UI 追加するなら |
| レート制限の永続化 | インスタンス間で状態共有してない | 高負荷になったら Redis 等 |
| 監査ログのフィルタ | Cloud Run の access log にPII含む可能性 | 高 |
| カスタムドメイン | `run.app` のままでも問題ないがブランディング次第 | 低 |

---

## 10. ファイル参照

| パス | 内容 |
|---|---|
| [Dockerfile](Dockerfile) | コンテナ定義 |
| [requirements.txt](requirements.txt) | Python 依存 |
| [.gcloudignore](.gcloudignore) | Cloud Build アップロード除外 |
| [django_prediction_API/django_prediction_API/settings.py](django_prediction_API/django_prediction_API/settings.py) | Django 設定 |
| [django_prediction_API/prediction/views.py](django_prediction_API/prediction/views.py) | 推論API (YOLO + ResNet) |
| [django_prediction_API/prediction/middleware.py](django_prediction_API/prediction/middleware.py) | レート制限 middleware |
| [django_prediction_API/prediction/models/best_tick_only.pt](django_prediction_API/prediction/models/best_tick_only.pt) | YOLO 重み |
| [django_prediction_API/prediction/models/resnet50_yolo_crop.pth](django_prediction_API/prediction/models/resnet50_yolo_crop.pth) | 分類器重み |
| [budget_killer/main.py](budget_killer/main.py) | 予算上限到達時の自動停止 Function |
| [budget_killer/requirements.txt](budget_killer/requirements.txt) | Function の依存 |

---

## 11. 全体クリーンアップ (もし停止する場合)

```bash
# Cloud Function 削除
gcloud functions delete budget-killer --region=asia-northeast1 --quiet

# Pub/Sub topic 削除
gcloud pubsub topics delete budget-alerts --quiet

# Budget 削除
gcloud billing budgets delete c6548de0-479d-4796-a804-b696e53a4faa \
  --billing-account=014F9C-CDBAF3-38853B --quiet

# Cloud Run service 削除
gcloud run services delete pred-api --region=asia-northeast1 --quiet

# Secret 削除
gcloud secrets delete django-secret-key --quiet

# Artifact Registry イメージ削除 (ストレージ料金節約)
gcloud artifacts repositories delete cloud-run-source-deploy \
  --location=asia-northeast1 --quiet
```
