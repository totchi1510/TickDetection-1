#!/usr/bin/env bash
# =============================================================================
# GitHub Actions から GCP にキーレスで認証させる設定 (Workload Identity 連携)
#
# 1回だけ実行する。サービスアカウントの JSON キーは作らない。
# キーを GitHub Secrets に置く方式は、漏れた時点でプロジェクト全権を渡すことに
# なるため使わない。
#
# 使い方:
#   ./scripts/setup-wif.sh
#
# 実行後に表示される2つの値を GitHub の
#   Settings > Secrets and variables > Actions > Variables
# に登録する:
#   WIF_PROVIDER
#   WIF_SERVICE_ACCOUNT
# =============================================================================
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-global-sign-475613-j2}"
REGION="${REGION:-asia-northeast1}"
GITHUB_REPO="${GITHUB_REPO:-totchi1510/TickDetection-1}"

POOL="${POOL:-github-pool}"
PROVIDER="${PROVIDER:-github-provider}"
CI_SA_NAME="${CI_SA_NAME:-github-actions-deployer}"

# Cloud Run のリビジョンが実行時に使うサービスアカウント。
# CI がデプロイするには、この SA を「使う」権限が必要になる。
RUNTIME_SA="${RUNTIME_SA:-612850974245-compute@developer.gserviceaccount.com}"

PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
CI_SA="${CI_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

echo "=============================================="
echo " Workload Identity 連携のセットアップ"
echo "=============================================="
echo "  project      : $PROJECT_ID ($PROJECT_NUMBER)"
echo "  GitHub repo  : $GITHUB_REPO"
echo "  CI SA        : $CI_SA"
echo "  runtime SA   : $RUNTIME_SA"
echo

# --- 必要な API ---------------------------------------------------------------
echo "--> 必要な API を有効化"
gcloud services enable \
  iamcredentials.googleapis.com \
  sts.googleapis.com \
  artifactregistry.googleapis.com \
  run.googleapis.com \
  --project="$PROJECT_ID"

# --- CI 用サービスアカウント ---------------------------------------------------
if ! gcloud iam service-accounts describe "$CI_SA" --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "--> CI 用サービスアカウントを作成"
  gcloud iam service-accounts create "$CI_SA_NAME" \
    --display-name="GitHub Actions deployer" \
    --description="GitHub Actions から Cloud Run にデプロイするための SA (キーは発行しない)" \
    --project="$PROJECT_ID"

  # 作成直後は IAM に伝播しておらず、すぐ add-iam-policy-binding すると
  # "Service account does not exist" で失敗する。見えるようになるまで待つ。
  echo -n "    IAM への伝播を待機"
  for _ in $(seq 1 30); do
    if gcloud iam service-accounts describe "$CI_SA" --project="$PROJECT_ID" >/dev/null 2>&1; then
      echo " OK"
      break
    fi
    echo -n "."
    sleep 2
  done
else
  echo "--> CI 用サービスアカウントは既にあります"
fi

# 伝播は describe が通っても IAM ポリシー側に届くまで更に遅れることがあるため、
# 権限付与は失敗しても数回やり直す。
retry_iam() {
  local desc="$1"; shift
  local i
  for i in $(seq 1 6); do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    if [[ $i -lt 6 ]]; then
      echo "    ($desc: 失敗 ${i}/6、10秒後に再試行)"
      sleep 10
    fi
  done
  echo "ERROR: $desc に失敗しました。もう一度スクリプトを実行してください" >&2
  echo "       (このスクリプトは何度実行しても安全です)" >&2
  return 1
}

# --- CI SA に与える権限 (最小限) ----------------------------------------------
# artifactregistry.writer  : イメージの push
# run.developer            : Cloud Run のリビジョン作成・デプロイ
echo "--> CI SA にプロジェクトレベルの権限を付与"
for ROLE in roles/artifactregistry.writer roles/run.developer; do
  retry_iam "$ROLE の付与" \
    gcloud projects add-iam-policy-binding "$PROJECT_ID" \
      --member="serviceAccount:${CI_SA}" \
      --role="$ROLE" \
      --condition=None \
      --quiet
  echo "    $ROLE"
done

# iam.serviceAccountUser は「ランタイム SA に対してだけ」与える。
# プロジェクト全体に与えると他の SA も使い回せてしまうため。
echo "--> ランタイム SA を使う権限を付与 (この SA に限定)"
retry_iam "ランタイム SA の利用権限付与" \
  gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
    --member="serviceAccount:${CI_SA}" \
    --role="roles/iam.serviceAccountUser" \
    --project="$PROJECT_ID" \
    --quiet

# --- Workload Identity プール --------------------------------------------------
if ! gcloud iam workload-identity-pools describe "$POOL" \
      --location=global --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "--> Workload Identity プールを作成"
  gcloud iam workload-identity-pools create "$POOL" \
    --location=global \
    --display-name="GitHub Actions" \
    --project="$PROJECT_ID"
else
  echo "--> プールは既にあります"
fi

# --- OIDC プロバイダ -----------------------------------------------------------
# attribute-condition が肝。これが無いと「GitHub 上の任意のリポジトリ」が
# このプロバイダ経由でトークンを要求できてしまう。必ずリポジトリを固定する。
if ! gcloud iam workload-identity-pools providers describe "$PROVIDER" \
      --location=global --workload-identity-pool="$POOL" \
      --project="$PROJECT_ID" >/dev/null 2>&1; then
  echo "--> OIDC プロバイダを作成 (${GITHUB_REPO} に限定)"
  gcloud iam workload-identity-pools providers create-oidc "$PROVIDER" \
    --location=global \
    --workload-identity-pool="$POOL" \
    --display-name="GitHub OIDC" \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref,attribute.repository_owner=assertion.repository_owner" \
    --attribute-condition="assertion.repository == '${GITHUB_REPO}'" \
    --project="$PROJECT_ID"
else
  echo "--> プロバイダは既にあります (条件を変える場合は update-oidc を使う)"
fi

# --- リポジトリに CI SA の借用を許可 -------------------------------------------
# attribute.repository で絞るので、他のリポジトリからは借用できない。
PRINCIPAL="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/attribute.repository/${GITHUB_REPO}"

echo "--> ${GITHUB_REPO} からの借用を許可"
retry_iam "リポジトリからの借用許可" \
  gcloud iam service-accounts add-iam-policy-binding "$CI_SA" \
    --member="$PRINCIPAL" \
    --role="roles/iam.workloadIdentityUser" \
    --project="$PROJECT_ID" \
    --quiet

PROVIDER_RESOURCE="projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/${POOL}/providers/${PROVIDER}"

cat <<EOM

==============================================
 セットアップ完了
==============================================

GitHub に登録する値 (Settings > Secrets and variables > Actions > Variables):

  WIF_PROVIDER          ${PROVIDER_RESOURCE}
  WIF_SERVICE_ACCOUNT   ${CI_SA}

gh CLI でまとめて登録するなら:

  gh variable set WIF_PROVIDER        --repo ${GITHUB_REPO} --body "${PROVIDER_RESOURCE}"
  gh variable set WIF_SERVICE_ACCOUNT --repo ${GITHUB_REPO} --body "${CI_SA}"

補足:
  - サービスアカウントのキー (JSON) は作っていません。
  - ${GITHUB_REPO} 以外のリポジトリからは認証できません。
  - fork からの PR では OIDC トークンが発行されないため、デプロイは起きません。
  - さらに main ブランチ限定にしたい場合は、プロバイダの条件を次のように更新します:
      gcloud iam workload-identity-pools providers update-oidc ${PROVIDER} \\
        --location=global --workload-identity-pool=${POOL} --project=${PROJECT_ID} \\
        --attribute-condition="assertion.repository == '${GITHUB_REPO}' && assertion.ref == 'refs/heads/main'"
EOM
