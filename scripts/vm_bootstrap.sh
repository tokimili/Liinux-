#!/usr/bin/env bash
# ==========================================================================
# VM 초기 구축 (Ubuntu 22.04 / 24.04 LTS 기준)
#
# 요구사항 #2 의 토대. Docker + 방화벽 + 침입차단을 설치하고
# 이 프로젝트가 돌아갈 수 있는 상태로 만든다.
#
# ★ 이 스크립트가 포트포워딩을 설정하지 않는 이유
#   외부 공개는 Cloudflare Tunnel(아웃바운드 전용)로 처리한다.
#   따라서 ufw 인바운드는 SSH 만 열고, 나머지는 전부 차단한다.
#   공유기에 구멍을 뚫지 않는 것이 이 구성의 핵심 방어다.
#
# 사용법:
#   chmod +x scripts/vm_bootstrap.sh
#   sudo ./scripts/vm_bootstrap.sh
#
# 멱등성: 여러 번 실행해도 안전하다.
# ==========================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------- 출력 헬퍼
readonly C_OK=$'\033[0;32m'
readonly C_WARN=$'\033[0;33m'
readonly C_ERR=$'\033[0;31m'
readonly C_INFO=$'\033[0;36m'
readonly C_OFF=$'\033[0m'

step() { printf '\n%s==> %s%s\n' "${C_INFO}" "$*" "${C_OFF}"; }
ok()   { printf '%s  [OK]%s %s\n'   "${C_OK}"   "${C_OFF}" "$*"; }
warn() { printf '%s  [!]%s %s\n'    "${C_WARN}" "${C_OFF}" "$*"; }
die()  { printf '%s  [에러]%s %s\n' "${C_ERR}"  "${C_OFF}" "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 사전 점검
[[ "${EUID}" -eq 0 ]] || die "root 권한이 필요합니다:  sudo $0"

# SUDO_USER: sudo 를 실행한 실제 사용자. docker 그룹에 넣어줘야 할 대상이다.
TARGET_USER="${SUDO_USER:-}"
if [[ -z "${TARGET_USER}" || "${TARGET_USER}" == "root" ]]; then
    warn "일반 사용자를 특정할 수 없습니다 (root 로 직접 로그인한 경우)."
    warn "docker 그룹 추가는 건너뜁니다. 나중에 수동으로:"
    warn "  sudo usermod -aG docker <사용자명>"
    TARGET_USER=""
fi

if ! command -v apt-get >/dev/null 2>&1; then
    die "apt 기반 배포판(Ubuntu/Debian)이 아닙니다. 이 스크립트는 Ubuntu LTS 를 가정합니다."
fi

step "시스템 정보"
. /etc/os-release 2>/dev/null || true
echo "  OS      : ${PRETTY_NAME:-unknown}"
echo "  커널    : $(uname -r)"
echo "  아키텍처: $(dpkg --print-architecture)"
echo "  대상유저: ${TARGET_USER:-(없음)}"

# ---------------------------------------------------------------- 패키지 갱신
step "패키지 목록 갱신 및 보안 업데이트"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
ok "시스템 업데이트 완료"

step "기본 도구 설치"
apt-get install -y -qq \
    ca-certificates curl gnupg lsb-release \
    git jq ufw fail2ban unattended-upgrades \
    htop net-tools dnsutils

# python3-systemd 가 반드시 필요한 이유:
#   Ubuntu 24.04 부터 rsyslog 가 기본 설치되지 않아 /var/log/auth.log 가
#   없고, SSH 인증 로그는 systemd journal 에만 남는다.
#   그래서 jail.local 에서 backend=systemd 를 쓰는데, fail2ban 이 journal 을
#   읽으려면 이 파이썬 바인딩이 있어야 한다.
#   없으면 fail2ban 서비스는 뜨지만 sshd jail 이 조용히 죽어서
#   "방화벽은 켜져 있는데 무차별 대입이 전혀 차단되지 않는" 상태가 된다.
apt-get install -y -qq python3-systemd || \
    warn "python3-systemd 설치 실패 — fail2ban 이 journal 을 읽지 못할 수 있습니다"
ok "기본 도구 설치 완료"

# ---------------------------------------------------------------- Docker
step "Docker Engine 설치"
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    ok "Docker 가 이미 설치되어 있습니다 ($(docker --version | cut -d, -f1))"
else
    # 공식 저장소를 쓴다. Ubuntu 기본 저장소의 docker.io 는 버전이 낮고
    # compose v2 플러그인이 함께 제공되지 않는다.
    install -m 0755 -d /etc/apt/keyrings
    if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc
    fi

    # 코드네임을 그대로 쓰기 전에 Docker 저장소가 그 버전을 지원하는지 본다.
    # 갓 나온 우분투(예: 26.04 resolute)는 Docker 반영이 며칠~몇 주 늦는데,
    # 그 상태로 apt update 를 하면 404 만 뜨고 원인을 알기 어렵다.
    # 미지원이면 최신 LTS 저장소로 폴백한다(패키지 호환성은 유지된다).
    CODENAME="$(. /etc/os-release && echo "${VERSION_CODENAME}")"
    echo "  감지된 배포판: ${CODENAME} ($(. /etc/os-release && echo "${VERSION}"))"

    if curl -fsSL --max-time 15 \
         "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/stable/binary-$(dpkg --print-architecture)/Packages" \
         2>/dev/null | grep -q "^Package: docker-ce$"; then
        ok "Docker 공식 저장소가 ${CODENAME} 를 지원합니다"
        REPO_CODENAME="${CODENAME}"
    else
        # noble(24.04) 은 장기 지원 LTS 라 폴백 대상으로 안전하다.
        REPO_CODENAME="noble"
        warn "Docker 저장소에 ${CODENAME} 이 아직 없습니다 → ${REPO_CODENAME} 저장소로 대체합니다"
    fi

    echo "deb [arch=$(dpkg --print-architecture) \
signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${REPO_CODENAME} stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq \
        docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin \
        || die "Docker 설치 실패 — /etc/apt/sources.list.d/docker.list 를 확인하세요"
    ok "Docker 설치 완료 ($(docker --version | cut -d, -f1))"
fi

systemctl enable --now docker >/dev/null 2>&1 || true
ok "Docker 서비스 활성화"

# 컨테이너 로그가 디스크를 채우는 것을 막는다.
# compose 파일에도 로깅 제한이 있지만, 여기서 데몬 기본값도 잡아둔다.
step "Docker 데몬 로그 로테이션 설정"
if [[ ! -f /etc/docker/daemon.json ]]; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "live-restore": true
}
JSON
    systemctl restart docker
    ok "로그 로테이션 설정 완료 (10MB x 3)"
else
    warn "/etc/docker/daemon.json 이 이미 존재합니다 — 덮어쓰지 않습니다"
fi

if [[ -n "${TARGET_USER}" ]]; then
    usermod -aG docker "${TARGET_USER}"
    ok "사용자 '${TARGET_USER}' 를 docker 그룹에 추가"
    warn "그룹 변경은 재로그인 후 적용됩니다 (또는: newgrp docker)"
fi

# ---------------------------------------------------------------- 방화벽
step "ufw 방화벽 설정"
# ★ 기본 정책: 인바운드 전부 차단, 아웃바운드 허용.
#   Cloudflare Tunnel 은 아웃바운드로 연결하므로 인바운드를 열 필요가 없다.
ufw --force default deny incoming >/dev/null
ufw --force default allow outgoing >/dev/null

# SSH 는 반드시 먼저 허용한다. 이 순서를 틀리면 원격 접속이 끊긴다.
SSH_PORT="$(grep -oP '^\s*Port\s+\K[0-9]+' /etc/ssh/sshd_config 2>/dev/null | head -1)"
SSH_PORT="${SSH_PORT:-22}"
ufw allow "${SSH_PORT}"/tcp comment 'SSH' >/dev/null
ok "SSH(${SSH_PORT}/tcp) 허용"

# 웹 포트(8080)는 열지 않는다.
#   - nginx 는 127.0.0.1:8080 에만 바인드된다 (docker-compose.yml 의 BIND_ADDR)
#   - 외부 접속은 cloudflared 가 아웃바운드로 처리한다
# 같은 LAN 의 다른 기기에서 테스트하려면 아래를 수동으로 실행:
#   sudo ufw allow from 192.168.0.0/16 to any port 8080 proto tcp
warn "8080 포트는 의도적으로 열지 않았습니다 (터널로 공개하므로 불필요)"

ufw --force enable >/dev/null
ok "ufw 활성화 완료"
ufw status verbose | sed 's/^/    /'

# ---------------------------------------------------------------- fail2ban
step "fail2ban 설정 (SSH 브루트포스 차단)"
# jail.local 에 작성한다. jail.conf 는 패키지 업데이트 시 덮어써진다.
if [[ ! -f /etc/fail2ban/jail.local ]]; then
    cat > /etc/fail2ban/jail.local <<CONF
# vmlab VM 침입 차단 설정
# 앱 레벨 브루트포스 방어(login_attempts 테이블)와 별개로,
# OS 레벨 SSH 접근도 차단한다 — 방어는 계층적으로 두는 것이 원칙이다.

[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
# 내부망과 루프백은 차단 대상에서 제외 (자기 자신을 잠그는 사고 방지)
ignoreip = 127.0.0.1/8 ::1 192.168.0.0/16 10.0.0.0/8 172.16.0.0/12

[sshd]
enabled  = true
port     = ${SSH_PORT}
maxretry = 4
bantime  = 2h
CONF
    ok "fail2ban 설정 작성 (/etc/fail2ban/jail.local)"
else
    warn "/etc/fail2ban/jail.local 이 이미 존재합니다 — 덮어쓰지 않습니다"
fi

systemctl enable --now fail2ban >/dev/null 2>&1 || true
sleep 3

# 서비스가 "실행 중"인 것만 보면 안 된다.
# fail2ban 은 journal 을 못 읽어도 서비스 자체는 정상 기동하고,
# sshd jail 만 조용히 실패한다. 그래서 jail 목록을 직접 확인한다.
if fail2ban-client status >/dev/null 2>&1; then
    if fail2ban-client status 2>/dev/null | grep -q "sshd"; then
        ok "fail2ban 동작 중 — sshd jail 활성"
        fail2ban-client status sshd 2>/dev/null | sed 's/^/    /' || true
    else
        warn "fail2ban 은 떴지만 sshd jail 이 올라오지 않았습니다!"
        warn "  → SSH 무차별 대입이 차단되지 않는 상태입니다. 확인:"
        echo  "     sudo journalctl -u fail2ban -n 30 --no-pager"
        echo  "     sudo fail2ban-client -d | head"
        # journal 백엔드 실패가 가장 흔한 원인이므로 자동 복구를 시도한다.
        if ! dpkg -s python3-systemd >/dev/null 2>&1; then
            warn "  python3-systemd 가 없습니다. 재설치를 시도합니다."
            apt-get install -y -qq python3-systemd && systemctl restart fail2ban && sleep 3
            fail2ban-client status 2>/dev/null | grep -q "sshd" \
                && ok "복구 성공 — sshd jail 활성" \
                || warn "복구 실패 — 수동 확인이 필요합니다"
        fi
    fi
else
    warn "fail2ban 상태를 확인할 수 없습니다: systemctl status fail2ban"
fi

# ---------------------------------------------------------------- 자동 보안 업데이트
step "자동 보안 업데이트 활성화"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
CONF
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "보안 패치 자동 적용 설정 완료"

# ---------------------------------------------------------------- 커널 네트워크 하드닝
step "커널 네트워크 파라미터 하드닝"
cat > /etc/sysctl.d/99-vmlab-hardening.conf <<'CONF'
# IP 스푸핑 방지 (역경로 필터링)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# ICMP 리다이렉트 수용 거부 (경로 조작 방지)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# 소스 라우팅 거부
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# SYN flood 대응
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2

# 마션 패킷(비정상 출처) 로깅
net.ipv4.conf.all.log_martians = 1
CONF
sysctl -p /etc/sysctl.d/99-vmlab-hardening.conf >/dev/null 2>&1 || \
    warn "일부 커널 파라미터 적용 실패 (VM 환경에 따라 정상)"
ok "커널 하드닝 적용"

# ---------------------------------------------------------------- 검증
step "설치 검증"
FAILED=0
check() {
    if eval "$2" >/dev/null 2>&1; then
        ok "$1"
    else
        printf '%s  [실패]%s %s\n' "${C_ERR}" "${C_OFF}" "$1"
        FAILED=$((FAILED + 1))
    fi
}

check "docker 명령 사용 가능"      "command -v docker"
check "docker compose v2 플러그인" "docker compose version"
check "docker 데몬 실행 중"        "docker info"
check "git 설치됨"                 "command -v git"
check "ufw 활성화됨"               "ufw status | grep -q 'Status: active'"
check "ufw 인바운드 기본 차단"     "ufw status verbose | grep -q 'deny (incoming)'"
check "SSH 접근 허용됨"            "ufw status | grep -qiE 'ssh|22'"
check "fail2ban 실행 중"           "systemctl is-active --quiet fail2ban"
# 서비스 상태와 별개로 jail 이 실제로 떠 있는지 본다.
# 이것이 실패하면 SSH 무차별 대입 차단이 동작하지 않는다.
check "fail2ban sshd jail 활성"    "fail2ban-client status | grep -q sshd"

# 컨테이너가 실제로 뜨는지 확인 — Docker 설치의 진짜 검증이다
step "Docker 동작 테스트 (hello-world)"
if docker run --rm hello-world >/dev/null 2>&1; then
    ok "컨테이너 실행 성공"
else
    printf '%s  [실패]%s 컨테이너를 실행할 수 없습니다\n' "${C_ERR}" "${C_OFF}"
    FAILED=$((FAILED + 1))
fi

# ---------------------------------------------------------------- 결과
echo ""
if [[ "${FAILED}" -eq 0 ]]; then
    printf '%s========================================%s\n' "${C_OK}" "${C_OFF}"
    printf '%s  VM 기본 구축 완료%s\n' "${C_OK}" "${C_OFF}"
    printf '%s========================================%s\n' "${C_OK}" "${C_OFF}"
    cat <<'NEXT'

다음 단계:

  1) 재로그인 (docker 그룹 적용)
       exit  후 다시 SSH 접속
       확인:  docker ps          # sudo 없이 동작해야 정상

  2) GitHub Secrets 값 생성
       ./scripts/gen_secrets.sh

  3) self-hosted 러너 설치 (이걸 하면 대기 중인 배포가 실행됨)
       sudo ./scripts/setup_runner.sh

  4) 외부 공개 (선택)
       sudo ./scripts/setup_tunnel.sh

  자세한 순서: docs/VM_SETUP.md
NEXT
else
    printf '%s%d개 항목이 실패했습니다. 위 로그를 확인하세요.%s\n' \
        "${C_ERR}" "${FAILED}" "${C_OFF}"
    exit 1
fi
