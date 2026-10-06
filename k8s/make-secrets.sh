#!/usr/bin/env bash
# 시크릿 셋을 만든다. **값은 저장소에 안 들어간다** — 이 스크립트가 `.env` 를
# 읽어 k8s Secret 으로 넣는다.
#
#   cp .env.example .env   # 값을 채우고
#   bash k8s/make-secrets.sh
#
# 다시 돌려도 안전하다(`--dry-run=client | apply -f -` 로 덮어쓴다).
set -euo pipefail

cd "$(dirname "$0")/.."
NS=supersub
KC="${KUBECONFIG:-$HOME/.kube/config}"
k() { KUBECONFIG="$KC" k3s kubectl "$@"; }

[ -f .env ] || { echo "🔴 .env 가 없다. .env.example 을 복사해 채우십시오." >&2; exit 1; }
# shellcheck disable=SC1091
set -a; . ./.env; set +a

need() {
  local name="$1"
  [ -n "${!name:-}" ] || { echo "🔴 .env 의 $name 이 비어 있다." >&2; exit 1; }
}
for v in POSTGRES_PASSWORD DATABASE_URL MINIO_ROOT_USER MINIO_ROOT_PASSWORD \
         JWT_SECRET S3_BUCKET AWS_ENDPOINT_URL_S3; do need "$v"; done

k get ns "$NS" >/dev/null 2>&1 || k apply -f k8s/00-namespace.yaml

mk() {  # mk <이름> <key=value>...
  local name="$1"; shift
  local args=()
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  k -n "$NS" create secret generic "$name" "${args[@]}" \
    --dry-run=client -o yaml | k apply -f -
}

mk supersub-db \
  "POSTGRES_PASSWORD=$POSTGRES_PASSWORD" \
  "DATABASE_URL=$DATABASE_URL"

mk supersub-minio \
  "MINIO_ROOT_USER=$MINIO_ROOT_USER" \
  "MINIO_ROOT_PASSWORD=$MINIO_ROOT_PASSWORD"

# 🔴 앱 시크릿. `APP_ENV` 를 빠뜨리면 기본값이 `local` 이라 `/docs` 가 **열린 채로
#    정상 동작한다** — 다른 키는 빠지면 기능이 멈춰 바로 드러나는데 이것만 반대다.
mk supersub-app \
  "APP_ENV=${APP_ENV:-prod}" \
  "JWT_SECRET=$JWT_SECRET" \
  "GOOGLE_CLIENT_IDS=${GOOGLE_CLIENT_IDS:-}" \
  "ADMIN_EMAILS=${ADMIN_EMAILS:-}" \
  "GEMINI_API_KEY=${GEMINI_API_KEY:-}" \
  "WORKER_TOKEN=${WORKER_TOKEN:-}" \
  "ANALYSIS_JOB_TIMEOUT_MINUTES=${ANALYSIS_JOB_TIMEOUT_MINUTES:-30}" \
  "PROVISIONAL_VIDEO_TTL_HOURS=${PROVISIONAL_VIDEO_TTL_HOURS:-24}" \
  "UPLOAD_URL_TTL_SECONDS=${UPLOAD_URL_TTL_SECONDS:-900}" \
  "S3_BUCKET=$S3_BUCKET" \
  "AWS_REGION=${AWS_REGION:-us-east-1}" \
  "AWS_ENDPOINT_URL_S3=$AWS_ENDPOINT_URL_S3" \
  "AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:-$MINIO_ROOT_USER}" \
  "AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:-$MINIO_ROOT_PASSWORD}"

echo
echo "--- 만들어진 시크릿 ---"
k -n "$NS" get secret supersub-db supersub-minio supersub-app
