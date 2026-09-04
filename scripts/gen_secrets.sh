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
  # gh CLI 는 vm_bootstrap.sh 가 설치하지 않는다(배포 자체에는 불필요하고,
  # 러너는 GitHub 가 직접 인증하므로). --gh 를 쓸 때만 필요하다.
  # 그래서 "설치하세요" 로 끝내지 않고 실행할 명령을 그대로 준다.
  if ! command -v gh >/dev/null 2>&1; then
    cat <<'GUIDE' >&2

gh CLI 가 설치되어 있지 않습니다.

  [A] gh 를 설치해서 자동 등록하기 (명령 3줄)

      sudo apt update && sudo apt install -y gh
      gh auth login          # GitHub -> HTTPS -> 브라우저 로그인(코드 입력)
      ./scripts/gen_secrets.sh --gh

      * apt 에 gh 가 없다고 나오면 공식 저장소를 추가하세요:
        sudo mkdir -p -m 755 /etc/apt/keyrings
        curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
          | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
        sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
          | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
        sudo apt update && sudo apt install -y gh

  [B] 설치 없이 웹 UI 로 직접 등록하기 (--gh 없이 실행)

      ./scripts/gen_secrets.sh

      출력된 값을 GitHub 저장소 ->
      Settings -> Secrets and variables -> Actions -> New repository secret
      에 하나씩 붙여넣으면 됩니다. 결과는 [A] 와 동일합니다.

GUIDE
    die "위 [A] 또는 [B] 중 하나를 선택하세요."
  fi
  gh auth status >/dev/null 2>&1 || \
    die "gh 인증이 안 되어 있습니다. 먼저 실행:  gh auth login"

  info "gh CLI 로 Secrets 등록 중..."

  # ★ 실패를 반드시 집계한다.
  #   초기 버전은 실패해도 warn 만 찍고 종료코드 0 으로 "다음 단계" 를
  #   안내했다. 토큰 권한이 부족하면 7개가 전부 403 으로 실패하는데도
  #   성공한 것처럼 보여, 배포가 빈 .env 로 돌다가 DB 접속 실패로
  #   죽은 뒤에야 원인을 찾게 된다.
  GH_FAIL=0
  GH_LAST_ERR=""
  set_secret() {
    local out
    if out="$(printf '%s' "$2" | gh secret set "$1" --body - 2>&1)"; then
      ok "$1 등록됨"
    else
      warn "$1 등록 실패"
      GH_FAIL=$((GH_FAIL + 1))
      GH_LAST_ERR="${out}"
    fi
  }
  set_secret SECRET_KEY             "${SECRET_KEY}"
  set_secret DB_NAME                "${DB_NAME}"
  set_secret DB_USER                "${DB_USER}"
  set_secret DB_PASSWORD            "${DB_PASSWORD}"
  set_secret MYSQL_ROOT_PASSWORD    "${MYSQL_ROOT_PASSWORD}"
  set_secret ADMIN_USERNAME         "${ADMIN_USERNAME}"
  set_secret ADMIN_INITIAL_PASSWORD "${ADMIN_INITIAL_PASSWORD}"

  if [[ ${GH_FAIL} -gt 0 ]]; then
    echo >&2
    warn "${GH_FAIL}개 등록에 실패했습니다. 마지막 오류:"
    printf '    %s\n' "${GH_LAST_ERR}" >&2
    echo >&2
    if [[ "${GH_LAST_ERR}" == *"Resource not accessible by integration"* ]] \
    || [[ "${GH_LAST_ERR}" == *"403"* ]]; then
      cat <<'GUIDE' >&2
원인: 지금 gh 가 쓰는 토큰에 Secrets 쓰기 권한이 없습니다.
      (GitHub App 토큰은 Actions Secrets 를 건드릴 수 없습니다.)

해결: 본인 계정으로 다시 인증하거나, 웹 UI 로 등록하세요.

  [A] 본인 계정으로 재인증
      gh auth login          # GitHub.com -> HTTPS -> 브라우저 로그인
      ./scripts/gen_secrets.sh --gh

  [B] 웹 UI 로 등록 (권한 문제 없음)
      ./scripts/gen_secrets.sh        # --gh 없이 실행하면 값만 출력
      -> Settings -> Secrets and variables -> Actions -> New repository secret

GUIDE
    fi
    die "Secrets 등록이 완료되지 않았습니다. 위 안내대로 처리한 뒤 다시 실행하세요."
  fi
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
