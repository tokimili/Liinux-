#!/usr/bin/env bash
# ==========================================================================
# 자기복구 (self-healing) — main 브랜치를 "진실"로 삼아 VM 상태를 맞춘다.
#
# ★ 이 스크립트가 필요한 이유
#   CI/CD(deploy.yml)는 **push 라는 이벤트가 있을 때만** 동작한다.
#   그래서 다음 상황들은 CI/CD 가 아무리 잘 돌아도 자동으로 복구되지 않고,
#   사람이 VM 에 접속해서 손으로 고쳐야 했다:
#
#     1) VM 재부팅 / 정전 후
#        → 컨테이너는 restart: unless-stopped 로 살아나지만
#          Quick Tunnel 은 profile 밖이라 죽은 채로 남는다 → 외부 접속 끊김
#     2) Quick Tunnel 이 Cloudflare 쪽 사정으로 끊김
#        → 주소가 죽었는데 아무도 모른다 (실제로 이 상태가 발생했다)
#     3) push 는 성공했는데 배포가 실패해서 VM 만 옛 커밋에 남음
#        → main 과 실제 서비스가 어긋난 채 방치 (드리프트)
#     4) 러너가 죽어서 배포 자체가 트리거되지 않음
#
#   → systemd timer 가 이 스크립트를 주기적으로 돌려서
#     "main 브랜치 기준으로 자동으로 맞춰지는" 상태를 만든다.
#
# ★ 설계 원칙
#   - 멱등(idempotent): 이미 정상이면 아무것도 하지 않고 조용히 끝난다.
#     타이머로 1분마다 도는 물건이라, 매번 뭔가를 재기동하면 안 된다.
#   - secure 강제: 어떤 경로로도 vulnerable 을 외부에 노출하지 않는다.
#   - 배포 자체는 GitHub Actions 에 맡긴다. 이 스크립트는 **감지와 복구**만
#     한다. 여기서 빌드까지 하면 CI 게이트(테스트 통과)를 우회하게 된다.
#
# 사용:
#   ./scripts/autoheal.sh            # 점검 + 필요한 것만 복구
#   ./scripts/autoheal.sh --dry-run  # 무엇을 할지 보기만 (아무것도 안 바꿈)
#   ./scripts/autoheal.sh --once     # 타이머 없이 1회 (기본과 동일, 가독성용)
# ==========================================================================
set -Eeuo pipefail

# ------------------------------------------------------------------ 설정
HEALTH_URL="${HEALTH_URL:-http://127.0.0.1:8080/healthz}"
COMPOSE_PROJECT="${COMPOSE_PROJECT_NAME:-vmlab}"
STATE_DIR="${STATE_DIR:-/var/lib/vmlab}"
URL_FILE="${STATE_DIR}/tunnel_url"
DRY_RUN=0

for arg in "$@"; do
    case "${arg}" in
        --dry-run) DRY_RUN=1 ;;
        --once)    : ;;   # 기본 동작
        -h|--help)
            sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) printf '알 수 없는 옵션: %s\n' "${arg}" >&2; exit 2 ;;
    esac
done

# ------------------------------------------------------------------ 로깅
# journald 가 수집하므로 타임스탬프는 붙이지 않는다 (중복이 된다).
# 단, 터미널에서 직접 돌릴 때는 시간이 보이는 편이 낫다.
if [[ -t 1 ]]; then
    log()  { printf '[autoheal %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
else
    log()  { printf '[autoheal] %s\n' "$*"; }
fi
warn() { log "WARN: $*" >&2; }
act()  {
    if (( DRY_RUN )); then
        log "DRY-RUN: $*"
        return 1   # 호출부가 '실행 안 함'을 알 수 있게 한다
    fi
    log "조치: $*"
    return 0
}

# ------------------------------------------------------------------ docker 호출 방식
# 사용자가 docker 그룹에 있어도 재로그인 전이면 권한이 없다.
# systemd 로 root 실행될 때는 sudo 가 필요 없다. 둘 다 대응한다.
DOCKER=(docker)
if ! docker info >/dev/null 2>&1; then
    if sudo -n docker info >/dev/null 2>&1; then
        DOCKER=(sudo -n docker)
    else
        log "docker 를 실행할 수 없습니다 (권한 또는 데몬 미기동)"
        exit 1
    fi
fi
dk()  { "${DOCKER[@]}" "$@"; }
# ★ -p 고정: compose 는 프로젝트명을 디렉터리 이름에서 유추한다.
#   그대로 두면 실행 중인 vmlab 스택을 못 보고 새로 만들려 들어
#   container_name 충돌(vmlab-db is already in use)이 난다.
dkc() { "${DOCKER[@]}" compose -p "${COMPOSE_PROJECT}" "$@"; }

# ------------------------------------------------------------------ 작업 디렉터리
# .env 와 docker-compose.yml 은 러너 작업 디렉터리에 있다.
# (git clone 한 ~/Liinux- 가 아니다 — 이 함정을 여러 번 겪었다)
find_workdir() {
    local base cand listing
    if [[ -f "${PWD}/docker-compose.yml" && -f "${PWD}/.env" ]]; then
        printf '%s' "${PWD}"; return 0
    fi
    for base in /opt/actions-runner "${HOME:-/root}/actions-runner" /home/*/actions-runner; do
        [[ -d "${base}/_work" ]] || sudo -n test -d "${base}/_work" 2>/dev/null || continue
        listing="$(ls -d "${base}"/_work/*/* 2>/dev/null || true)"
        [[ -n "${listing}" ]] || listing="$(sudo -n ls -d "${base}"/_work/*/* 2>/dev/null || true)"
        [[ -n "${listing}" ]] || continue
        while IFS= read -r cand; do
            [[ -n "${cand}" ]] || continue
            [[ -f "${cand}/docker-compose.yml" ]] || continue
            [[ -f "${cand}/.env" ]] || sudo -n test -f "${cand}/.env" 2>/dev/null || continue
            printf '%s' "${cand}"; return 0
        done <<< "${listing}"
    done
    return 1
}

WORKDIR="$(find_workdir || true)"
if [[ -z "${WORKDIR}" ]]; then
    log "작업 디렉터리(.env + docker-compose.yml)를 찾지 못했습니다 — 배포를 한 번 성공시키세요"
    exit 1
fi
cd "${WORKDIR}"

# ------------------------------------------------------------------ 상태 저장 위치
if [[ ! -d "${STATE_DIR}" ]]; then
    mkdir -p "${STATE_DIR}" 2>/dev/null || sudo -n mkdir -p "${STATE_DIR}" 2>/dev/null || {
        STATE_DIR="${WORKDIR}/.autoheal"
        URL_FILE="${STATE_DIR}/tunnel_url"
        mkdir -p "${STATE_DIR}"
    }
fi

# ------------------------------------------------------------------ .env 읽기
env_get() {
    local key="$1" line
    if [[ -r .env ]]; then line="$(grep -E "^${key}=" .env 2>/dev/null | tail -1 || true)"
    else                   line="$(sudo -n cat .env 2>/dev/null | grep -E "^${key}=" | tail -1 || true)"
    fi
    printf '%s' "${line#*=}"
}

CHANGED=0   # 뭔가 고쳤는지 (요약 출력용)

# ==========================================================================
# 1. 보안 게이트 — vulnerable 이면 외부 노출을 오히려 '끈다'
#
#    자기복구 스크립트가 취약 빌드를 되살려 인터넷에 내보내면
#    자동화가 사고를 자동화하는 꼴이 된다. 여기서 먼저 막는다.
# ==========================================================================
MODE_ENV="$(env_get SECURITY_MODE)"
if [[ "${MODE_ENV}" == "vulnerable" ]]; then
    warn "SECURITY_MODE=vulnerable — 외부 노출을 차단합니다"
    for c in vmlab-quicktunnel vmlab-tunnel; do
        if dk ps --format '{{.Names}}' 2>/dev/null | grep -qx "${c}"; then
            act "취약 모드이므로 ${c} 중지" && dk stop "${c}" >/dev/null 2>&1 || true
            CHANGED=1
        fi
    done
    log "취약 모드에서는 앱 복구도 하지 않습니다 (실습 중일 수 있음)"
    exit 0
fi

# ==========================================================================
# 2. 앱 스택 — 죽어 있으면 되살린다
#
#    restart: unless-stopped 가 대부분 처리하지만,
#    `docker compose stop` 으로 명시적으로 멈춘 뒤 재부팅한 경우나
#    이미지 교체 중 실패로 컨테이너가 없는 경우는 살아나지 않는다.
# ==========================================================================
app_ok() { curl -fsS --max-time 5 "${HEALTH_URL}" -o /tmp/autoheal_health.json 2>/dev/null; }

if app_ok && grep -q '"status"[[:space:]]*:[[:space:]]*"ok"' /tmp/autoheal_health.json; then
    log "앱 정상"
else
    warn "앱이 응답하지 않습니다 (${HEALTH_URL})"
    if act "앱 스택 기동 (db/web/nginx)"; then
        dkc up -d db web nginx >/dev/null 2>&1 || warn "스택 기동 명령 실패"
        CHANGED=1
        # 기동 직후엔 아직 안 뜬다. 최대 60초 기다린다.
        for _ in $(seq 1 60); do
            app_ok && break
            sleep 1
        done
        if app_ok; then log "앱 복구됨"; else
            warn "앱 복구 실패 — 수동 확인 필요:  ${DOCKER[*]} compose -p ${COMPOSE_PROJECT} logs --tail=50 web"
            exit 1
        fi
    fi
fi

# 여기까지 왔으면 /tmp/autoheal_health.json 은 최신이다.
LIVE_MODE="$(python3 -c "import json;print(json.load(open('/tmp/autoheal_health.json')).get('mode',''))" 2>/dev/null || echo "")"
LIVE_COMMIT="$(python3 -c "import json;print(json.load(open('/tmp/autoheal_health.json')).get('commit',''))" 2>/dev/null || echo "")"

# 실행 중인 것이 secure 인지 최종 확인 (.env 와 실제가 다를 수 있다)
if [[ "${LIVE_MODE}" != "secure" ]]; then
    warn "실행 중인 앱이 secure 가 아닙니다 (mode=${LIVE_MODE}) — 터널을 올리지 않습니다"
    for c in vmlab-quicktunnel vmlab-tunnel; do
        dk ps --format '{{.Names}}' 2>/dev/null | grep -qx "${c}" && {
            act "${c} 중지" && dk stop "${c}" >/dev/null 2>&1 || true; CHANGED=1; }
    done
    exit 1
fi

# ==========================================================================
# 3. 외부 노출 터널 — 이게 실제로 끊겼던 지점이다
#
#    Quick Tunnel 은 profiles: ["quick"] 이라 일반 `compose up` 이 건드리지
#    않는다. 그래서 배포는 성공했는데 외부 주소만 조용히 죽는 일이 생긴다.
#    "웹은 떠 있는데 밖에서 안 열린다" 의 정체.
# ==========================================================================
TOKEN="$(env_get TUNNEL_TOKEN)"

tunnel_running() { dk ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }

if [[ -n "${TOKEN}" ]]; then
    # ---- Named Tunnel (고정 주소) ----
    if tunnel_running vmlab-tunnel; then
        log "Named Tunnel 정상"
    else
        warn "Named Tunnel 중단 상태"
        if act "Named Tunnel 재기동"; then
            dkc --profile tunnel up -d --no-deps cloudflared >/dev/null 2>&1 \
                && log "Named Tunnel 복구됨" || warn "Named Tunnel 재기동 실패"
            CHANGED=1
        fi
    fi
else
    # ---- Quick Tunnel (임시 주소) ----
    # 컨테이너가 '존재는 하는데 멈춰 있는' 경우와 '아예 없는' 경우를 구분한다.
    # 존재한 적이 있다 = 사용자가 외부 공개를 원했다는 뜻이므로 되살린다.
    # 한 번도 켠 적이 없으면 함부로 공개하지 않는다 (의도하지 않은 노출 방지).
    #
    # ★ 이 구분이 setup_tunnel.sh --down 과의 계약이다.
    #   --down 은 stop 이 아니라 `rm -f` 로 컨테이너를 **삭제**한다.
    #   따라서 사용자가 의도적으로 내린 터널은 여기서 '없음'으로 보이고
    #   되살아나지 않는다. 만약 --down 을 stop 으로 바꾸면 1분 뒤
    #   터널이 되살아나 vulnerable 실습을 방해하게 된다. 둘을 함께 고칠 것.
    if tunnel_running vmlab-quicktunnel; then
        # 컨테이너는 떠 있어도 터널이 실제로 살아있는지는 별개다.
        # 로그에 주소가 있는지로 확인한다.
        URL="$(dk logs --tail 200 vmlab-quicktunnel 2>&1 \
                | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
        if [[ -n "${URL}" ]]; then
            log "Quick Tunnel 정상: ${URL}"
            # 주소가 바뀌었으면 기록해둔다 (알림/조회용)
            PREV="$(cat "${URL_FILE}" 2>/dev/null || true)"
            if [[ "${PREV}" != "${URL}" ]]; then
                printf '%s\n' "${URL}" > "${URL_FILE}" 2>/dev/null \
                    || sudo -n tee "${URL_FILE}" >/dev/null <<< "${URL}" 2>/dev/null || true
                log "외부 주소 변경 감지: ${PREV:-없음} → ${URL}"
            fi
        else
            warn "Quick Tunnel 컨테이너는 떠 있으나 주소가 없습니다 (연결 실패 상태)"
            if act "Quick Tunnel 재생성"; then
                dkc --profile quick rm -sf quicktunnel >/dev/null 2>&1 || true
                dkc --profile quick up -d --no-deps quicktunnel >/dev/null 2>&1 || true
                CHANGED=1
            fi
        fi
    elif dk ps -a --format '{{.Names}}' 2>/dev/null | grep -qx vmlab-quicktunnel; then
        warn "Quick Tunnel 중단 상태 — 외부 접속이 끊겨 있습니다"
        if act "Quick Tunnel 재기동"; then
            # --no-deps: depends_on(nginx) 때문에 스택 전체를 재생성하려 드는 것을 막는다
            dkc --profile quick up -d --no-deps quicktunnel >/dev/null 2>&1 || true
            CHANGED=1
            sleep 8
            URL="$(dk logs --tail 200 vmlab-quicktunnel 2>&1 \
                    | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true)"
            if [[ -n "${URL}" ]]; then
                log "Quick Tunnel 복구됨: ${URL}"
                printf '%s\n' "${URL}" > "${URL_FILE}" 2>/dev/null \
                    || sudo -n tee "${URL_FILE}" >/dev/null <<< "${URL}" 2>/dev/null || true
            else
                warn "재기동했으나 주소를 아직 못 받았습니다 (다음 주기에 재확인)"
            fi
        fi
    else
        log "외부 터널 미사용 (한 번도 켠 적 없음) — 노출하지 않습니다"
    fi
fi

# ==========================================================================
# 4. main 드리프트 감지
#
#    배포가 실패했거나 러너가 죽어 있으면 VM 이 옛 커밋에 남는다.
#    여기서는 **감지와 보고만** 한다. 자동으로 빌드해서 올리지 않는 이유:
#    그렇게 하면 CI(테스트) 게이트를 건너뛰고 배포하는 셈이 된다.
#    대신 러너가 죽어 있으면 그건 되살린다 — 러너만 살아나면
#    GitHub Actions 가 밀린 배포를 알아서 가져간다.
# ==========================================================================
#    ★ 실패하면 반드시 말해야 한다
#      처음엔 조회 실패 시 조용히 건너뛰게 짰는데, 그러면 감지 기능이
#      죽어 있어도 로그에는 "점검 완료"만 찍혀 정상처럼 보인다.
#      동작하지 않는 안전장치를 동작한다고 믿는 것이 가장 위험하다.
REMOTE_SHA=""
GIT_ERR=""
if ! command -v git >/dev/null 2>&1; then
    GIT_ERR="git 명령이 없습니다"
else
    # 러너 작업 디렉터리는 소유자가 달라 git 이 거부할 수 있다(dubious ownership).
    # 조회만 하므로 safe.directory 를 이 실행에 한해 허용한다.
    if ! GIT_OUT="$(git -c safe.directory='*' ls-remote origin refs/heads/main 2>&1)"; then
        GIT_ERR="$(printf '%s' "${GIT_OUT}" | head -1)"
    else
        REMOTE_SHA="$(printf '%s' "${GIT_OUT}" | awk 'NR==1{print substr($1,1,7)}')"
        [[ -n "${REMOTE_SHA}" ]] || GIT_ERR="origin/main 을 찾지 못했습니다"
    fi
fi

if [[ -n "${GIT_ERR}" ]]; then
    warn "드리프트 감지 불가: ${GIT_ERR}"
    echo  "      (main 과 실행 커밋 비교를 건너뜁니다. 배포 자동화에는 영향 없음)"
    echo  "      확인:  cd ${WORKDIR} && git ls-remote origin"
fi

if [[ -n "${REMOTE_SHA}" && -n "${LIVE_COMMIT}" ]]; then
    if [[ "${REMOTE_SHA}" == "${LIVE_COMMIT}" ]]; then
        log "main 과 일치: ${LIVE_COMMIT}"
    else
        warn "드리프트: main=${REMOTE_SHA} / 실행중=${LIVE_COMMIT}"
        # 러너가 살아 있는지 본다. 죽었다면 그것이 원인일 가능성이 크다.
        if systemctl list-units --type=service --all 2>/dev/null \
             | grep -q 'actions\.runner\.'; then
            RSVC="$(systemctl list-units --type=service --all --plain --no-legend 2>/dev/null \
                     | awk '/actions\.runner\./{print $1; exit}')"
            if [[ -n "${RSVC}" ]] && ! systemctl is-active --quiet "${RSVC}"; then
                warn "러너 서비스(${RSVC})가 중지되어 있습니다 — 이것이 드리프트 원인입니다"
                if act "러너 서비스 재시작"; then
                    sudo -n systemctl start "${RSVC}" >/dev/null 2>&1 \
                        && log "러너 재시작됨 — 밀린 배포가 곧 진행됩니다" \
                        || warn "러너 재시작 실패 (sudo 권한 확인)"
                    CHANGED=1
                fi
            else
                log "러너는 정상 — 배포가 실패했거나 진행 중입니다. Actions 로그를 확인하세요"
            fi
        fi
    fi
fi

# ==========================================================================
(( CHANGED )) && log "복구 조치를 수행했습니다" || log "점검 완료 — 조치 불필요"
exit 0
