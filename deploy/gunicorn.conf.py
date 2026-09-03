"""
Gunicorn 설정.

VM(2 vCPU 기준)에서 안정적으로 돌아가도록 잡은 값이다.
worker class 를 gthread 로 쓰는 이유:
  - 이 앱은 CPU 연산이 아니라 DB I/O 대기가 대부분이다.
  - 접속 로그 writer 가 백그라운드 스레드로 동작하므로
    스레드를 지원하는 워커가 필요하다 (sync 워커는 요청당 블로킹).
"""
from __future__ import annotations

import multiprocessing
import os


def _int(key: str, default: int) -> int:
    try:
        return int(os.environ.get(key, default))
    except (TypeError, ValueError):
        return default


# ---------------------------------------------------------------- 바인딩
# 컨테이너 안에서 Nginx 만 접근하므로 0.0.0.0 이어도 외부에 직접 노출되지 않는다.
bind = os.environ.get("GUNICORN_BIND", "0.0.0.0:8000")

# ---------------------------------------------------------------- 워커
# 기본식: (2 × CPU) + 1. 단 VM 메모리를 고려해 상한을 둔다.
_default_workers = min((multiprocessing.cpu_count() * 2) + 1, 5)
workers = _int("GUNICORN_WORKERS", _default_workers)
worker_class = "gthread"
threads = _int("GUNICORN_THREADS", 4)

# 워커당 커넥션 풀을 잡으므로 DB max_connections 를 넘지 않도록 주의.
# workers(3) × DB_POOL_SIZE(5) = 15 커넥션 → MariaDB 기본값(151) 내에서 안전.

# ---------------------------------------------------------------- 타임아웃
timeout = _int("GUNICORN_TIMEOUT", 30)
graceful_timeout = _int("GUNICORN_GRACEFUL_TIMEOUT", 30)
# Nginx keepalive_timeout(65) 보다 길게 잡아 커넥션 조기 종료를 막는다.
keepalive = _int("GUNICORN_KEEPALIVE", 70)

# ---------------------------------------------------------------- 워커 재활용
# 메모리 누수가 누적되지 않도록 일정 요청 처리 후 워커를 교체한다.
# jitter 를 주어 모든 워커가 동시에 죽는 상황을 피한다.
max_requests = _int("GUNICORN_MAX_REQUESTS", 2000)
max_requests_jitter = _int("GUNICORN_MAX_REQUESTS_JITTER", 200)

# ---------------------------------------------------------------- 로깅
# 컨테이너 표준출력으로 보내 `docker compose logs` 로 확인한다.
accesslog = "-"
errorlog = "-"
loglevel = os.environ.get("GUNICORN_LOG_LEVEL", "info")

# 실제 클라이언트 IP를 남기기 위해 X-Forwarded-For 를 사용한다.
# (애플리케이션 접속 로그는 DB에 별도로 저장되지만, Gunicorn 로그도 맞춰둔다)
access_log_format = (
    '%({x-forwarded-for}i)s %(h)s "%(r)s" %(s)s %(b)s %(M)sms "%(a)s"'
)

# Nginx 가 앞에 있으므로 프록시 헤더를 신뢰한다.
# 컨테이너 네트워크 내부의 Nginx 만 접근 가능하므로 안전하다.
forwarded_allow_ips = os.environ.get("GUNICORN_FORWARDED_ALLOW_IPS", "*")

# ---------------------------------------------------------------- 프로세스
proc_name = "vmlab"
preload_app = False  # 워커별로 DB 커넥션 풀을 따로 만들기 위해 preload 하지 않는다


# ---------------------------------------------------------------- 훅

def on_starting(server):
    mode = os.environ.get("SECURITY_MODE", "secure")
    server.log.info(
        "Gunicorn 시작 | mode=%s workers=%s threads=%s version=%s",
        mode, workers, threads, os.environ.get("APP_VERSION", "dev"),
    )
    if mode == "vulnerable":
        server.log.warning(
            "SECURITY_MODE=vulnerable — 절대 인터넷에 노출하지 마십시오."
        )


def worker_int(worker):
    worker.log.info("워커 종료 신호 수신 (pid=%s)", worker.pid)
