#!/usr/bin/env bash
# MinIO 에 `supersub-storage.example.com` 이름의 자체 서명 인증서를 달아, **백엔드가
# Cloudflare 를 안 지나고 직결**할 수 있게 한다. (README 「HEAD 첫 요청 403」)
#
# 🔴 왜 같은 호스트 이름이어야 하나: 사전 서명 URL 의 서명은 **Host 헤더**를
#    포함한다. 백엔드가 다른 이름으로 접속하면 브라우저용 서명과 안 맞는다.
#    반대로 **스킴(http/https)은 서명에 안 들어가므로** 안팎이 달라도 된다.
#
# 🔴 이 인증서는 **클러스터 안에서만** 쓰인다. 브라우저는 Cloudflare 가 주는
#    진짜 인증서를 보므로 자체 서명이 노출되지 않는다.
#
# 다시 돌려도 안전하다(시크릿을 덮어쓴다).
set -euo pipefail

cd "$(dirname "$0")/.."
NS=supersub
HOST=supersub-storage.example.com
KC="${KUBECONFIG:-$HOME/.kube/config}"
k() { KUBECONFIG="$KC" k3s kubectl "$@"; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# MinIO 는 `public.crt`/`private.key` 라는 이름을 본다. SAN 에 호스트를 넣는다.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/private.key" -out "$TMP/public.crt" \
  -subj "/CN=$HOST" \
  -addext "subjectAltName=DNS:$HOST,DNS:minio,DNS:minio.$NS.svc,DNS:localhost,IP:127.0.0.1" \
  2>/dev/null

k -n "$NS" create secret generic minio-tls \
  --from-file=public.crt="$TMP/public.crt" \
  --from-file=private.key="$TMP/private.key" \
  --dry-run=client -o yaml | k apply -f -

# 백엔드가 이 인증서를 믿게 한다 — botocore 는 `AWS_CA_BUNDLE` 을 읽는다.
k -n "$NS" create secret generic minio-ca \
  --from-file=ca.crt="$TMP/public.crt" \
  --dry-run=client -o yaml | k apply -f -

echo
echo "--- 인증서 ---"
openssl x509 -in "$TMP/public.crt" -noout -subject -ext subjectAltName | sed 's/^/  /'
