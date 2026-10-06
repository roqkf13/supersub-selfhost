#!/usr/bin/env bash
# 공개 주소만으로 전체 경로를 확인한다 — 포트포워드 없이, 브라우저가 하는 그대로.
#
#   bash scripts/smoke.sh
#
# 가입 -> 로그인 -> 업로드 자리 -> 사전 서명 URL 로 PUT -> 등록 -> 재생 GET -> 삭제
#
# 🔴 `curl -4` 를 쓴다. 이 PC 는 IPv6 가 안 나가서 빼면 000 이 나오고
#    서버 문제로 오진하기 쉽다(브라우저는 IPv4 로 알아서 넘어간다).
# 🔴 시험 계정이 하나씩 남는다(`smoke<시각>@example.com`). 영상은 지운다.
set -uo pipefail
API=${API:-https://supersub-api.example.com/api/v1}
C=(curl -4 -s -m 60)
fail() { echo "🔴 $*"; exit 1; }
j() { python3 -c "import sys,json; print(json.load(sys.stdin)$1)"; }

E="smoke$(date +%s)@example.com"
"${C[@]}" -o /dev/null -X POST "$API/auth/signup" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$E\",\"password\":\"CHANGE_ME\",\"nickname\":\"smoke$(date +%H%M%S)\"}"
T=$("${C[@]}" -X POST "$API/auth/login" -H 'Content-Type: application/json' \
  -d "{\"email\":\"$E\",\"password\":\"CHANGE_ME\"}" | j '.get("access_token","")') || true
[ -n "$T" ] || fail "로그인 실패"
echo "가입·로그인      ✅"

SPOT=$("${C[@]}" -X POST "$API/videos/upload-url" -H "Authorization: Bearer $T" \
  -H 'Content-Type: application/json' \
  -d '{"content_type":"video/mp4","size_bytes":4096,"filename":"smoke.mp4","analyze":false}')
KEY=$(echo "$SPOT" | j '["storage_key"]') || fail "upload-url: $SPOT"
URL=$(echo "$SPOT" | j '["upload_url"]')

TMP=$(mktemp); trap 'rm -f "$TMP" "$TMP.back"' EXIT
head -c 4096 /dev/urandom > "$TMP"
CODE=$("${C[@]}" -o /dev/null -w '%{http_code}' -X PUT "$URL" -H 'Content-Type: video/mp4' --data-binary @"$TMP")
[ "$CODE" = 200 ] || fail "PUT -> $CODE"
echo "업로드(PUT)      ✅ 200"

REG=$("${C[@]}" -X POST "$API/videos" -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d "{\"sport_code\":\"football\",\"storage_key\":\"$KEY\",\"duration_ms\":10000,\"width\":1920,\"height\":1080,\"analyze\":false}" \
  -w '|%{http_code}')
[ "${REG##*|}" = 201 ] || fail "등록 -> ${REG##*|}"
VID=$(echo "${REG%|*}" | j '["id"]')
echo "등록             ✅ 201"

PB=$("${C[@]}" "$API/videos/$VID/playback-url" -H "Authorization: Bearer $T" | j '["url"]')
"${C[@]}" -o "$TMP.back" "$PB"
cmp -s "$TMP" "$TMP.back" || fail "재생한 내용이 올린 것과 다르다"
echo "재생(GET)        ✅ 올린 것과 바이트 단위 동일"

CODE=$("${C[@]}" -o /dev/null -w '%{http_code}' -X DELETE "$API/videos/$VID" -H "Authorization: Bearer $T")
[ "$CODE" = 204 ] || fail "삭제 -> $CODE"
echo "삭제             ✅ 204"
