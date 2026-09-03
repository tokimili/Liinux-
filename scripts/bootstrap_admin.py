#!/usr/bin/env python3
"""
관리자 계정 부트스트랩 (멱등).

배포 파이프라인이 매 배포마다 호출해도 안전하다:
  - 관리자 계정이 없으면 ADMIN_INITIAL_PASSWORD 로 생성
  - 이미 있으면 role 만 admin 으로 보정하고 비밀번호는 건드리지 않는다
    (운영자가 바꾼 비밀번호를 배포가 되돌려놓으면 안 되기 때문)

사용:
    python3 scripts/bootstrap_admin.py
    python3 scripts/bootstrap_admin.py --reset-password   # 비밀번호 강제 재설정
"""
from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.config import get_config  # noqa: E402
from app.core import db  # noqa: E402
from app.core.security import hash_password  # noqa: E402


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--reset-password", action="store_true",
        help="기존 관리자 계정의 비밀번호를 ADMIN_INITIAL_PASSWORD 로 재설정",
    )
    args = parser.parse_args()

    cfg = get_config()
    username = cfg.ADMIN_USERNAME
    password = cfg.ADMIN_INITIAL_PASSWORD

    if len(password) < 10:
        print("[!] ADMIN_INITIAL_PASSWORD 가 10자 미만입니다. 더 강한 값을 설정하세요.",
              file=sys.stderr)
        return 2
    if password.startswith("CHANGE_ME"):
        print("[!] ADMIN_INITIAL_PASSWORD 가 예시값 그대로입니다. .env 를 수정하세요.",
              file=sys.stderr)
        return 2

    db.init_db(cfg)

    existing = db.query_one(
        "SELECT id, role FROM users WHERE username=%s", (username,)
    )

    if existing is None:
        uid = db.insert(
            "INSERT INTO users (username, email, password_hash, role) "
            "VALUES (%s,%s,%s,'admin')",
            (username, f"{username}@vmlab.local", hash_password(password)),
        )
        print(f"[+] 관리자 계정 생성 완료: {username} (id={uid})")
        print("[!] 첫 로그인 후 반드시 비밀번호를 변경하세요.")
        return 0

    changed = []
    if existing["role"] != "admin":
        db.execute("UPDATE users SET role='admin' WHERE id=%s", (existing["id"],))
        changed.append("role→admin")

    if args.reset_password:
        db.execute(
            "UPDATE users SET password_hash=%s WHERE id=%s",
            (hash_password(password), existing["id"]),
        )
        changed.append("password reset")

    if changed:
        print(f"[=] 관리자 계정 보정: {username} ({', '.join(changed)})")
    else:
        print(f"[=] 관리자 계정이 이미 존재합니다: {username} (변경 없음)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
