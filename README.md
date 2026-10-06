# supersub-selfhost — 팀 서비스를 AWS 없이 내 PC 에서 돌리기

팀 프로젝트 [Super-Sub](https://github.com/pmhllll12/super-sub.cloud)(경기 영상으로 실력을 확인하고
용병을 찾는 서비스)는 AWS 에서 돌았습니다. 프로젝트가 끝나도 링크 하나로 보여 줄 수 있도록,
**팀 코드는 한 줄도 고치지 않고** 전체를 내 PC(WSL2 + k3s)로 옮겨 Cloudflare 터널로 내보내는
구성을 만들었습니다. 이 저장소는 그 구성의 **인프라 코드**입니다.

- 데모: <https://supersub.anjgkwl.com> — 화면 · 서버 · 영상 분석이 모두 개인 PC 에서 돌아서, PC 가 꺼져 있으면 열리지 않습니다
- 소개: <https://portfolio.anjgkwl.com/projects/supersub/>

> **보여 주기용으로 추린 저장소입니다.** 팀의 애플리케이션 코드 · 비밀 값 · 데이터 · 화면 패치와 분석 워커를
> 띄우는 스크립트는 들어 있지 않아서 이것만으로는 돌지 않습니다. 스크립트가 가리키는 `upstream/` ·
> `web/patches/` · `web/make-patch.py` · `worker/run.sh` · `worker/install-service.sh` 는 실제로 쓰는 비공개
> 저장소에만 있습니다. 매니페스트와 스크립트의 주소는 `*.example.com` 으로, 시험용 비밀번호는 자리표시자로
> 바꿔 실었습니다.

## 무엇을 무엇으로 바꿨나

| AWS 에서 | 여기서 |
|---|---|
| EC2 — k3s + PostgreSQL | 로컬 k3s 의 `backend` · `postgres`(pgvector) |
| S3 | MinIO — 환경 변수 하나(`AWS_ENDPOINT_URL_S3`)로, 앱 코드 수정 없이 |
| 공인 IP + 프록시 | Cloudflare 터널 (공인 IP 불필요) |
| GPU 서버 (T4 16GB) | PC 의 RTX 3050 8GB — 추론 서버 없이 GPU 를 차례로 |
| 웹 (Vercel) | 같은 k3s 에 한 벌 더 |

## 저장소 구성

| 폴더 | 내용 |
|---|---|
| `k8s/` | 매니페스트 여섯(네임스페이스 · PostgreSQL · MinIO · 백엔드 · 터널 · 웹)과 스크립트 셋 — `make-secrets.sh`(`.env` 를 k8s Secret 으로) · `make-minio-cert.sh` · `wire-direct.sh` |
| `scripts/` | `backup.sh` · `bootstrap.sh`(클론 + 백업 하나로 전체 복구) · `smoke.sh`(공개 주소로 가입부터 삭제까지) · `minio_sync.py`(버킷 ↔ 폴더) · `update_upstream.sh`(팀 코드 사본을 다른 커밋으로) |
| `worker/` | 영상 분석 워커의 패키지 버전 고정(`agent.uv.lock`)과 설정 예시 |
| `web/` | 팀의 웹 코드를 고치지 않고 이미지로 만드는 빌드 |
| `.env.example` · `worker/worker.env.example` | 설정 예시 — 키마다 「빠지면 어떻게 되는지」를 적었다 |

## 팀 코드는 고치지 않는다

애플리케이션 코드는 팀 저장소의 **커밋 하나**에서 `fastapi/` · `www/` · `agent/` 를 `upstream/` 으로
그대로 옮겨 쓴다. 옮긴 뒤 폴더 해시가 팀 커밋과 같은지 대조한다(`scripts/update_upstream.sh`).
이 공개 저장소에는 그 사본을 싣지 않았다 — 코드는 팀 저장소에 있다.

화면을 조금 바꿀 때도 사본은 그대로 두고, **빌드 문맥에만 패치를 입힌다**(`web/build.sh`).
사본이 새 팀 코드로 바뀌어 패치가 안 맞으면 빌드가 멈춘다 — 모르는 사이 어긋나지 않게.

## 앱 코드를 안 고치고 S3 를 MinIO 로

팀 코드는 `boto3.client("s3", region_name=...)` 로 클라이언트를 만들고 엔드포인트를 받지 않는다.
그런데 **botocore 가 `AWS_ENDPOINT_URL_S3` 환경 변수를 읽어** 엔드포인트를 바꾼다(botocore 1.43.87 에서 확인).
사전 서명 URL 은 path-style 로 떨어져 MinIO 기본과 맞고, 앱이 쓰는 연산 일곱(`head_object` · `copy_object` ·
`delete_object` · `delete_objects` · `get_object` · 목록 · 사전 서명)을 MinIO 가 모두 지원한다.

🔴 이 값은 **브라우저에서 닿는 공개 주소**여야 한다. 앱이 이 엔드포인트로 사전 서명 URL 을 만들고
브라우저가 거기에 직접 올리기 때문이다. 컨테이너 안의 이름을 넣으면 업로드가 브라우저에서만 실패하고
서버 로그에는 아무것도 남지 않는다.

## HEAD 첫 요청 403 — 해결

터널을 붙인 직후 영상 등록이 500 을 냈다. 백엔드의 `head_object` 가 403 을 받았는데, 증상이 아주 좁았다.

| 무엇이 | 결과 |
|---|---|
| HEAD 첫 요청 (공개 주소) | 🔴 403 |
| HEAD 두 번째 (같은 키, 밀리초 뒤) | OK |
| GET · PUT · LIST (공개 주소) | 언제나 OK |
| HEAD (클러스터 안) | 언제나 OK |

캐시가 아니라 MinIO 가 낸 403 이었다 — 엣지를 지나며 요청이 바뀌어 서명이 안 맞은 것으로 보았다.
botocore 는 403 을 다시 시도하지 않아서, 사용자에게는 「업로드 직후 등록 실패, 조금 뒤 다시 하면 된다」로 보였다.

**고친 방법 — 백엔드만 MinIO 에 직결시킨다.** 브라우저는 Cloudflare 를 지나야 하지만 백엔드는 지날 이유가 없다.
같은 호스트 이름을 파드 안에서만 다르게 푼다.

```
브라우저 ──https──> Cloudflare ──터널──> minio:9000     (사전 서명 URL)
백엔드   ──https──────────────────────> minio:443      (hostAliases 로 직결)
```

| 조각 | 무엇 |
|---|---|
| `k8s/make-minio-cert.sh` | 저장소 호스트 이름의 자체 서명 인증서 — MinIO 가 쓰고, 백엔드가 믿는다 |
| `k8s/20-minio.yaml` | 9000 이 HTTPS 가 되고, 서비스에 443 을 연다(백엔드 직결용) |
| `k8s/30-backend.yaml` | `hostAliases` 로 그 호스트를 MinIO 로. `AWS_CA_BUNDLE` 로 자체 서명을 믿는다 |
| `k8s/wire-direct.sh` | ClusterIP 를 적용 시점에 채운다 — 매니페스트에 박으면 서비스를 다시 만들 때 조용히 옛 IP 를 가리킨다 |

이것이 성립하는 근거는 **SigV4 가 스킴을 서명하지 않는다**는 것이다. 서명에 들어가는 것은 메서드 · 경로 ·
질의 · 헤더(Host 포함) · 페이로드 해시라서, 백엔드가 같은 호스트 이름으로만 접속하면 브라우저용 사전 서명
URL 과 서명이 맞는다. 자체 서명 인증서는 클러스터 밖으로 나가지 않는다 — 브라우저가 보는 것은 Cloudflare 의 인증서다.

## 영상 분석

팀은 GPU 서버(T4 16GB)에서 추론 서버(vLLM)를 따로 띄웠다. 여기서는 `SUPERSUB_VLLM_URL` 을 비워
에이전트가 판정 모델(EXAONE 1.2B)을 직접 올리게 하고, 자세 추출과 **차례로** GPU 를 쓴다 — 그래서 8GB 에 들어간다.

워커는 파드가 아니라 **호스트에서** 상시 서비스로 돈다. GPU 를 파드에 넘기려면 장치 플러그인이 필요한데
WSL 에는 깔지 않았다. 그래서 MinIO 를 NodePort 로 열어 호스트의 워커가 직결하게 했다(`k8s/20-minio.yaml`).

팀이 에이전트의 잠금 파일을 git 에 올리지 않아서, 새로 설치하면 그날의 최신 버전이 골라진다.
`worker/agent.uv.lock` 으로 버전을 고정하고 `uv sync --locked` 로 설치한다 — 설정과 잠금 파일이 안 맞으면
멈춘다(`scripts/bootstrap.sh` 7단계).

## 백업과 복구

git 에는 「만드는 법」만 있다. 비밀 값과 데이터는 git 에 넣을 수 없어서 둘로 나눴다.

```bash
bash scripts/backup.sh                    # git 에 없는 것 전부 → 백업 폴더 하나
bash scripts/bootstrap.sh <백업 폴더>      # 깨끗한 환경에서 되살리기
```

백업에는 비밀 파일 둘, k8s 시크릿(터널 자격증명 포함), DB 덤프, 객체 전부와 그 Content-Type, 그리고
건수를 적은 목록이 들어간다. 복구 끝에 그 목록과 대조한다. 암호화한 사본은 PC 밖에 둔다.

**실제로 해 봤다** — 네임스페이스를 통째로 지우고, 로컬 폴더와 워커 서비스도 지운 뒤, 새로 클론해
`bootstrap.sh` 하나를 돌렸다. 약 1분 30초 뒤 DB · 영상 · 백엔드 · 웹 · 터널 · 워커가 되살아났고 건수가 백업과 같았다.
이 시험은 기계 쪽 준비물(WSL · k3s · GPU 드라이버 · 컨테이너 이미지)이 남아 있는 상태에서 했다.

복구하며 찾은 것:

- 버킷을 만드는 Job 이 `http://` 로 붙고 있었다. MinIO 에 TLS 를 붙인 뒤로 **깨끗한 환경에서만** 영원히 기다린다 —
  돌던 환경은 그 전에 Job 이 끝나 있어서 드러나지 않았다. 「돌던 환경에서 된다」와 「새로 띄워도 된다」는 다르다
- `/` 로 끝나는 0바이트 「폴더 표시」 객체를 파일로 내리면 빈 파일이 폴더 자리를 막는다 — 목록에만 적는다
- 객체를 파일로 내리면 Content-Type 이 사라진다 — 따로 적어 두지 않으면 영상이 재생되지 않을 수 있다

## 이미지

레지스트리 없이, k3s 의 containerd 에 직접 빌드해 넣는다. 그래서 매니페스트는 `imagePullPolicy: Never` 다.

```bash
sudo nerdctl --address /run/k3s/containerd/containerd.sock --namespace k8s.io \
  build -t supersub-backend:local upstream/fastapi
```

평소에 sudo 가 필요한 곳은 이미지 빌드뿐이다. 배포와 운영은 sudo 없이 된다(k3s 설치처럼 기계에 한 번 하는 준비는 따로다).

## 띄우는 순서

```bash
# 이미지 둘(백엔드 · 웹)은 먼저 빌드해 둔다 — 위 「이미지」 · `web/build.sh`
cp .env.example .env          # 값을 채운다
bash k8s/make-secrets.sh      # .env → k8s Secret (다시 돌려도 안전)

k3s kubectl apply -f k8s/00-namespace.yaml -f k8s/10-postgres.yaml
bash k8s/make-minio-cert.sh   # MinIO TLS + 백엔드가 믿을 CA
k3s kubectl apply -f k8s/20-minio.yaml
bash k8s/wire-direct.sh       # 백엔드 — MinIO ClusterIP 를 채워 적용한다
k3s kubectl apply -f k8s/50-web.yaml
k3s kubectl apply -f k8s/40-cloudflared.yaml   # 터널 자격증명 시크릿을 만든 뒤(파일 머리의 「준비」)
bash worker/install-service.sh                 # 분석 워커를 상시 서비스로(이 저장소에는 싣지 않았다)
```

확인은 `bash scripts/smoke.sh` — 공개 주소만으로 가입 → 로그인 → 사전 서명 URL 로 업로드 → 등록 →
재생(올린 것과 바이트 단위 대조) → 삭제까지 본다.
