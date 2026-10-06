#!/usr/bin/env bash
# upstream/(팀 코드 사본)을 팀 저장소의 다른 커밋으로 바꾼다.
#
#   bash scripts/update_upstream.sh <팀 저장소 경로> <커밋>
#   예) bash scripts/update_upstream.sh ~/projects/super-sub.cloud origin/main
#
# 🔴 세 폴더(fastapi·www·agent)를 **통째로** 바꾼다 — 일부만 가져오면 사본이
#    어느 커밋과 같은지 말할 수 없게 된다. 끝에 폴더 해시로 팀 커밋과 대조한다.
# 🔴 실행 환경(`upstream/agent/.venv` 등 git 에 없는 파일)은 지우지도, 올리지도
#    않는다 — 그래서 `git add -f upstream/agent` 가 아니라 **팀 커밋의 파일 목록만**
#    넣는다(-f 로 폴더를 통째로 넣으면 6GB 짜리 .venv 가 같이 들어간다).
# 🔴 커밋·빌드·재시작은 하지 않는다 — 끝에 순서를 알려 준다.
set -euo pipefail
TEAM="${1:?팀 저장소 경로를 주십시오}"; REF="${2:?커밋을 주십시오 (예: origin/main)}"
REPO=$(cd "$(dirname "$0")/.." && pwd)
UP="$REPO/upstream"
DIRS=(fastapi www agent)
die() { echo "🔴 $*" >&2; exit 1; }

NEW=$(git -C "$TEAM" rev-parse --verify "$REF^{commit}") || die "$TEAM 에 $REF 가 없다"
OLD=$(cat "$UP/COMMIT")
[ "$NEW" != "$OLD" ] || { echo "이미 ${NEW:0:7} 이다 — 할 일 없음"; exit 0; }
git -C "$REPO" diff --quiet HEAD -- upstream && git -C "$REPO" diff --cached --quiet -- upstream \
  || die "upstream/ 에 커밋 안 된 변경이 있다 — 먼저 정리하십시오"

cd "$REPO"
# 중간에 멈추면 반쯤 바뀐 채 남는다 — 되돌리는 법을 알린다(.venv 등 무시 파일은 안 지운다)
trap 'echo "🔴 중간에 멈췄다. 되돌리기: git reset -q HEAD -- upstream && git checkout -- upstream && git clean -fdq upstream" >&2' ERR
# 1) 추적 중인 파일만 지운다 — .venv·node_modules 같은 추적 안 되는 것은 남는다
git rm -r -q "${DIRS[@]/#/upstream/}"
# 2) 새 커밋의 파일을 풀고, 그 목록만 넣는다.
#    🔴 목록은 NUL 로 주고받는다 — 줄 단위면 git 이 한글 파일명을 "\352..." 로
#    감싸 내보내서 `git add` 가 못 찾는다(2026-09-22 실측)
git -C "$TEAM" archive "$NEW" "${DIRS[@]}" | tar -x -C "$UP"
git -C "$TEAM" ls-tree -r -z --name-only "$NEW" -- "${DIRS[@]}" | sed -z 's|^|upstream/|' \
  | git add -f --pathspec-from-file=- --pathspec-file-nul
echo "$NEW" > "$UP/COMMIT"
git add upstream/COMMIT

# 3) 팀 커밋과 같은가 — 폴더 해시로
bad=0
for d in "${DIRS[@]}"; do
  a=$(git write-tree --prefix="upstream/$d/"); b=$(git -C "$TEAM" rev-parse "$NEW:$d")
  [ "$a" = "$b" ] && echo "  $d ✅" || { echo "  $d 🔴 해시가 다르다"; bad=1; }
done
[ "$bad" = 0 ] || die "사본이 팀 커밋과 다르다 — git status 로 보십시오(커밋하지 마십시오)"
trap - ERR   # 여기부터는 안내 출력뿐 — `| head` 로 잘려도 「멈췄다」고 하지 않게

echo
echo "✅ upstream: ${OLD:0:7} → ${NEW:0:7} (스테이징만 했다)"
git diff --cached --stat -- upstream | tail -1
cat <<EOF

다음 순서:
  1) git commit -m "upstream: 팀 코드 ${NEW:0:7}"
  2) bash web/build.sh --check              # 패치가 맞는지 — 안 맞으면 python3 web/make-patch.py
  3) 분석 환경 — 버전 고정 파일도 새로 만들어 커밋한다:
       (cd upstream/agent && uv lock && uv sync --extra aws --locked)
       cp upstream/agent/uv.lock worker/agent.uv.lock    # 그리고 git commit
       systemctl --user restart supersub-worker
  4) 이미지 (진짜 터미널 — sudo):
       sudo nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io \\
         build -t supersub-backend:local upstream/fastapi
       bash web/build.sh
       k3s kubectl -n supersub rollout restart deploy/backend deploy/web
  5) bash scripts/smoke.sh && bash scripts/backup.sh
EOF
