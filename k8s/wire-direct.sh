#!/usr/bin/env bash
# 백엔드가 `supersub-storage.example.com` 을 **클러스터 안 MinIO 로** 풀도록
# hostAliases 의 IP 를 지금 ClusterIP 로 채워 적용한다.
#
# 🔴 왜 스크립트인가: ClusterIP 는 서비스를 다시 만들면 바뀐다. 매니페스트에
#    박아 두면 어느 날 조용히 옛 IP 를 가리킨다. 그래서 적용 시점에 채운다.
set -euo pipefail

cd "$(dirname "$0")/.."
NS=supersub
KC="${KUBECONFIG:-$HOME/.kube/config}"
k() { KUBECONFIG="$KC" k3s kubectl "$@"; }

IP=$(k -n "$NS" get svc minio -o jsonpath='{.spec.clusterIP}')
[ -n "$IP" ] || { echo "🔴 minio 서비스가 없다 — 먼저 20-minio.yaml 을 적용하십시오." >&2; exit 1; }
echo "MinIO ClusterIP: $IP"

sed "s/MINIO_CLUSTER_IP/$IP/" k8s/30-backend.yaml | k apply -f -

echo
echo "--- 확인 ---"
k -n "$NS" rollout status deploy/backend --timeout=180s
k -n "$NS" exec deploy/backend -c backend -- python -c "
import socket, os
print('  파드가 보는 주소:', socket.gethostbyname('supersub-storage.example.com'))
print('  엔드포인트      :', os.environ.get('AWS_ENDPOINT_URL_S3'))
"
