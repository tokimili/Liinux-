# ==========================================================================
# 멀티스테이지 빌드
#   builder : 의존성을 wheel 로 빌드 (컴파일러 포함)
#   runtime : 실행에 필요한 것만 담은 슬림 이미지 (컴파일러 없음)
#
# 컴파일러를 최종 이미지에 남기지 않는 것은 공격 표면 축소의 기본이다.
# 침투에 성공한 공격자가 컨테이너 안에서 도구를 빌드하기 어려워진다.
# ==========================================================================

# -------------------------------------------------------------- builder
FROM python:3.12-slim-bookworm AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# cryptography / PyMySQL 빌드에 필요한 최소 패키지
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        libffi-dev \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY requirements.txt .
RUN pip wheel --wheel-dir=/wheels -r requirements.txt


# -------------------------------------------------------------- runtime
FROM python:3.12-slim-bookworm AS runtime

# PYTHONDONTWRITEBYTECODE : .pyc 를 남기지 않아 이미지/볼륨을 깨끗하게 유지
# PYTHONUNBUFFERED       : 로그가 즉시 stdout 으로 나가도록 (docker logs 실시간 확인)
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PYTHONPATH=/app

# 헬스체크에 curl 이 필요하다 (compose healthcheck 가 사용)
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
    && rm -rf /var/lib/apt/lists/*

# ---- 비루트 사용자 생성 ----
# 컨테이너를 root 로 돌리면 컨테이너 탈출 시 피해가 커진다.
# UID/GID 를 10001 로 고정해 호스트 볼륨 권한을 예측 가능하게 만든다.
RUN groupadd --gid 10001 vmlab \
    && useradd --uid 10001 --gid 10001 --create-home --shell /usr/sbin/nologin vmlab

WORKDIR /app

# 의존성 먼저 설치 → 소스만 바뀔 때 이 레이어를 재사용해 빌드가 빨라진다
COPY --from=builder /wheels /wheels
COPY requirements.txt .
RUN pip install --no-index --find-links=/wheels -r requirements.txt \
    && rm -rf /wheels

# ---- 애플리케이션 소스 ----
COPY app/ ./app/
COPY migrations/ ./migrations/
COPY scripts/ ./scripts/
COPY deploy/gunicorn.conf.py ./deploy/gunicorn.conf.py
COPY wsgi.py .

# 업로드 디렉터리 (docker-compose 에서 볼륨으로 덮어씀)
RUN mkdir -p /app/uploads && chown -R vmlab:vmlab /app

# ---- 빌드 메타 (CI 가 --build-arg 로 주입) ----
ARG APP_VERSION=dev
ARG GIT_COMMIT=unknown
ARG BUILD_DATE=""
ENV APP_VERSION=${APP_VERSION} \
    GIT_COMMIT=${GIT_COMMIT} \
    DEPLOYED_AT=${BUILD_DATE}

# OCI 표준 라벨 — 이미지만 보고 어느 커밋에서 나왔는지 추적할 수 있다
LABEL org.opencontainers.image.title="vmlab-web" \
      org.opencontainers.image.description="VM Security Lab web application" \
      org.opencontainers.image.version="${APP_VERSION}" \
      org.opencontainers.image.revision="${GIT_COMMIT}" \
      org.opencontainers.image.created="${BUILD_DATE}"

USER vmlab

EXPOSE 8000

# 컨테이너 자체 헬스체크.
# compose 의 depends_on: condition: service_healthy 와 배포 게이트가 이 값을 본다.
HEALTHCHECK --interval=15s --timeout=5s --start-period=40s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8000/healthz || exit 1

CMD ["gunicorn", "--config", "deploy/gunicorn.conf.py", "wsgi:app"]
