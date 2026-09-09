#!/usr/bin/env bash
# ==========================================================================
# 지금까지 구축한 것 전체 점검 (VM 안에서 실행)
#
# 무엇이 실제로 동작하고 무엇이 안 되는지 사실만 확인한다.
# 아무것도 변경하지 않는다 (읽기 전용).
#
# 사용:  ./scripts/verify_all.sh
# ==========================================================================
set -uo pipefail   # -e 는 쓰지 않는다. 실패해도 끝까지 점검해야 한다.

G=$'\033[0;32m'; R=$'\033[0;31m'; Y=$'\033[0;33m'; B=$'\033[1m'; N=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$G" "$N" "$*"; }
bad()  { printf '  %s✘%s %s\n' "$R" "$N" "$*"; }
warn() { printf '  %s▲%s %s\n' "$Y" "$N" "$*"; }
sec()  { printf '\n%s━━━ %s ━━━%s\n' "$B" "$*" "$N"; }

DOCKER=(docker)
docker info >/dev/null 2>&1 || DOCKER=(sudo docker)
dk()  { "${DOCKER[@]}" "$@"; }
dkc() { "${DOCKER[@]}" compose -p vmlab "$@"; }

# ---------------------------------------------------------------- 작업 디렉터리
WORKDIR=""
for c in "$PWD" /opt/actions-runner/_work/*/*; do
    [[ -f "$c/docker-compose.yml" ]] || continue
    [[ -f "$c/.env" ]] || sudo -n test -f "$c/.env" 2>/dev/null || continue
    WORKDIR="$c"; break
done

sec "1. 실행 환경"
echo "  현재 위치     : $PWD"
echo "  러너 작업폴더 : ${WORKDIR:-찾지 못함}"
echo "  docker 호출   : ${DOCKER[*]}"

sec "2. 컨테이너 상태"
dkc ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null || bad "compose ps 실패"

sec "3. 앱 헬스체크"
if HEALTH=$(curl -fsS --max-time 5 http://127.0.0.1:8080/healthz 2>/dev/null); then
    ok "응답 정상"
    echo "$HEALTH" | python3 -m json.tool 2>/dev/null || echo "$HEALTH"
    LIVE=$(echo "$HEALTH" | python3 -c "import json,sys;print(json.load(sys.stdin).get('commit',''))" 2>/dev/null)
    MODE=$(echo "$HEALTH" | python3 -c "import json,sys;print(json.load(sys.stdin).get('mode',''))" 2>/dev/null)
    [[ "$MODE" == "secure" ]] && ok "secure 모드" || bad "secure 아님: $MODE"
else
    bad "앱이 응답하지 않습니다"
    LIVE=""
fi

sec "4. main 브랜치와 일치하는가 (드리프트)"
REPO_DIR="${WORKDIR:-$PWD}"
REMOTE_SHA=$(cd "$REPO_DIR" 2>/dev/null && git ls-remote origin refs/heads/main 2>/dev/null | awk '{print substr($1,1,7)}')
if [[ -z "$REMOTE_SHA" ]]; then
    warn "git ls-remote 실패 — autoheal 의 드리프트 감지도 같은 이유로 작동 못 함"
    echo "       (러너 작업폴더의 원격 인증이 없거나 네트워크 문제)"
    echo "       확인:  cd $REPO_DIR && git ls-remote origin"
else
    echo "  origin/main : $REMOTE_SHA"
    echo "  실행 중     : ${LIVE:-알수없음}"
    [[ "$REMOTE_SHA" == "$LIVE" ]] && ok "일치" || warn "드리프트 — 최신 커밋이 아직 배포되지 않았습니다"
fi

sec "5. 자기복구 (autoheal)"
if systemctl is-enabled vmlab-autoheal.timer >/dev/null 2>&1; then
    ok "타이머 등록됨"
    systemctl status vmlab-autoheal.timer --no-pager 2>/dev/null | grep -E "Active:|Trigger:" | sed 's/^/     /'
else
    bad "타이머가 등록되지 않았습니다"
fi
[[ -x /usr/local/bin/vmlab-autoheal ]] && ok "스크립트 설치됨" || bad "/usr/local/bin/vmlab-autoheal 없음"
echo "  최근 로그:"
journalctl -u vmlab-autoheal -n 6 --no-pager 2>/dev/null | sed 's/^/     /'

sec "6. GitHub Actions 러너"
RSVC=$(systemctl list-units --type=service --all --plain --no-legend 2>/dev/null | awk '/actions\.runner\./{print $1; exit}')
if [[ -n "$RSVC" ]]; then
    if systemctl is-active --quiet "$RSVC"; then
        ok "러너 실행 중 ($RSVC)"
    else
        bad "러너 중지됨 ($RSVC) — 배포가 트리거되지 않습니다"
        echo "       복구:  sudo systemctl start $RSVC"
    fi
else
    bad "러너 서비스를 찾을 수 없습니다"
fi

sec "7. 외부 노출 (터널)"
if dk ps --format '{{.Names}}' 2>/dev/null | grep -qx vmlab-quicktunnel; then
    URL=$(dk logs --tail 200 vmlab-quicktunnel 2>&1 | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1)
    ok "Quick Tunnel 실행 중: ${URL:-주소 확인중}"
elif dk ps -a --format '{{.Names}}' 2>/dev/null | grep -qx vmlab-quicktunnel; then
    warn "터널 컨테이너가 멈춰 있음 (autoheal 이 1분 내 재기동합니다)"
else
    warn "터널 없음 — 외부에서 접속 불가"
    echo "       켜기:  ./scripts/setup_tunnel.sh --quick"
fi

sec "8. 포트 바인딩 (외부 노출면)"
echo "  8080 리스닝:"
ss -tlnp 2>/dev/null | grep ':8080' | sed 's/^/     /' || echo "     (없음)"
if ss -tln 2>/dev/null | grep -q '0.0.0.0:8080'; then
    bad "8080 이 0.0.0.0 에 열려 있습니다 — 127.0.0.1 로 제한해야 합니다"
else
    ok "8080 은 외부에 직접 열려 있지 않습니다"
fi

sec "9. VM 방화벽"
sudo -n ufw status 2>/dev/null | head -8 | sed 's/^/     /' || echo "     (조회 실패)"
if systemctl is-active --quiet fail2ban 2>/dev/null; then
    ok "fail2ban 실행 중"
else
    warn "fail2ban 미실행"
fi

sec "10. 보안 모드 최종 확인"
if [[ -n "$WORKDIR" ]]; then
    M=$( (grep -E '^SECURITY_MODE=' "$WORKDIR/.env" 2>/dev/null || sudo -n grep -E '^SECURITY_MODE=' "$WORKDIR/.env" 2>/dev/null) | cut -d= -f2)
    [[ "$M" == "secure" ]] && ok ".env SECURITY_MODE=secure" || bad ".env SECURITY_MODE=$M"
fi

printf '\n%s점검 완료%s\n\n' "$B" "$N"
