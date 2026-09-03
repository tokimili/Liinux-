"""
접속 로그 미들웨어.

모든 요청을 access_logs 테이블에 적재하고, 위협 패턴이 탐지되면
security_events 에 경보를 남긴다. 관리자 대시보드가 이 데이터를 읽는다.

설계 원칙:
  - 로깅 실패가 서비스 장애로 번지지 않게 모든 예외를 흡수한다.
  - 비밀번호 등 민감 파라미터는 절대 저장하지 않는다 (마스킹).
  - 큐 + 백그라운드 워커로 적재해 응답 지연을 만들지 않는다.
"""
from __future__ import annotations

import atexit
import logging
import queue
import re
import threading
import time
from datetime import datetime

from flask import g, request, session

from app.core import db
from app.core.security import (
    detect_threats,
    get_client_ip,
    severity_from_score,
)

log = logging.getLogger(__name__)

# 로그에서 값을 지워야 하는 파라미터 이름
_SENSITIVE_KEYS = re.compile(
    r"(password|passwd|pwd|token|secret|api[_-]?key|authorization|csrf)",
    re.I,
)

_MAX_PATH = 512
_MAX_QS = 1024
_MAX_UA = 512
_MAX_REFERER = 512


def _mask_query_string(qs: str) -> str:
    """비밀번호 등이 쿼리스트링에 있으면 값을 가린다."""
    if not qs:
        return ""
    out = []
    for pair in qs.split("&"):
        if "=" not in pair:
            out.append(pair)
            continue
        key, _, value = pair.partition("=")
        if _SENSITIVE_KEYS.search(key):
            out.append(f"{key}=***MASKED***")
        else:
            out.append(f"{key}={value}")
    return "&".join(out)[:_MAX_QS]


def _mask_body(form: dict) -> str:
    """POST 본문에서 위협 탐지에 쓸 문자열을 만든다 (민감값 제외)."""
    if not form:
        return ""
    chunks = []
    for key, value in form.items():
        if _SENSITIVE_KEYS.search(key):
            continue
        chunks.append(f"{key}={value}")
    return "&".join(chunks)[:2000]


# ------------------------------------------------------------------ 비동기 적재

class _LogWriter:
    """
    백그라운드 스레드로 로그를 배치 INSERT 한다.
    Gunicorn 워커마다 1개씩 생성된다.
    """

    def __init__(self, max_queue: int = 2000, batch_size: int = 25, flush_interval: float = 1.0):
        self.q: queue.Queue = queue.Queue(maxsize=max_queue)
        self.batch_size = batch_size
        self.flush_interval = flush_interval
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self.dropped = 0

    def start(self) -> None:
        if self._thread and self._thread.is_alive():
            return
        self._thread = threading.Thread(target=self._run, name="access-log-writer", daemon=True)
        self._thread.start()
        atexit.register(self.stop)

    def stop(self) -> None:
        self._stop.set()
        if self._thread and self._thread.is_alive():
            self._thread.join(timeout=3)

    def put(self, row: tuple) -> None:
        try:
            self.q.put_nowait(row)
        except queue.Full:
            # 로그 폭주 시 서비스를 지키기 위해 버린다 (카운트만 유지)
            self.dropped += 1

    def _run(self) -> None:
        sql = (
            "INSERT INTO access_logs "
            "(ts, ip, method, path, query_string, status_code, duration_ms, bytes_sent, "
            " user_id, username, user_agent, referer, country, is_admin_path, "
            " threat_score, threat_tags) "
            "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)"
        )
        buffer: list[tuple] = []
        last_flush = time.monotonic()

        while not self._stop.is_set() or not self.q.empty():
            timeout = max(0.05, self.flush_interval - (time.monotonic() - last_flush))
            try:
                buffer.append(self.q.get(timeout=timeout))
            except queue.Empty:
                pass

            due = (
                len(buffer) >= self.batch_size
                or (buffer and time.monotonic() - last_flush >= self.flush_interval)
            )
            if due:
                try:
                    db.execute_many(sql, buffer)
                except Exception as exc:  # noqa: BLE001
                    log.warning("접속 로그 적재 실패 (%d건 유실): %s", len(buffer), exc)
                finally:
                    buffer.clear()
                    last_flush = time.monotonic()

        # 스레드 종료 직전 마지막 배치 flush.
        # 여기서 실패하면 로그가 유실되므로 조용히 넘기지 않고 반드시 남긴다.
        if buffer:
            try:
                db.execute_many(sql, buffer)
            except Exception as exc:  # noqa: BLE001
                log.error("종료 시점 접속 로그 flush 실패 (%d건 유실): %s", len(buffer), exc)


_writer = _LogWriter()


# ------------------------------------------------------------------ 훅 등록

def register_access_logging(app) -> None:
    cfg = app.config_obj
    exclude = tuple(cfg.LOG_EXCLUDE_PREFIXES)
    _writer.start()

    @app.before_request
    def _start_timer():
        g._req_started = time.perf_counter()
        g.client_ip = get_client_ip(cfg.TRUSTED_PROXY_COUNT)

    @app.after_request
    def _write_access_log(response):
        try:
            path = request.path or "/"
            if path.startswith(exclude):
                return response

            started = getattr(g, "_req_started", None)
            duration_ms = int((time.perf_counter() - started) * 1000) if started else 0

            qs = _mask_query_string(request.query_string.decode("utf-8", "replace"))
            body_probe = ""
            if request.method in ("POST", "PUT", "PATCH"):
                try:
                    body_probe = _mask_body(request.form.to_dict())
                except Exception:
                    body_probe = ""

            ua = (request.headers.get("User-Agent") or "")[:_MAX_UA]
            referer = (request.headers.get("Referer") or "")[:_MAX_REFERER]

            score, tags = detect_threats(
                path=path, query_string=qs, body=body_probe, user_agent=ua
            )

            ip = getattr(g, "client_ip", None) or "0.0.0.0"
            uid = session.get("user_id")
            uname = session.get("username")
            country = (request.headers.get("CF-IPCountry") or "")[:2] or None
            is_admin_path = 1 if path.startswith("/admin") else 0

            _writer.put((
                datetime.now(),
                ip,
                request.method,
                path[:_MAX_PATH],
                qs or None,
                int(response.status_code),
                duration_ms,
                int(response.calculate_content_length() or 0),
                uid,
                uname,
                ua or None,
                referer or None,
                country,
                is_admin_path,
                score,
                ",".join(tags) if tags else None,
            ))

            # 유의미한 위협은 즉시 경보 테이블에 기록 (동기 — 건수가 적음)
            if score >= 35:
                _record_security_event(score, tags, ip, path, qs, body_probe)

        except Exception as exc:  # noqa: BLE001
            log.debug("접속 로그 처리 중 예외 무시: %s", exc)

        return response


def _record_security_event(
    score: int, tags: list[str], ip: str, path: str, qs: str, body: str
) -> None:
    try:
        primary = next(
            (t for t in tags if t in ("sqli", "xss", "traversal", "cmdi", "ssrf", "ssti", "deser")),
            tags[0] if tags else "suspicious",
        )
        detail = f"tags={','.join(tags)} score={score}"
        if qs:
            detail += f"\nquery={qs[:400]}"
        if body:
            detail += f"\nbody={body[:400]}"

        db.insert(
            "INSERT INTO security_events (severity, event_type, ip, path, detail) "
            "VALUES (%s,%s,%s,%s,%s)",
            (severity_from_score(score), f"{primary}_attempt", ip, path[:512], detail),
        )
    except Exception as exc:  # noqa: BLE001
        log.debug("보안 이벤트 기록 실패: %s", exc)


def writer_stats() -> dict:
    return {
        "queue_size": _writer.q.qsize(),
        "dropped": _writer.dropped,
        "alive": bool(_writer._thread and _writer._thread.is_alive()),
    }
