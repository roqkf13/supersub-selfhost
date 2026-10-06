"""MinIO 버킷 ↔ 로컬 폴더. 백업(export)과 복원(import)에 같이 쓴다.

    python minio_sync.py export <폴더>    # 버킷 → 폴더
    python minio_sync.py import <폴더>    # 폴더 → 버킷

🔴 **호스트에서 NodePort(30900)로 직결한다.** MinIO 파드엔 `tar` 가 없어서
파드 밖으로 통째로 뺄 수 없다. 객체 단위로 옮기면 MinIO 버전이 바뀌어도
복원된다(데이터 디렉터리를 그대로 복사하면 같은 버전에서만 된다).

🔴 **Content-Type 을 따로 적어 둔다**(`_content_types.json`). 파일로 내리면
사라지는데, 영상이 `binary/octet-stream` 으로 복원되면 브라우저가 재생을
못 할 수 있다.

🔴 **`/` 로 끝나는 0바이트 「폴더 표시」 객체**(`reports/`·`videos/`)는 파일로
내리지 않는다. 내리면 `reports` 라는 빈 **파일**이 생겨서 그 아래 객체를 담을
**폴더**를 못 만든다(`NotADirectoryError`, 실측). 목록에만 적고 복원 때 빈
객체로 다시 만든다.

자격증명은 환경변수(`AWS_ACCESS_KEY_ID`·`AWS_SECRET_ACCESS_KEY`)에서, 인증서는
`AWS_CA_BUNDLE` 에서 읽는다 — 부르는 쪽(backup.sh·bootstrap.sh)이 채운다.
다시 돌려도 안전하다 — 크기가 같은 것은 건너뛴다.
"""
import json
import os
import pathlib
import sys

import boto3
from botocore.config import Config

BUCKET = os.environ.get("S3_BUCKET", "supersub")
META = "_content_types.json"

s3 = boto3.client(
    "s3",
    endpoint_url=os.environ.get("MINIO_ENDPOINT", "https://localhost:30900"),
    region_name="us-east-1",
    config=Config(retries={"max_attempts": 5}, s3={"addressing_style": "path"}),
)


def listing():
    out = {}
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=BUCKET):
        for o in page.get("Contents", []):
            out[o["Key"]] = o["Size"]
    return out


def export(root: pathlib.Path):
    root.mkdir(parents=True, exist_ok=True)
    types = {}
    objs = listing()
    done = skipped = 0
    for i, (key, size) in enumerate(sorted(objs.items()), 1):
        dest = root / key
        head = s3.head_object(Bucket=BUCKET, Key=key)
        types[key] = head.get("ContentType") or "binary/octet-stream"
        if key.endswith("/"):  # 폴더 표시 — 목록에만 남긴다
            skipped += 1
        elif dest.exists() and dest.stat().st_size == size:
            skipped += 1
        else:
            dest.parent.mkdir(parents=True, exist_ok=True)
            s3.download_file(BUCKET, key, str(dest))
            done += 1
        if i % 50 == 0 or i == len(objs):
            print(f"  {i}/{len(objs)} (받음 {done} · 건너뜀 {skipped})", flush=True)
    (root / META).write_text(json.dumps(types, ensure_ascii=False, indent=0), encoding="utf-8")
    total = sum(objs.values())
    print(f"끝 — 객체 {len(objs)}개 · {total / 2**20:.0f}MB")


def import_(root: pathlib.Path):
    types = json.loads((root / META).read_text(encoding="utf-8"))
    if BUCKET not in {b["Name"] for b in s3.list_buckets().get("Buckets", [])}:
        s3.create_bucket(Bucket=BUCKET)
        print(f"  버킷 {BUCKET} 을 만들었다")
    have = listing()
    done = skipped = 0
    keys = sorted(types)
    for i, key in enumerate(keys, 1):
        src = root / key
        if key.endswith("/"):  # 폴더 표시 — 빈 객체로 다시 만든다
            if key not in have:
                s3.put_object(Bucket=BUCKET, Key=key, Body=b"", ContentType=types[key])
                done += 1
            continue
        if not src.is_file():
            print(f"  🔴 파일 없음: {key}", file=sys.stderr)
            continue
        if have.get(key) == src.stat().st_size:
            skipped += 1
        else:
            s3.upload_file(str(src), BUCKET, key, ExtraArgs={"ContentType": types[key]})
            done += 1
        if i % 50 == 0 or i == len(keys):
            print(f"  {i}/{len(keys)} (올림 {done} · 건너뜀 {skipped})", flush=True)
    after = listing()
    missing = [k for k in keys if k not in after]
    print(f"끝 — 버킷에 {len(after)}개 · 빠진 것 {len(missing)}개")
    if missing:
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) != 3 or sys.argv[1] not in ("export", "import"):
        sys.exit(__doc__)
    path = pathlib.Path(sys.argv[2])
    export(path) if sys.argv[1] == "export" else import_(path)
