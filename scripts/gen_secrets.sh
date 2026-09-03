#!/usr/bin/env bash
# ==========================================================================
# GitHub Secrets 값 생성기
#
# deploy.yml 이 .env 를 만들 때 참조하는 8개 시크릿의 값을 생성한다.
# 이 값들이 GitHub 에 등록되어 있지 않으면 배포는 "성공"하지만
# .env 의 해당 항목이 **빈 값**으로 채워져서 앱이 부팅에 실패한다.
# (가장 찾기 어려운 종류의 실패라서 이 스크립트를 따로 만든다.)
#
# 사용법:
#   ./scripts/gen_secrets.sh              # 값 생성 + 등록 방법 출력
#   ./scripts/gen_secrets.sh --gh         # gh CLI 로 자동 등록까지
#   ./scripts/gen_secrets.sh --env        # 로컬 .env 파일도 함께 생성
#
# 주의: 출력에 실제 비밀값이 찍히므로 화면 공유 중에는 실행하지 말 것.
#       생성된 값은 어디에도 저장되지 않는다(--env 제외). 창을 닫으면 사라진다.
# ==========================================================================
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'

info() { printf '%s\n' "${C_CYAN}$*${C_RESET}"; }
ok()   { printf '%s\n' "${C_GREEN}✔ $*${C_RESET}"; }
warn() { printf '%s\n' "${C_YELLOW}▲ $*${C_RESET}"; }
die()  { printf '%s\n' "${C_RED}✘ $*${C_RESET}" >&2; exit 1; }

USE_GH=0
WRITE_ENV=0
for arg in "$@"; do
  case "${arg}" in
    --gh)  USE_GH=1 ;;
    --env) WRITE_ENV=1 ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) die "알 수 없는 옵션: ${arg}" ;;
  esac
done

# --------------------------------------------------------------------------
# 난수 생성
#   openssl 이 없을 수도 있으므로 /dev/urandom 폴백을 둔다.
#   base64 결과에서 특수문자(+ / =)를 빼는 이유:
#     이 값들은 .env 파일과 docker compose 변수 치환을 거치는데,
#     특수문자가 섞이면 따옴표 처리 실수로 조용히 잘려나갈 수 있다.
#     길이를 늘려서 엔트로피를 보상한다.
# --------------------------------------------------------------------------
randstr() {
  local len="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 $((len * 2)) | tr -dc 'A-Za-z0-9' | head -c "${len}"
  else
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "${len}"
  fi
  echo
}

info "════════════════════════════════════════════════════════════"
info " GitHub Secrets 값 생성"
info "════════════════════════════════════════════════════════════"
echo

# 고정값 성격 (사람이 기억해야 하는 것)
ADMIN_USERNAME="admin"
DB_NAME="vmlab"
DB_USER="vmlab"

# 생성값
SECRET_KEY="$(randstr 48)"
DB_PASSWORD="$(randstr 32)"
MYSQL_ROOT_PASSWORD="$(randstr 32)"
ADMIN_INITIAL_PASSWORD="$(randstr 20)"

printf '%s\n' "${C_BOLD}생성된 값 (8개 중 7개 — 터널 토큰은 Cloudflare 에서 발급)${C_RESET}"
echo "──────────────────────────────────────────────────────────────"
printf '%-24s %s\n' "SECRET_KEY"             "${SECRET_KEY}"
printf '%-24s %s\n' "DB_NAME"                "${DB_NAME}"
printf '%-24s %s\n' "DB_USER"                "${DB_USER}"
printf '%-24s %s\n' "DB_PASSWORD"            "${DB_PASSWORD}"
printf '%-24s %s\n' "MYSQL_ROOT_PASSWORD"    "${MYSQL_ROOT_PASSWORD}"
printf '%-24s %s\n' "ADMIN_USERNAME"         "${ADMIN_USERNAME}"
printf '%-24s %s\n' "ADMIN_INITIAL_PASSWORD" "${ADMIN_INITIAL_PASSWORD}"
echo "──────────────────────────────────────────────────────────────"
echo
warn "ADMIN_INITIAL_PASSWORD 는 첫 로그인용입니다. 로그인 후 반드시 변경하세요."
echo

# --------------------------------------------------------------------------
# gh CLI 자동 등록
# --------------------------------------------------------------------------
if [[ ${USE_GH} -eq 1 ]]; then
  command -v gh >/dev/null 2>&1 || die "gh CLI 가 없습니다. https://cli.github.com 에서 설치하세요."
  gh auth status >/dev/null 2>&1 || die "gh 인증이 안 되어 있습니다. 'gh auth login' 먼저 실행하세요."

  info "gh CLI 로 Secrets 등록 중..."
  set_secret() {
    printf '%s' "$2" | gh secret set "$1" --body - >/dev/null \
      && ok "$1 등록됨" \
      || warn "$1 등록 실패"
  }
  set_secret SECRET_KEY             "${SECRET_KEY}"
  set_secret DB_NAME                "${DB_NAME}"
  set_secret DB_USER                "${DB_USER}"
  set_secret DB_PASSWORD            "${DB_PASSWORD}"
  set_secret MYSQL_ROOT_PASSWORD    "${MYSQL_ROOT_PASSWORD}"
  set_secret ADMIN_USERNAME         "${ADMIN_USERNAME}"
  set_secret ADMIN_INITIAL_PASSWORD "${ADMIN_INITIAL_PASSWORD}"
  echo
  warn "CLOUDFLARE_TUNNEL_TOKEN 은 자동 등록할 수 없습니다 (Cloudflare 발급값)."
  warn "  ./scripts/setup_tunnel.sh 로 발급받은 뒤 아래처럼 등록하세요:"
  echo  "    gh secret set CLOUDFLARE_TUNNEL_TOKEN"
else
  info "수동 등록 방법"
  echo "──────────────────────────────────────────────────────────────"
  echo "GitHub 저장소 → Settings → Secrets and variables → Actions"
  echo "  → 'New repository secret' 로 위 7개를 하나씩 등록"
  echo
  echo "또는 gh CLI 가 있다면 이 스크립트를 다시 실행:"
  echo "    ./scripts/gen_secrets.sh --gh"
  echo "──────────────────────────────────────────────────────────────"
fi
echo

# --------------------------------------------------------------------------
# 로컬 .env
#   CI/CD 없이 VM 에서 직접 docker compose 로 띄워보고 싶을 때 쓴다.
# --------------------------------------------------------------------------
if [[ ${WRITE_ENV} -eq 1 ]]; then
  if [[ -f .env ]]; then
    warn ".env 가 이미 있습니다. .env.generated 로 저장합니다."
    TARGET=".env.generated"
  else
    TARGET=".env"
  fi

  umask 077   # 600 으로 만든다
  cat > "${TARGET}" <<EOF
FLASK_ENV=production
SECURITY_MODE=secure

SECRET_KEY=${SECRET_KEY}

DB_HOST=db
DB_PORT=3306
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
DB_POOL_SIZE=5
MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}

ADMIN_USERNAME=${ADMIN_USERNAME}
ADMIN_INITIAL_PASSWORD=${ADMIN_INITIAL_PASSWORD}

SESSION_COOKIE_SECURE=true
SESSION_LIFETIME_MIN=60
LOGIN_MAX_ATTEMPTS=5
LOGIN_LOCKOUT_MINUTES=15

UPLOAD_DIR=/app/uploads
MAX_UPLOAD_MB=5
TRUSTED_PROXY_COUNT=1
ACCESS_LOG_RETENTION_DAYS=90

BIND_ADDR=127.0.0.1
HTTP_PORT=8080

APP_VERSION=manual
GIT_COMMIT=
DEPLOYED_AT=

TUNNEL_TOKEN=
EOF
  ok "${TARGET} 생성 완료 (권한 $(stat -c %a "${TARGET}"))"
  warn "SESSION_COOKIE_SECURE=true 입니다. 터널(HTTPS) 없이 http://로 접속하면"
  warn "  쿠키가 전송되지 않아 로그인이 안 됩니다. 그럴 땐 false 로 바꾸세요."
fi

echo
info "다음 단계 → sudo ./scripts/setup_runner.sh  (러너를 설치하면 대기 중인 배포가 실행됩니다)"
