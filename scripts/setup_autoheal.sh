#!/usr/bin/env bash
# ==========================================================================
# autoheal.sh 를 systemd timer 로 등록한다 (VM 에서 1회 실행).
#
# ★ 왜 cron 이 아니라 systemd timer 인가
#   - 부팅 직후 실행(OnBootSec)을 정확히 표현할 수 있다.
#     재부팅 후 터널이 안 올라오는 문제가 바로 이 케이스였다.
#   - 로그가 journald 로 모인다: journalctl -u vmlab-autoheal
#     cron 은 메일이나 리다이렉트로 따로 관리해야 한다.
#   - 이전 실행이 안 끝났으면 겹쳐 돌지 않는다(서비스 단위 보장).
#     1분 주기인데 겹치면 compose 명령이 충돌한다.
#
# 사용:
#   sudo ./scripts/setup_autoheal.sh            # 설치 (기본 1분 주기)
#   sudo ./scripts/setup_autoheal.sh --interval 5min
#   sudo ./scripts/setup_autoheal.sh --uninstall
# ==========================================================================
set -Eeuo pipefail

C_G=$'\033[0;32m'; C_Y=$'\033[0;33m'; C_R=$'\033[0;31m'; C_0=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "${C_G}" "${C_0}" "$*"; }
warn() { printf '  %s▲%s %s\n' "${C_Y}" "${C_0}" "$*"; }
die()  { printf '  %s✘%s %s\n' "${C_R}" "${C_0}" "$*" >&2; exit 1; }
step() { printf '\n%s▸ %s%s\n' "${C_G}" "$*" "${C_0}"; }

INTERVAL="1min"
UNINSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --interval) INTERVAL="${2:?--interval 값이 필요합니다}"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "알 수 없는 옵션: $1" ;;
    esac
done

[[ ${EUID} -eq 0 ]] || die "root 로 실행하세요:  sudo $0 $*"

UNIT_SVC=/etc/systemd/system/vmlab-autoheal.service
UNIT_TMR=/etc/systemd/system/vmlab-autoheal.timer

# ------------------------------------------------------------------ 제거
if (( UNINSTALL )); then
    step "제거"
    systemctl disable --now vmlab-autoheal.timer >/dev/null 2>&1 || true
    rm -f "${UNIT_SVC}" "${UNIT_TMR}"
    systemctl daemon-reload
    ok "제거 완료"
    exit 0
fi

# ------------------------------------------------------------------ 스크립트 위치
# 러너가 배포할 때마다 작업 디렉터리를 갈아엎으므로, 거기를 직접 가리키면
# 배포 도중 스크립트가 사라질 수 있다. 안정된 위치에 복사해서 쓴다.
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/autoheal.sh"
[[ -f "${SRC}" ]] || die "autoheal.sh 를 찾을 수 없습니다: ${SRC}"

DEST=/usr/local/bin/vmlab-autoheal
step "스크립트 설치"
install -m 0755 "${SRC}" "${DEST}"
ok "${DEST}"

# ------------------------------------------------------------------ 유닛 작성
step "systemd 유닛 작성"

cat > "${UNIT_SVC}" <<EOF
[Unit]
Description=vmlab 자기복구 (main 기준으로 VM 상태 정렬)
# 도커가 준비된 뒤에 돈다. 안 그러면 부팅 직후 매번 실패 로그가 남는다.
After=docker.service network-online.target
Wants=docker.service

[Service]
Type=oneshot
ExecStart=${DEST}
# 실패해도 시스템을 건드리지 않는다. 다음 주기에 다시 시도한다.
SuccessExitStatus=0 1
TimeoutStartSec=300
# 러너 작업 디렉터리 접근을 위해 root 로 실행한다.
User=root
EOF
ok "${UNIT_SVC}"

cat > "${UNIT_TMR}" <<EOF
[Unit]
Description=vmlab 자기복구 타이머

[Timer]
# 부팅 후 90초: 도커가 컨테이너를 다 올릴 시간을 준다.
OnBootSec=90s
OnUnitActiveSec=${INTERVAL}
# 꺼져 있던 동안 놓친 실행을 부팅 후 한 번 따라잡는다.
Persistent=true
Unit=vmlab-autoheal.service

[Install]
WantedBy=timers.target
EOF
ok "${UNIT_TMR} (주기: ${INTERVAL})"

# ------------------------------------------------------------------ 활성화
step "활성화"
systemctl daemon-reload
systemctl enable --now vmlab-autoheal.timer >/dev/null
ok "타이머 활성화"

step "첫 실행"
if systemctl start vmlab-autoheal.service; then
    ok "실행 완료"
else
    warn "첫 실행이 실패했습니다 (로그 확인 필요)"
fi

echo
journalctl -u vmlab-autoheal --no-pager -n 20 2>/dev/null | sed 's/^/    /' || true

cat <<EOF

${C_G}설치 완료${C_0}

  이제 다음이 자동으로 유지됩니다:
    · 재부팅 후 터널 자동 복구 (부팅 90초 뒤)
    · 터널이 끊기면 ${INTERVAL} 안에 재기동
    · 앱이 죽으면 자동 기동 + 헬스체크 확인
    · main 과 실행 커밋이 다르면 감지, 러너가 죽었으면 재시작
    · vulnerable 모드면 오히려 외부 노출을 차단

  확인 명령:
    상태     : systemctl status vmlab-autoheal.timer
    로그     : journalctl -u vmlab-autoheal -f
    수동실행 : sudo ${DEST}
    미리보기 : sudo ${DEST} --dry-run
    현재주소 : cat /var/lib/vmlab/tunnel_url
               (터널을 켠 뒤에 생기는 파일입니다. 켜기 전이면
                No such file 이 나오는 것이 정상입니다)

  ※ 외부 공개는 최초 1회만 직접 켜세요:
        ./scripts/setup_tunnel.sh --quick
    한 번도 켠 적 없는 터널을 자동으로 켜지 않는 것은
    의도치 않은 외부 노출을 막기 위한 설계입니다.
    제거     : sudo ./scripts/setup_autoheal.sh --uninstall

EOF
