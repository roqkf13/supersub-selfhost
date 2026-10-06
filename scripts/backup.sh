#!/usr/bin/env bash
# git 에 **없는 것 전부**를 한 폴더에 묶는다 — 비밀·터널 자격증명·DB·영상.
#
#   bash scripts/backup.sh
#   BACKUP_ROOT=/경로 bash scripts/backup.sh     # 기본 /mnt/d/supersub-backup
#
# 🔴 git 에는 「만드는 법」만 있다. 이 백업이 있어야 깨끗한 환경에서
#    `bootstrap.sh <이 폴더>` 로 **같은 서브도메인에 같은 데이터로** 되살아난다.
#    특히 **터널 자격증명은 여기 말고 어디에도 없다** — 잃으면 터널을 새로 파고
#    DNS 를 다시 걸어야 한다.
#
# 🔴 **비밀이 들어 있다.** 기본 위치를 D: 로 둔 것은 WSL 을 통째로 지워도 남게
#    하려는 것이다. 공개된 곳·git 에 올리지 않는다. 폴더 권한은 700 이다.
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
NS=supersub
KC="${KUBECONFIG:-$HOME/.kube/config}"
k() { KUBECONFIG="$KC" k3s kubectl -n "$NS" "$@"; }

ROOT="${BACKUP_ROOT:-/mnt/d/supersub-backup}"
DEST="$ROOT/$(date +%Y%m%d-%H%M%S)"
umask 077
mkdir -p "$DEST/env"
echo "백업 → $DEST"

# 1) 비밀 파일 — git 에 안 올라가는 둘
for f in .env worker/worker.env; do
  if [ -f "$REPO/$f" ]; then cp "$REPO/$f" "$DEST/env/$(basename "$f")"
  else echo "  ⚠️ $f 가 없다 — 시크릿에서 되살릴 수 있지만 원본은 없는 셈이다"; fi
done
echo "1) 비밀 파일     ✅"

# 2) k8s 시크릿 전부 — 🔴 터널 자격증명(supersub-tunnel)이 여기에만 있다.
#    클러스터 고유 칸(uid·resourceVersion 등)을 걷어 **다른 클러스터에 그대로
#    apply** 되게 한다.
k get secret -o json | python3 -c '
import json, sys
d = json.load(sys.stdin)
keep = []
for s in d["items"]:
    if s.get("type") != "Opaque":
        continue
    m = s["metadata"]
    s["metadata"] = {"name": m["name"], "namespace": m["namespace"]}
    keep.append(s)
json.dump({"apiVersion": "v1", "kind": "List", "items": keep}, sys.stdout)
print(f"  시크릿 {len(keep)}개: " + ", ".join(s["metadata"]["name"] for s in keep), file=sys.stderr)
' > "$DEST/k8s-secrets.json"
grep -q supersub-tunnel "$DEST/k8s-secrets.json" || { echo "🔴 터널 자격증명이 빠졌다" >&2; exit 1; }
echo "2) k8s 시크릿    ✅"

# 3) DB — 커스텀 형식이라 pg_restore 로 골라 되살릴 수 있다
k exec deploy/postgres -- pg_dump -Fc --no-owner --no-acl -U supersub -d supersub \
  > "$DEST/db.dump"
k exec -i deploy/postgres -- pg_restore -l < "$DEST/db.dump" > /dev/null \
  || { echo "🔴 덤프가 읽히지 않는다" >&2; exit 1; }
echo "3) DB 덤프       ✅ $(du -h "$DEST/db.dump" | cut -f1)"

# 4) 영상·리포트 — 호스트에서 NodePort 로 객체 단위로 받는다
CA=$(mktemp); trap 'rm -f "$CA"' EXIT
k get secret minio-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA"
eval "$(k get secret supersub-minio -o json | python3 -c '
import json, sys, base64
d = json.load(sys.stdin)["data"]
print("export AWS_ACCESS_KEY_ID=" + base64.b64decode(d["MINIO_ROOT_USER"]).decode())
print("export AWS_SECRET_ACCESS_KEY=" + base64.b64decode(d["MINIO_ROOT_PASSWORD"]).decode())
')"
AWS_CA_BUNDLE="$CA" "$REPO/upstream/agent/.venv/bin/python" "$REPO/scripts/minio_sync.py" export "$DEST/minio"
echo "4) MinIO 객체    ✅"

# 5) 무엇이 들어 있나 — 복원할 때 이것과 대조한다
q() { k exec deploy/postgres -- psql -U supersub -d supersub -tAc "$1" | tr -d ' '; }
{
  echo "시각=$(date -Iseconds)"
  # upstream/ 이 어느 팀 커밋의 사본인가 — 복원할 때 사본과 대조한다
  echo "팀저장소커밋=$(cut -c1-7 "$REPO/upstream/COMMIT" 2>/dev/null || echo '?')"
  echo "배포저장소커밋=$(git -C "$REPO" rev-parse --short HEAD)"
  echo "사용자=$(q 'select count(*) from "user"')"
  echo "영상=$(q 'select count(*) from video')"
  echo "분석작업=$(q 'select count(*) from analysis_job')"
  echo "리포트=$(q 'select count(*) from analysis_report')"
  echo "객체=$(find "$DEST/minio" -type f ! -name _content_types.json | wc -l)"
} > "$DEST/manifest.txt"
chmod -R go-rwx "$DEST"
echo
cat "$DEST/manifest.txt" | sed 's/^/  /'
echo "  크기=$(du -sh "$DEST" | cut -f1)"
echo
echo "복원: bash scripts/bootstrap.sh $DEST"
