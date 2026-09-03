"""
데이터베이스 접근 레이어 (MySQL / MariaDB).

- 커넥션 풀을 사용해 요청마다 접속 비용을 없앤다.
- 기본 API는 전부 파라미터 바인딩(%s)을 강제한다.
  => SQL Injection 방어의 1차 방어선이 여기다.
- 취약점 실습용 raw 실행은 execute_raw()로 별도 격리하고,
  vulnerable 모드가 아니면 호출 자체를 거부한다.
"""
from __future__ import annotations

import logging
import time
from contextlib import contextmanager
from typing import Any, Iterable, Sequence

import pymysql
from pymysql.cursors import DictCursor
from dbutils.pooled_db import PooledDB

log = logging.getLogger(__name__)

_pool: PooledDB | None = None
_cfg: Any = None


def init_db(config) -> None:
    """앱 팩토리에서 1회 호출. DB가 아직 안 떴을 수 있으므로 재시도한다."""
    global _pool, _cfg
    _cfg = config

    last_err = None
    for attempt in range(1, 31):
        try:
            _pool = PooledDB(
                creator=pymysql,
                maxconnections=config.DB_POOL_SIZE,
                mincached=1,
                blocking=True,
                ping=1,  # 사용 전 커넥션 생존 확인
                host=config.DB_HOST,
                port=config.DB_PORT,
                user=config.DB_USER,
                password=config.DB_PASSWORD,
                database=config.DB_NAME,
                charset="utf8mb4",
                cursorclass=DictCursor,
                autocommit=True,
            )
            with get_cursor() as cur:
                cur.execute("SELECT 1")
            log.info("DB 커넥션 풀 준비 완료 (시도 %d회)", attempt)
            return
        except Exception as exc:  # noqa: BLE001
            last_err = exc
            log.warning("DB 접속 대기 중... (%d/30) %s", attempt, exc)
            time.sleep(2)

    raise RuntimeError(f"DB 접속 실패: {last_err}")


@contextmanager
def get_cursor(commit: bool = False):
    if _pool is None:
        raise RuntimeError("init_db()가 먼저 호출되어야 합니다.")
    conn = _pool.connection()
    cur = conn.cursor()
    try:
        yield cur
        if commit:
            conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        cur.close()
        conn.close()  # 풀로 반환


# ---------------------------------------------------------------- 안전 API

def query_all(sql: str, params: Sequence | None = None) -> list[dict]:
    with get_cursor() as cur:
        cur.execute(sql, params or ())
        return list(cur.fetchall())


def query_one(sql: str, params: Sequence | None = None) -> dict | None:
    with get_cursor() as cur:
        cur.execute(sql, params or ())
        return cur.fetchone()


def query_scalar(sql: str, params: Sequence | None = None, default=0):
    row = query_one(sql, params)
    if not row:
        return default
    return next(iter(row.values()), default)


def execute(sql: str, params: Sequence | None = None) -> int:
    """INSERT/UPDATE/DELETE. 영향받은 행 수를 반환."""
    with get_cursor(commit=True) as cur:
        cur.execute(sql, params or ())
        return cur.rowcount


def insert(sql: str, params: Sequence | None = None) -> int:
    """INSERT 후 생성된 PK를 반환."""
    with get_cursor(commit=True) as cur:
        cur.execute(sql, params or ())
        return cur.lastrowid


def execute_many(sql: str, seq_params: Iterable[Sequence]) -> int:
    with get_cursor(commit=True) as cur:
        cur.executemany(sql, list(seq_params))
        return cur.rowcount


# ------------------------------------------------- 취약점 실습 전용 (격리)

def execute_raw(sql: str) -> list[dict]:
    """
    ⚠️ 문자열로 조립된 SQL을 그대로 실행한다 (SQL Injection 재현용).

    vulnerable 모드가 아니면 예외를 던져서 secure 배포본에서는
    이 경로가 절대 살아나지 못하게 한다.
    """
    if _cfg is None or getattr(_cfg, "SECURITY_MODE", "secure") != "vulnerable":
        raise PermissionError(
            "execute_raw()는 SECURITY_MODE=vulnerable 에서만 사용 가능합니다."
        )
    log.warning("[VULN] raw SQL 실행: %s", sql)
    with get_cursor() as cur:
        cur.execute(sql)
        try:
            return list(cur.fetchall())
        except Exception:
            return []


def healthcheck() -> dict:
    """/healthz 및 대시보드용 DB 상태."""
    started = time.perf_counter()
    try:
        query_one("SELECT 1 AS ok")
        return {
            "ok": True,
            "latency_ms": round((time.perf_counter() - started) * 1000, 2),
        }
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": str(exc)}
