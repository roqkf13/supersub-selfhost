#!/usr/bin/env bash
# 깨끗한 환경에서 **클론 + 백업 하나**로 서브도메인까지 되살린다.
#
#   git clone <운영 저장소 주소>
#   cd <운영 저장소>
#   bash scripts/bootstrap.sh /mnt/d/supersub-backup/<시각>
#
# 🔴 **진짜 터미널에서** 돌린다 — 이미지 빌드에 sudo 가 필요하고 비밀번호를 묻는다.
#
# git 에는 「만드는 법」과 코드(`upstream/` — 팀 코드 사본)가 있고, 비밀(터널
# 자격증명 포함)·DB·영상은 **백업에만** 있다(`scripts/backup.sh` 가 만든다).
# 이 스크립트는 그 둘을 합친다. 🔴 팀 저장소는 **필요 없다**(2026-09-22 부터 —
# 사본만으로 빌드한다).
#
# 여러 번 돌려도 안전하다 — 이미 있는 것은 건너뛴다. 특히 **DB 에 데이터가
# 있으면 복원하지 않는다**(덮어쓰려면 FORCE_DB_RESTORE=1).
#
# ── 이 스크립트가 **못 하는 것** (기계에 한 번만, 사람이) ─────────────────────
#   WSL2 + systemd · k3s 설치 · NVIDIA 드라이버(분석용) · nerdctl
#   → 없으면 1단계에서 무엇이 없는지 말하고 멈춘다.
set -euo pipefail

BACKUP="${1:?백업 폴더를 주십시오 — 예: bash scripts/bootstrap.sh /mnt/d/supersub-backup/<시각>}"
BACKUP=$(cd "$BACKUP" && pwd)
REPO=$(cd "$(dirname "$0")/.." && pwd)
UP="$REPO/upstream"
NS=supersub
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
SOCK=/run/k3s/containerd/containerd.sock

k() { k3s kubectl -n "$NS" "$@"; }
step() { echo; echo "━━ $* ━━"; }
die() { echo "🔴 $*" >&2; exit 1; }
wait_ready() {  # wait_ready <deploy> <초>
  k rollout status "deploy/$1" --timeout="${2:-240}s" >/dev/null \
    || { k get pods -l "app=$1"; die "$1 이 안 뜬다 — 위 상태를 보십시오"; }
  echo "  $1 ✅"
}

# ─────────────────────────────────────────────────────────────────────────────
step "1) 사전 점검"
for f in manifest.txt env/.env env/worker.env k8s-secrets.json db.dump minio/_content_types.json; do
  [ -e "$BACKUP/$f" ] || die "백업에 $f 가 없다 — backup.sh 로 만든 폴더가 맞나?"
done
sed 's/^/  백업: /' "$BACKUP/manifest.txt" | head -3

missing=()
for c in git curl python3 openssl k3s; do command -v "$c" >/dev/null || missing+=("$c"); done
[ ${#missing[@]} -eq 0 ] || die "없는 도구: ${missing[*]}"
systemctl is-active -q k3s || die "k3s 가 안 돈다 — sudo systemctl start k3s"
if ! k3s kubectl get nodes >/dev/null 2>&1; then
  echo "  ~/.kube/config 가 없거나 안 맞는다 — k3s 설정을 복사한다(sudo)"
  mkdir -p ~/.kube
  sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
  sudo chown "$USER" ~/.kube/config
  k3s kubectl get nodes >/dev/null || die "그래도 k3s 에 못 붙는다"
fi
echo "  k3s ✅"
command -v nerdctl >/dev/null || die "nerdctl 이 없다 — 이미지를 빌드할 수 없다"
nvidia-smi >/dev/null 2>&1 && echo "  GPU ✅ $(nvidia-smi --query-gpu=name --format=csv,noheader)" \
  || echo "  ⚠️ GPU 가 안 보인다 — 화면·API 는 되지만 영상 분석은 안 된다"
if ! command -v uv >/dev/null && [ ! -x "$HOME/.local/bin/uv" ]; then
  echo "  uv 설치(sudo 불필요)"
  curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null
fi
export PATH="$HOME/.local/bin:$PATH"
echo "  uv ✅ $(uv --version)"

# ─────────────────────────────────────────────────────────────────────────────
step "2) 코드 (upstream/ — 팀 코드 사본)"
for d in fastapi www agent; do
  [ -d "$UP/$d" ] || die "upstream/$d 가 없다 — 이 저장소를 온전히 클론했나?"
done
have=$(cut -c1-7 "$UP/COMMIT")
want=$(grep -oP '^팀저장소커밋=\K.*' "$BACKUP/manifest.txt" || true)
echo "  사본: 팀 커밋 $have"
[ -z "$want" ] || [ "$want" = "$have" ] \
  || echo "  ⚠️ 백업 때 코드는 $want, 사본은 $have — DB 스키마가 다를 수 있다(백엔드가 뜰 때 alembic 이 올린다)"

# ─────────────────────────────────────────────────────────────────────────────
step "3) 비밀 파일 되살리기 (git 에 없는 둘)"
umask 077
[ -f "$REPO/.env" ] || cp "$BACKUP/env/.env" "$REPO/.env"
[ -f "$REPO/worker/worker.env" ] || cp "$BACKUP/env/worker.env" "$REPO/worker/worker.env"
umask 022
echo "  .env · worker/worker.env ✅"

# ─────────────────────────────────────────────────────────────────────────────
step "4) 이미지 (sudo — 비밀번호를 물을 수 있다)"
if [ "${SKIP_IMAGES:-}" = 1 ]; then
  echo "  SKIP_IMAGES=1 — 이미지가 이미 있다고 보고 건너뜀"
else
have_image() { sudo nerdctl --address "$SOCK" --namespace k8s.io image inspect "$1" >/dev/null 2>&1; }
if have_image supersub-backend:local; then echo "  백엔드 이미지 있음 — 건너뜀"
else
  sudo nerdctl --address "$SOCK" --namespace k8s.io build -q \
    -t supersub-backend:local "$UP/fastapi" >/dev/null
  echo "  백엔드 이미지 빌드 ✅"
fi
if have_image supersub-web:local; then echo "  웹 이미지 있음 — 건너뜀"
else
  bash "$REPO/web/build.sh" >/dev/null
  echo "  웹 이미지 빌드 ✅"
fi
fi

# ─────────────────────────────────────────────────────────────────────────────
step "5) 네임스페이스·시크릿 (터널 자격증명 포함)"
k3s kubectl apply -f "$REPO/k8s/00-namespace.yaml" >/dev/null
k3s kubectl apply -f "$BACKUP/k8s-secrets.json" >/dev/null
echo "  시크릿 $(k get secret --no-headers | wc -l)개 ✅"

# ─────────────────────────────────────────────────────────────────────────────
step "6) PostgreSQL + DB 복원"
k3s kubectl apply -f "$REPO/k8s/10-postgres.yaml" >/dev/null
wait_ready postgres
psql_q() { k exec deploy/postgres -- psql -U supersub -d supersub -tAc "$1" 2>/dev/null | tr -d ' '; }
users=$(psql_q "select count(*) from \"user\"" || true)
if [ -n "$users" ] && [ "$users" != 0 ] && [ "${FORCE_DB_RESTORE:-}" != 1 ]; then
  echo "  DB 에 이미 사용자 $users 명 — 복원 건너뜀(덮으려면 FORCE_DB_RESTORE=1)"
else
  k exec deploy/postgres -- psql -U supersub -d postgres -q -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='supersub' AND pid<>pg_backend_pid()" >/dev/null
  k exec deploy/postgres -- psql -U supersub -d postgres -q -c 'DROP DATABASE IF EXISTS supersub' >/dev/null
  k exec deploy/postgres -- psql -U supersub -d postgres -q -c 'CREATE DATABASE supersub OWNER supersub' >/dev/null
  # 🔴 확장이 복원보다 먼저다 — `vector` 칸을 가진 테이블이 멈춘다
  k exec deploy/postgres -- psql -U supersub -d supersub -q -c 'CREATE EXTENSION IF NOT EXISTS vector' >/dev/null
  k exec -i deploy/postgres -- pg_restore -U supersub -d supersub --no-owner --no-acl --exit-on-error \
    < "$BACKUP/db.dump"
  echo "  복원 ✅ 사용자 $(psql_q 'select count(*) from "user"')명"
fi

# ─────────────────────────────────────────────────────────────────────────────
step "7) MinIO + 영상 복원"
# 🔴 Job 은 spec 이 바뀌면 apply 가 「field is immutable」로 거부된다 — 지우고
#    다시 만든다. 버킷 만들기는 `--ignore-existing` 이라 몇 번 돌아도 된다.
k delete job minio-create-bucket --ignore-not-found >/dev/null
k3s kubectl apply -f "$REPO/k8s/20-minio.yaml" >/dev/null
wait_ready minio
k wait --for=condition=complete job/minio-create-bucket --timeout=180s >/dev/null
echo "  버킷 ✅"
echo "  분석 에이전트 의존성(uv sync --extra aws) — 처음이면 수 분·수 GB"
# 🔴 버전은 `worker/agent.uv.lock` 으로 고정한다 — 팀이 `agent/uv.lock` 을 git 에
#    안 올려서, 없으면 **그날의 최신 버전**(torch·transformers …)으로 다시 고른다.
#    `--locked`: pyproject 와 lock 이 안 맞으면 멈춘다(모르는 사이 달라지지 않게).
cp "$REPO/worker/agent.uv.lock" "$UP/agent/uv.lock"
(cd "$UP/agent" && uv sync -q --extra aws --locked)
CA=$(mktemp); trap 'rm -f "$CA"' EXIT
k get secret minio-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "$CA"
eval "$(k get secret supersub-minio -o json | python3 -c '
import json, sys, base64
d = json.load(sys.stdin)["data"]
print("export AWS_ACCESS_KEY_ID=" + base64.b64decode(d["MINIO_ROOT_USER"]).decode())
print("export AWS_SECRET_ACCESS_KEY=" + base64.b64decode(d["MINIO_ROOT_PASSWORD"]).decode())
')"
AWS_CA_BUNDLE="$CA" "$UP/agent/.venv/bin/python" "$REPO/scripts/minio_sync.py" import "$BACKUP/minio"

# ─────────────────────────────────────────────────────────────────────────────
step "8) 백엔드 · 웹 · 터널"
# 🔴 백엔드는 `apply` 가 아니라 wire-direct 로 — MinIO ClusterIP 를 채워 넣는다
bash "$REPO/k8s/wire-direct.sh" >/dev/null
wait_ready backend
k3s kubectl apply -f "$REPO/k8s/50-web.yaml" >/dev/null
wait_ready web
k3s kubectl apply -f "$REPO/k8s/40-cloudflared.yaml" >/dev/null
wait_ready cloudflared

# ─────────────────────────────────────────────────────────────────────────────
step "9) 분석 워커 (상시 서비스)"
bash "$REPO/worker/install-service.sh" | sed 's/^/  /'

# ─────────────────────────────────────────────────────────────────────────────
step "10) 확인 — 공개 주소로"
echo "  터널이 붙기를 기다린다"
for _ in $(seq 30); do
  curl -4 -sf -o /dev/null -m 10 https://supersub-api.example.com/health && break
  sleep 3
done
echo "  백업과 대조 (🔴 스모크 앞에 — 스모크가 시험 계정을 하나 만든다):"
for kv in "사용자:select count(*) from \"user\"" "영상:select count(*) from video" "리포트:select count(*) from analysis_report"; do
  name=${kv%%:*}; now=$(psql_q "${kv#*:}")
  was=$(grep -oP "^${name}=\K.*" "$BACKUP/manifest.txt" || echo '?')
  [ "$now" = "$was" ] && echo "    $name $now ✅" || echo "    $name 지금 $now / 백업 $was ⚠️"
done
bash "$REPO/scripts/smoke.sh" | sed 's/^/  /'
code=$(curl -4 -s -o /dev/null -w '%{http_code}' -m 20 -L https://supersub.example.com/)
[ "$code" = 200 ] && echo "  화면 https://supersub.example.com ✅" || die "화면이 $code 다"

echo
echo "✅ 끝 — https://supersub.example.com"
