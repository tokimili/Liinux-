#!/usr/bin/env bash
# ==========================================================================
# 무중단에 가까운 교체 + 헬스체크 게이트 + 자동 롤백.
#
# 핵심 원칙: "배포가 성공했다"의 기준을 컨테이너 기동이 아니라
#            /healthz 200 응답으로 둔다. 컨테이너는 떴지만 DB 연결이
#            깨진 상태로 방치되는 사고가 가장 흔하다.
#
# 실패 시 이전 이미지로 되돌리고 exit 1 → 워크플로가 실패로 표시된다.
# ==========================================================================
set -Eeuo pipefail

HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:8080/healthz}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-90}"
ROLLBACK_TAG="vmlab-web:rollback"

log()  { printf '[deploy] %s\n' "$*"; }
fail() { printf '[deploy][ERROR] %s\n' "$*" >&2; }

# ---------------------------------------------------------------- 롤백 준비
# 현재 돌고 있는 이미지를 태그로 고정해둔다.
# compose 가 새 이미지를 같은 이름으로 덮어쓰기 때문에, ID 만으로는
# prune 후 사라질 수 있다.
PREV_IMAGE="$(docker compose images -q web 2>/dev/null | head -1 || true)"
if [[ -n "${PREV_IMAGE}" ]]; then
    docker tag "${PREV_IMAGE}" "${ROLLBACK_TAG}"
    log "롤백 지점 저장: ${PREV_IMAGE:0:12} → ${ROLLBACK_TAG}"
else
    log "이전 배포 없음 (최초 배포) — 롤백 불가, 실패 시 수동 확인 필요"
fi

# ---------------------------------------------------------------- 교체
log "컨테이너 교체 시작"
docker compose up -d --no-deps --force-recreate web nginx

# ---------------------------------------------------------------- 헬스체크 게이트
log "헬스체크 대기 (최대 ${HEALTH_TIMEOUT}초): ${HEALTH_URL}"
healthy=0
for ((i = 1; i <= HEALTH_TIMEOUT; i++)); do
    if curl -fsS --max-time 3 "${HEALTH_URL}" -o /tmp/deploy_health.json 2>/dev/null; then
        # 200 만으로는 부족하다. status 필드까지 확인한다.
        if grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' /tmp/deploy_health.json; then
            log "헬스체크 통과 (${i}초)"
            cat /tmp/deploy_health.json
            echo ""
            healthy=1
            break
        fi
        log "응답은 왔지만 status != ok — 재시도 (${i}/${HEALTH_TIMEOUT})"
    fi
    sleep 1
done

# ---------------------------------------------------------------- 실패 → 롤백
if [[ "${healthy}" -ne 1 ]]; then
    fail "헬스체크 실패 — 롤백을 시작합니다"

    echo "----- web 로그 (최근 80줄) -----" >&2
    docker compose logs --tail=80 --no-color web >&2 || true
    echo "----- 컨테이너 상태 -----" >&2
    docker compose ps >&2 || true

    if docker image inspect "${ROLLBACK_TAG}" >/dev/null 2>&1; then
        fail "이전 이미지로 되돌립니다"
        # compose 가 참조하는 이미지 이름으로 되돌린 뒤 재기동한다
        IMAGE_NAME="$(docker compose config --images web | head -1)"
        docker tag "${ROLLBACK_TAG}" "${IMAGE_NAME}"
        docker compose up -d --no-deps --force-recreate web nginx

        for ((i = 1; i <= 60; i++)); do
            if curl -fsS --max-time 3 "${HEALTH_URL}" >/dev/null 2>&1; then
                fail "롤백 완료 — 이전 버전으로 서비스 중 (${i}초)"
                exit 1
            fi
            sleep 1
        done
        fail "롤백 후에도 헬스체크 실패 — 수동 개입이 필요합니다"
    else
        fail "롤백할 이전 이미지가 없습니다 (최초 배포) — 수동 개입 필요"
    fi
    exit 1
fi

# ---------------------------------------------------------------- 성공
# 외부 노출 전 최후 확인: secure 모드가 아니면 즉시 중단한다.
MODE="$(python3 -c "import json;print(json.load(open('/tmp/deploy_health.json'))['mode'])")"
if [[ "${MODE}" != "secure" ]]; then
    fail "배포본이 secure 모드가 아닙니다 (mode=${MODE}) — 즉시 중단"
    docker compose stop nginx cloudflared quicktunnel 2>/dev/null || true
    exit 1
fi

# ---------------------------------------------------------------- Quick Tunnel 복구
# Quick Tunnel(도메인 없이 쓰는 임시 터널)은 profile 밖에 있어서
# 위의 `docker compose up` 이 건드리지 않는다. 그 결과 배포가 성공해도
# 외부 접속만 조용히 끊긴 상태가 된다 — "배포했더니 주소가 안 열린다"의 원인.
# 그래서 배포 전에 떠 있었다면 다시 올려준다.
#
# secure 검증 **뒤에** 두는 것이 중요하다. 순서가 바뀌면
# 취약 빌드가 잠깐이라도 공개될 수 있다.
if docker ps -a --format '{{.Names}}' | grep -qx vmlab-quicktunnel; then
    if docker ps --format '{{.Names}}' | grep -qx vmlab-quicktunnel; then
        log "Quick Tunnel 실행 중 — 유지"
    else
        log "Quick Tunnel 이 중단되어 있어 재기동합니다"
        docker compose --profile quick up -d quicktunnel 2>/dev/null || \
            fail "Quick Tunnel 재기동 실패 — ./scripts/setup_tunnel.sh --quick 로 다시 켜세요"
    fi
    # 주소는 재기동 시 바뀌므로 배포 로그에 남겨준다.
    sleep 5
    NEWURL="$(docker logs vmlab-quicktunnel 2>&1 \
               | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
    [[ -n "${NEWURL}" ]] && log "외부 접속 주소: ${NEWURL}"
fi

log "배포 성공 (mode=${MODE})"
exit 0
