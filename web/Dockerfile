# `upstream/www/`(팀 코드 사본, Next.js)를 **고치지 않고** 이미지로 만든다.
#
# 🔴 `output: "standalone"` 을 쓰면 이미지가 훨씬 작아지지만 그건
#    `www/next.config.ts` 를 고쳐야 한다 — **남의 영역이고 팀 저장소다.**
#    커진 이미지를 감수하고 `next start` 를 그대로 쓴다.
#
# 빌드 문맥은 `git archive` 로 뜬 **깨끗한 www 사본**이다(`web/build.sh`) —
# 로컬 `node_modules` 가 딸려 들어가지 않고, 커밋된 것과 같은 것이 빌드된다.

FROM node:22-slim AS build
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY . .

# 🔴 `NEXT_PUBLIC_*` 는 **빌드 시점에 번들로 박힌다.** 런타임 환경변수로는
#    안 바뀐다. 비워 두면 구글 로그인 단추가 아예 안 그려질 뿐(깨지지 않는다) —
#    어차피 이 도메인은 구글 OAuth 에 등록돼 있지 않아 눌러도 안 된다.
ARG NEXT_PUBLIC_GOOGLE_CLIENT_ID=""
ENV NEXT_PUBLIC_GOOGLE_CLIENT_ID=$NEXT_PUBLIC_GOOGLE_CLIENT_ID

ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

FROM node:22-slim
WORKDIR /app
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 PORT=3000

COPY --from=build /app ./

EXPOSE 3000
CMD ["npx", "next", "start"]
