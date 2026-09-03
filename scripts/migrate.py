#!/usr/bin/env python3
"""
데이터베이스 마이그레이션 러너 (멱등).

migrations/ 디렉터리의 `NNNN_이름.sql` 파일을 버전 순서대로 적용하고,
적용된 버전을 schema_migrations 테이블에 기록한다.
이미 적용된 버전은 건너뛰므로 배포마다 안전하게 호출할 수 있다.

사용:
    python3 scripts/migrate.py
    python3 scripts/migrate.py --status   # 적용 상태만 확인
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import pymysql  # noqa: E402

from app.config import get_config  # noqa: E402

MIGRATIONS_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "migrations"
)
_FILE_RE = re.compile(r"^(\d{4})_.+\.sql$")

_BOOTSTRAP = """
CREATE TABLE IF NOT EXISTS schema_migrations (
  version    VARCHAR(20) NOT NULL,
  applied_at DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (version)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
"""


def connect(cfg, retries: int = 30, delay: float = 2.0):
    """DB 컨테이너가 아직 준비되지 않았을 수 있으므로 재시도한다."""
    last = None
    for attempt in range(1, retries + 1):
        try:
            return pymysql.connect(
                host=cfg.DB_HOST, port=cfg.DB_PORT,
                user=cfg.DB_USER, password=cfg.DB_PASSWORD,
                database=cfg.DB_NAME, charset="utf8mb4",
                autocommit=False,
            )
        except pymysql.err.OperationalError as exc:
            last = exc
            print(f"    DB 연결 대기 {attempt}/{retries} … ({exc.args[0]})")
            time.sleep(delay)
    raise SystemExit(f"[!] DB 연결 실패: {last}")


def discover() -> list[tuple[str, str]]:
    if not os.path.isdir(MIGRATIONS_DIR):
        return []
    found = []
    for name in sorted(os.listdir(MIGRATIONS_DIR)):
        m = _FILE_RE.match(name)
        if m:
            found.append((m.group(1), os.path.join(MIGRATIONS_DIR, name)))
    return found


def split_statements(sql: str) -> list[str]:
    """
    세미콜론 단위로 문장을 나눈다.
    문자열 리터럴 안의 세미콜론과 -- 주석을 존중한다.
    (스키마 파일 수준에서 충분한 단순 파서. DELIMITER 구문은 쓰지 않는다.)
    """
    statements, buf = [], []
    in_single = in_double = in_line_comment = False
    i = 0
    while i < len(sql):
        ch = sql[i]
        nxt = sql[i + 1] if i + 1 < len(sql) else ""

        if in_line_comment:
            if ch == "\n":
                in_line_comment = False
                buf.append(ch)
            i += 1
            continue

        if not in_single and not in_double:
            if ch == "-" and nxt == "-":
                in_line_comment = True
                i += 2
                continue
            if ch == "#":
                in_line_comment = True
                i += 1
                continue
            if ch == ";":
                stmt = "".join(buf).strip()
                if stmt:
                    statements.append(stmt)
                buf = []
                i += 1
                continue

        if ch == "'" and not in_double:
            in_single = not in_single
        elif ch == '"' and not in_single:
            in_double = not in_double
        elif ch == "\\" and (in_single or in_double):
            buf.append(ch)
            if nxt:
                buf.append(nxt)
            i += 2
            continue

        buf.append(ch)
        i += 1

    tail = "".join(buf).strip()
    if tail:
        statements.append(tail)
    return statements


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--status", action="store_true", help="적용 상태만 출력")
    args = parser.parse_args()

    cfg = get_config()
    print(f"[i] 대상 DB: {cfg.DB_USER}@{cfg.DB_HOST}:{cfg.DB_PORT}/{cfg.DB_NAME}")

    conn = connect(cfg)
    try:
        with conn.cursor() as cur:
            cur.execute(_BOOTSTRAP)
            conn.commit()
            cur.execute("SELECT version FROM schema_migrations")
            applied = {row[0] for row in cur.fetchall()}

        migrations = discover()
        if not migrations:
            print("[!] migrations/ 에 적용할 파일이 없습니다.")
            return 1

        if args.status:
            for version, path in migrations:
                mark = "적용됨" if version in applied else "대기"
                print(f"    [{mark:>4}] {version}  {os.path.basename(path)}")
            return 0

        pending = [(v, p) for v, p in migrations if v not in applied]
        if not pending:
            print(f"[=] 모든 마이그레이션이 이미 적용되어 있습니다. (총 {len(applied)}건)")
            return 0

        for version, path in pending:
            print(f"[+] 적용 중: {version}  {os.path.basename(path)}")
            with open(path, encoding="utf-8") as fh:
                sql = fh.read()

            statements = split_statements(sql)
            try:
                with conn.cursor() as cur:
                    for stmt in statements:
                        cur.execute(stmt)
                    cur.execute(
                        "INSERT IGNORE INTO schema_migrations (version) VALUES (%s)",
                        (version,),
                    )
                conn.commit()
            except Exception as exc:
                conn.rollback()
                print(f"[!] {version} 적용 실패 → 롤백: {exc}", file=sys.stderr)
                return 1
            print(f"    완료 ({len(statements)} 문장)")

        print(f"[✓] 마이그레이션 {len(pending)}건 적용 완료")
        return 0
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
