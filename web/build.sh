#!/usr/bin/env bash
# `upstream/www/`(팀 코드 사본)를 이미지로 만든다.
#
#   bash web/build.sh           # 빌드 (sudo)
#   bash web/build.sh --check   # 문맥을 뜨고 패치가 맞는지만 본다 — sudo 불필요.
#                               # upstream 을 새 팀 코드로 바꾼 뒤 먼저 돌린다
#
# 🔴 빌드 문맥을 `git archive` 로 뜬다 — 이유 둘:
#    1. 로컬 `node_modules`(수백 MB)가 문맥에 안 딸려 간다. `.dockerignore` 를
#       두려면 **사본에 파일을 넣어야** 해서 안 쓴다(사본은 고치지 않는다).
#    2. **커밋된 것**이 빌드된다 — 작업 중인 변경이 섞이지 않는다.
#
# 🔴 sudo 가 필요하다(이 기계는 k3s 의 containerd 에 붙는다 — README 참고).
set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
REF="${REF:-HEAD}"
IMAGE="${IMAGE:-supersub-web:local}"
SOCK=/run/k3s/containerd/containerd.sock
CHECK=0; [ "${1:-}" = --check ] && CHECK=1

git -C "$REPO" cat-file -e "$REF:upstream/www" 2>/dev/null \
  || { echo "🔴 $REF 에 upstream/www 가 없다 — 커밋했나?" >&2; exit 1; }
[ "$CHECK" = 1 ] || [ -S "$SOCK" ] || { echo "🔴 k3s containerd 소켓이 없다 — k3s 가 떠 있나?" >&2; exit 1; }

CTX=$(mktemp -d); trap 'rm -rf "$CTX"' EXIT
git -C "$REPO" archive "$REF:upstream/www" | tar -x -C "$CTX"

# 🔴 **개인 사본 패치** — upstream 은 안 고치고, 복사해 온 문맥에만 입힌다.
#    (테스트 로그인을 8·9번 둘로 · 단추 문구 「테스트용 로그인」)
#    upstream 이 바뀌어 안 맞으면 **여기서 멈춘다** — 모르는 사이 어긋나지 않게.
#    고치는 법: python3 web/make-patch.py 로 새 코드 기준 패치를 다시 만든다.
for p in "$(dirname "$0")"/patches/*.patch; do
  [ -e "$p" ] || continue
  patch -p1 -d "$CTX" --dry-run -s < "$p" >/dev/null \
    || { echo "🔴 패치가 안 맞는다: $(basename "$p") — python3 web/make-patch.py 로 다시 만드십시오" >&2; exit 1; }
  patch -p1 -d "$CTX" -s < "$p"
  echo "패치: $(basename "$p")"
done

cp "$(dirname "$0")/Dockerfile" "$CTX/Dockerfile"
echo "문맥: $(du -sh "$CTX" | cut -f1) (팀 코드 $(git -C "$REPO" show "$REF:upstream/COMMIT" | cut -c1-7))"
[ "$CHECK" = 0 ] || { echo "✅ --check — 패치가 맞는다. 빌드는 하지 않았다"; exit 0; }

sudo nerdctl --address "$SOCK" --namespace k8s.io build \
  -t "$IMAGE" "$CTX"

echo
sudo k3s ctr -n k8s.io images ls | grep -F "$IMAGE" || echo "🔴 이미지가 안 보인다"
