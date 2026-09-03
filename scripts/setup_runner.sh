#!/usr/bin/env bash
# ==========================================================================
# GitHub Actions self-hosted 러너 설치 (VM 안에서 실행)
#
# ★ 왜 self-hosted 러너인가
#   GitHub 클라우드 러너는 우리 집 VM 에 접속할 수 없다. NAT 뒤에 있고
#   공유기에 포트를 열지 않았기 때문이다(그게 이 구성의 방어 지점이다).
#   그래서 방향을 뒤집는다 — VM 안의 러너가 GitHub 로 **아웃바운드** 연결을
#   맺어 작업을 받아온다(pull 방식). 인바운드 구멍이 0개인 이유다.
#
# ★ 라벨
#   deploy.yml 은  runs-on: [self-hosted, linux, vmlab]  으로 잡혀 있다.
#   따라서 이 러너에 'vmlab' 라벨이 반드시 붙어야 배포가 잡힌다.
#
# 사용법:
#   sudo ./scripts/setup_runner.sh
#   sudo ./scripts/setup_runner.sh --token <등록토큰> --repo tokimili/Liinux-
#
# 등록 토큰 받는 곳 (유효기간 1시간):
#   저장소 → Settings → Actions → Runners → New self-hosted runner → Linux
#   화면의  ./config.sh --token AXXXX...  에서 토큰 부분만 복사
# ==========================================================================
set -Eeuo pipefail

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
step() { printf '\n%s\n' "${C_BOLD}${C_CYAN}▶ $*${C_RESET}"; }
ok()   { printf '%s\n' "${C_GREEN}  ✔ $*${C_RESET}"; }
warn() { printf '%s\n' "${C_YELLOW}  ▲ $*${C_RESET}"; }
die()  { printf '%s\n' "${C_RED}  ✘ $*${C_RESET}" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "root 권한이 필요합니다:  sudo $0 $*"

# --------------------------------------------------------------------------
# 설정
# --------------------------------------------------------------------------
REPO="tokimili/Liinux-"
RUNNER_TOKEN=""
RUNNER_NAME="vmlab-$(hostname -s)"
RUNNER_LABELS="self-hosted,linux,vmlab"   # ★ deploy.yml 과 반드시 일치
RUNNER_DIR="/opt/actions-runner"

# 러너는 root 로 돌리면 안 된다. GitHub 의 config.sh 자체가 거부한다.
# (워크플로가 root 로 임의 코드를 실행하게 되는 셈이라 위험하다)
TARGET_USER="${SUDO_USER:-}"
[[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" ]] \
  || die "일반 사용자로 로그인한 뒤 sudo 로 실행하세요. (러너는 root 로 실행할 수 없습니다)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --token)  RUNNER_TOKEN="$2"; shift 2 ;;
    --repo)   REPO="$2"; shift 2 ;;
    --name)   RUNNER_NAME="$2"; shift 2 ;;
    --dir)    RUNNER_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "알 수 없는 옵션: $1" ;;
  esac
done

printf '%s\n' "${C_BOLD}${C_CYAN}══════════════════════════════════════════════${C_RESET}"
printf '%s\n' "${C_BOLD}${C_CYAN} GitHub Actions self-hosted 러너 설치${C_RESET}"
printf '%s\n' "${C_BOLD}${C_CYAN}══════════════════════════════════════════════${C_RESET}"
echo "  저장소  : ${REPO}"
echo "  러너명  : ${RUNNER_NAME}"
echo "  라벨    : ${RUNNER_LABELS}"
echo "  실행계정: ${TARGET_USER}"
echo "  설치경로: ${RUNNER_DIR}"

# --------------------------------------------------------------------------
step "사전 조건 확인"
# --------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 \
  || die "docker 가 없습니다. 먼저  sudo ./scripts/vm_bootstrap.sh  를 실행하세요."
docker compose version >/dev/null 2>&1 \
  || die "docker compose v2 플러그인이 없습니다. vm_bootstrap.sh 를 실행하세요."
ok "docker / compose 확인"

# 러너가 배포 작업에서 docker 를 호출하므로 docker 그룹에 있어야 한다.
if id -nG "${TARGET_USER}" | tr ' ' '\n' | grep -qx docker; then
  ok "${TARGET_USER} 가 docker 그룹에 속함"
else
  warn "${TARGET_USER} 가 docker 그룹에 없습니다. 추가합니다."
  usermod -aG docker "${TARGET_USER}"
  ok "추가 완료 (systemd 서비스로 실행하므로 재로그인 없이 적용됩니다)"
fi

for pkg in curl tar jq; do
  command -v "${pkg}" >/dev/null 2>&1 || { apt-get install -y "${pkg}" >/dev/null 2>&1 || die "${pkg} 설치 실패"; }
done
ok "curl / tar / jq 확인"

# --------------------------------------------------------------------------
step "등록 토큰 확인"
# --------------------------------------------------------------------------
if [[ -z "${RUNNER_TOKEN}" ]]; then
  echo
  echo "  아래 주소에서 등록 토큰을 발급받으세요 (유효기간 1시간):"
  printf '  %s\n' "${C_BOLD}https://github.com/${REPO}/settings/actions/runners/new?arch=x64&os=linux${C_RESET}"
  echo
  echo "  화면 중간의 Configure 단계에 이런 줄이 있습니다:"
  echo "     ./config.sh --url https://github.com/${REPO} --token AXXXXXXXXXXXXXXXXXXXXXXXXX"
  echo "  여기서 --token 뒤의 값만 복사해서 붙여넣으세요."
  echo
  read -rp "  등록 토큰: " RUNNER_TOKEN
fi
[[ -n "${RUNNER_TOKEN}" ]] || die "토큰이 비었습니다."
ok "토큰 입력됨"

# --------------------------------------------------------------------------
step "기존 러너 정리 (재설치 대응)"
# --------------------------------------------------------------------------
# 같은 이름으로 다시 설치하면 GitHub 쪽에 유령 러너가 남는다.
# 기존 설치가 있으면 먼저 정상적으로 제거한다.
if [[ -d "${RUNNER_DIR}" ]]; then
  warn "기존 설치 발견 → 제거 시도"
  if [[ -f "${RUNNER_DIR}/svc.sh" ]]; then
    (cd "${RUNNER_DIR}" && ./svc.sh stop >/dev/null 2>&1 || true)
    (cd "${RUNNER_DIR}" && ./svc.sh uninstall >/dev/null 2>&1 || true)
  fi
  if [[ -f "${RUNNER_DIR}/config.sh" ]]; then
    (cd "${RUNNER_DIR}" && sudo -u "${TARGET_USER}" ./config.sh remove --token "${RUNNER_TOKEN}" >/dev/null 2>&1 || true)
  fi
  rm -rf "${RUNNER_DIR}"
  ok "기존 설치 제거"
fi

# --------------------------------------------------------------------------
step "러너 다운로드"
# --------------------------------------------------------------------------
mkdir -p "${RUNNER_DIR}"
chown "${TARGET_USER}:${TARGET_USER}" "${RUNNER_DIR}"

# 최신 버전을 API 로 조회한다. 버전을 하드코딩하면 몇 달 뒤 이 스크립트가
# 낡은 러너를 깔게 되고, GitHub 이 구버전 접속을 끊으면 원인 파악이 어렵다.
ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  RUNNER_ARCH="x64" ;;
  aarch64) RUNNER_ARCH="arm64" ;;
  *) die "지원하지 않는 아키텍처: ${ARCH}" ;;
esac

VERSION="$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest \
            | jq -r '.tag_name' | sed 's/^v//')" || true
if [[ -z "${VERSION}" || "${VERSION}" == "null" ]]; then
  VERSION="2.328.0"
  warn "최신 버전 조회 실패 → 고정 버전 ${VERSION} 사용"
else
  ok "최신 러너 버전: ${VERSION}"
fi

TARBALL="actions-runner-linux-${RUNNER_ARCH}-${VERSION}.tar.gz"
URL="https://github.com/actions/runner/releases/download/v${VERSION}/${TARBALL}"

echo "  다운로드: ${URL}"
curl -fsSL -o "/tmp/${TARBALL}" "${URL}" || die "다운로드 실패"
tar -xzf "/tmp/${TARBALL}" -C "${RUNNER_DIR}"
rm -f "/tmp/${TARBALL}"
chown -R "${TARGET_USER}:${TARGET_USER}" "${RUNNER_DIR}"
ok "압축 해제 완료"

# 러너가 의존하는 시스템 라이브러리 (libicu 등)
if [[ -f "${RUNNER_DIR}/bin/installdependencies.sh" ]]; then
  bash "${RUNNER_DIR}/bin/installdependencies.sh" >/dev/null 2>&1 \
    && ok "의존 라이브러리 설치" \
    || warn "의존 라이브러리 설치 경고 (대개 무시 가능)"
fi

# --------------------------------------------------------------------------
step "러너 등록"
# --------------------------------------------------------------------------
# --unattended  : 대화형 프롬프트 없이
# --replace     : 같은 이름의 러너가 있으면 교체
# --labels      : ★ deploy.yml 의 runs-on 과 일치해야 함
sudo -u "${TARGET_USER}" bash -c "
  cd '${RUNNER_DIR}' &&
  ./config.sh \
    --url 'https://github.com/${REPO}' \
    --token '${RUNNER_TOKEN}' \
    --name '${RUNNER_NAME}' \
    --labels '${RUNNER_LABELS}' \
    --work '_work' \
    --unattended \
    --replace
" || die "러너 등록 실패 — 토큰이 만료되었을 수 있습니다(유효기간 1시간). 새로 발급받아 다시 시도하세요."
ok "러너 등록 완료"

# --------------------------------------------------------------------------
step "systemd 서비스 등록 (부팅 시 자동 시작)"
# --------------------------------------------------------------------------
# svc.sh 를 쓰는 이유: GitHub 이 제공하는 공식 방법이라
# 러너 업데이트 시에도 서비스 정의가 함께 관리된다.
(cd "${RUNNER_DIR}" && ./svc.sh install "${TARGET_USER}") >/dev/null || die "서비스 설치 실패"
(cd "${RUNNER_DIR}" && ./svc.sh start) >/dev/null || die "서비스 시작 실패"
ok "systemd 서비스 등록 및 시작"

sleep 3

# --------------------------------------------------------------------------
step "검증"
# --------------------------------------------------------------------------
FAILED=0
check() {
  if eval "$2" >/dev/null 2>&1; then ok "$1"; else
    printf '%s\n' "${C_RED}  ✘ $1${C_RESET}"; FAILED=$((FAILED + 1))
  fi
}
SVC_NAME="$(systemctl list-units --type=service --all 2>/dev/null \
             | grep -o 'actions\.runner\.[^ ]*\.service' | head -1)"

check "러너 서비스 실행 중"  "[[ -n '${SVC_NAME}' ]] && systemctl is-active --quiet '${SVC_NAME}'"
check "설치 디렉터리 존재"    "[[ -d '${RUNNER_DIR}/_work' || -f '${RUNNER_DIR}/.runner' ]]"
check "docker 접근 가능"      "sudo -u ${TARGET_USER} docker ps"

echo
if [[ ${FAILED} -eq 0 ]]; then
  printf '%s\n' "${C_GREEN}${C_BOLD}✔ 러너 설치 완료${C_RESET}"
else
  printf '%s\n' "${C_RED}${C_BOLD}✘ ${FAILED}개 항목 실패 — 아래 로그를 확인하세요${C_RESET}"
  echo "    sudo journalctl -u '${SVC_NAME}' -n 50 --no-pager"
fi

cat <<EOF

──────────────────────────────────────────────────────────────
 러너 상태 확인
──────────────────────────────────────────────────────────────
  서비스명 : ${SVC_NAME:-(조회 실패)}
  상태     : sudo systemctl status '${SVC_NAME}'
  로그     : sudo journalctl -u '${SVC_NAME}' -f
  중지     : cd ${RUNNER_DIR} && sudo ./svc.sh stop
  제거     : cd ${RUNNER_DIR} && sudo ./svc.sh uninstall

  GitHub 에서 확인:
    https://github.com/${REPO}/settings/actions/runners
    → '${RUNNER_NAME}' 이 Idle(초록색) 로 보이면 정상

──────────────────────────────────────────────────────────────
 ${C_BOLD}지금 일어날 일${C_RESET}
──────────────────────────────────────────────────────────────
  대기(queued) 중이던 'Deploy to VM' 워크플로가
  이 러너를 잡아서 **자동으로 실행**됩니다.

  단, GitHub Secrets 8개가 등록되어 있어야 합니다.
  아직이라면 배포는 돌지만 .env 가 빈 값이라 앱이 뜨지 않습니다:
      ./scripts/gen_secrets.sh --gh

  진행 상황:
    https://github.com/${REPO}/actions

──────────────────────────────────────────────────────────────
 다음 단계
──────────────────────────────────────────────────────────────
  외부 공개(요구사항 #2) → sudo ./scripts/setup_tunnel.sh
  전체 순서              → docs/VM_SETUP.md

EOF
