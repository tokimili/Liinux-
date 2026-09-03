#!/usr/bin/env python3
"""
배포 이력을 deployments 테이블에 기록한다.

관리자 대시보드 /admin/deployments 화면이 이 데이터를 읽는다 —
"언제 어떤 커밋이 누구에 의해 배포됐는가"가 감사 추적의 시작점이다.

CI/CD 파이프라인(deploy.yml)이 배포 성공/실패 직후 호출한다.
기록 실패가 배포 자체를 실패시키면 안 되므로 exit code 는 항상 0 이지만,
실패 사유는 stderr 로 남긴다.

사용법:
    python3 scripts/record_deploy.py \
        --commit abc123... --ref main --version v42 \
        --actor github-actions --mode secure --note "배포 성공"
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.config import Config  # noqa: E402
from app.core import db  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser(description="배포 이력 기록")
    parser.add_argument("--commit", default=os.environ.get("GIT_COMMIT", ""),
                        help="git 커밋 SHA (40자)")
    parser.add_argument("--ref", default="main", help="브랜치/태그 이름")
    parser.add_argument("--version", default=os.environ.get("APP_VERSION", "dev"),
                        help="앱 버전")
    parser.add_argument("--actor", default="manual", help="배포 실행자")
    parser.add_argument("--mode", default=os.environ.get("SECURITY_MODE", "secure"),
                        help="배포된 보안 모드")
    parser.add_argument("--note", default="", help="비고 (성공/실패/롤백 등)")
    args = parser.parse_args()

    cfg = Config()
    try:
        db.init_db(cfg)
    except Exception as exc:  # noqa: BLE001
        print(f"[record_deploy] DB 연결 실패 — 기록을 건너뜁니다: {exc}", file=sys.stderr)
        return 0

    # 스키마 컬럼:
    #   deployed_at / git_commit(40) / git_ref(120) / app_version(40)
    #   actor(80) / mode(20) / note(255)
    try:
        row_id = db.insert(
            "INSERT INTO deployments "
            "(git_commit, git_ref, app_version, actor, mode, note) "
            "VALUES (%s,%s,%s,%s,%s,%s)",
            (
                (args.commit or "")[:40],
                (args.ref or "")[:120],
                (args.version or "")[:40],
                (args.actor or "")[:80],
                (args.mode or "secure")[:20],
                (args.note or "")[:255],
            ),
        )
    except Exception as exc:  # noqa: BLE001
        print(f"[record_deploy] 기록 실패: {exc}", file=sys.stderr)
        return 0

    print(
        f"[record_deploy] 기록 완료 (id={row_id}) "
        f"commit={args.commit[:7]} version={args.version} "
        f"mode={args.mode} actor={args.actor}"
    )

    # 운영 안전장치: vulnerable 모드가 기록되면 경고를 크게 남긴다.
    if args.mode != "secure":
        print(
            f"[record_deploy][WARNING] ⚠️ secure 가 아닌 모드가 배포됐습니다: {args.mode}\n"
            f"                         이 빌드는 절대 외부에 노출하지 마십시오.",
            file=sys.stderr,
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
