#!/usr/bin/env bash
# ==========================================================================
# Cloudflare Tunnel 설정 (요구사항 #2 — 외부 접속)
#
# ★ 왜 포트포워딩이 아니라 터널인가
#   공유기에 포트를 열면 인터넷 전체가 우리 집 IP 를 스캔 대상으로 삼는다.
#   포트포워딩 = 인바운드 구멍 1개 + 공인 IP 노출 + ISP 차단 위험.
#   Cloudflare Tunnel 은 VM 이 Cloudflare 로 **아웃바운드** 연결을 맺고
#   그 위로 트래픽을 되받는다. 인바운드 구멍 0개, HTTPS 자동, IP 비노출.
#   보안 포트폴리오에서 "왜 이 선택을 했는가"로 설명하기 좋은 지점이다.
#
# ★★ 안전장치 (이 스크립트의 가장 중요한 부분)
#   vulnerable 모드에서는 터널을 절대 켜지 않는다.
#   의도적으로 취약한 앱을 인터넷에 공개하는 것은
#   실습이 아니라 사고다. 아래에서 SECURITY_MODE 를 강제 검사한다.
#
# 사용법:
#   ./scripts/setup_tunnel.sh            # 안내 + 토큰 입력 + 기동
#   ./scripts/setup_tunnel.sh --status   # 현재 터널 상태만 확인
#   ./scripts/setup_tunnel.sh --down     # 터널 내리기 (앱은 계속 동작)
# ==========================================================================
set -Eeuo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_CYAN=$'\033[36m'
step() { printf '\n%s\n' "${C_BOLD}${C_CYAN}▶ $*${C_RESET}"; }
ok()   { printf '%s\n' "${C_GREEN}  ✔ $*${C_RESET}"; }
warn() { printf '%s\n' "${C_YELLOW}  ▲ $*${C_RESET}"; }
die()  { printf '%s\n' "${C_RED}  ✘ $*${C_RESET}" >&2; exit 1; }

ACTION="up"
case "${1:-}" in
  --status) ACTION="status" ;;
  --down)   ACTION="down" ;;
  -h|--help) sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) die "알 수 없는 옵션: $1" ;;
esac

command -v docker >/dev/null 2>&1 || die "docker 가 없습니다. vm_bootstrap.sh 를 먼저 실행하세요."

# --------------------------------------------------------------------------
if [[ "${ACTION}" == "status" ]]; then
  step "터널 상태"
  if docker ps --format '{{.Names}}' | grep -qx vmlab-tunnel; then
    ok "터널 실행 중"
    docker ps --filter name=vmlab-tunnel --format '  {{.Names}}  {{.Status}}'
    echo
    echo "  최근 로그:"
    docker logs --tail 15 vmlab-tunnel 2>&1 | sed 's/^/    /'
  else
    warn "터널이 실행 중이 아닙니다."
  fi
  exit 0
fi

# --------------------------------------------------------------------------
if [[ "${ACTION}" == "down" ]]; then
  step "터널 내리기"
  docker compose --profile tunnel stop cloudflared 2>/dev/null || true
  docker compose --profile tunnel rm -f cloudflared 2>/dev/null || true
  ok "터널 중지됨 (앱은 계속 127.0.0.1:8080 에서 동작합니다)"
  exit 0
fi

printf '%s\n' "${C_BOLD}${C_CYAN}══════════════════════════════════════════════${C_RESET}"
printf '%s\n' "${C_BOLD}${C_CYAN} Cloudflare Tunnel 설정 — 외부 접속 활성화${C_RESET}"
printf '%s\n' "${C_BOLD}${C_CYAN}══════════════════════════════════════════════${C_RESET}"

# --------------------------------------------------------------------------
step "안전 점검 — secure 모드 확인"
# --------------------------------------------------------------------------
[[ -f .env ]] || die ".env 가 없습니다. 먼저 배포하거나  ./scripts/gen_secrets.sh --env  를 실행하세요."

# .env 를 source 하지 않는 이유: 값에 특수문자가 있으면 셸이 해석해버린다.
# 필요한 키만 문자열로 뽑아 쓴다.
env_get() { grep -E "^${1}=" .env | tail -1 | cut -d= -f2- ; }

MODE="$(env_get SECURITY_MODE)"
echo "  현재 SECURITY_MODE = ${MODE:-(미설정)}"

if [[ "${MODE}" != "secure" ]]; then
  echo
  printf '%s\n' "${C_RED}${C_BOLD}  ╔══════════════════════════════════════════════════════╗${C_RESET}"
  printf '%s\n' "${C_RED}${C_BOLD}  ║  중단: secure 모드가 아닙니다                        ║${C_RESET}"
  printf '%s\n' "${C_RED}${C_BOLD}  ╚══════════════════════════════════════════════════════╝${C_RESET}"
  echo
  echo "  현재 모드가 '${MODE}' 입니다."
  echo "  이 상태로 터널을 켜면 의도적으로 심어둔 취약점"
  echo "  (SQLi / XSS / IDOR / 파일 업로드)이 인터넷에 그대로 공개됩니다."
  echo
  echo "  vulnerable 모드 실습은 호스트 전용 네트워크에서 Kali 로만 진행하세요."
  echo "  터널을 켜려면 .env 의 SECURITY_MODE 를 secure 로 바꾸고 재배포하세요."
  exit 1
fi
ok "secure 모드 확인됨 — 공개해도 안전한 빌드입니다"

# 실행 중인 앱이 정말 secure 인지 한 번 더 확인한다.
# .env 는 secure 인데 컨테이너가 옛날 vulnerable 이미지로 떠 있을 수 있다.
if docker ps --format '{{.Names}}' | grep -qx vmlab-nginx; then
  RUNTIME_MODE="$(curl -fsS --max-time 5 http://127.0.0.1:8080/healthz 2>/dev/null \
                   | grep -o '"mode"[[:space:]]*:[[:space:]]*"[^"]*"' \
                   | cut -d'"' -f4 || true)"
  if [[ -n "${RUNTIME_MODE}" ]]; then
    if [[ "${RUNTIME_MODE}" == "secure" ]]; then
      ok "실행 중인 앱도 secure 응답 (이중 확인 통과)"
    else
      die "실행 중인 앱이 '${RUNTIME_MODE}' 모드입니다. .env 와 불일치 — 재배포 후 다시 시도하세요."
    fi
  else
    warn "/healthz 응답을 읽지 못했습니다 (앱이 아직 기동 중일 수 있음)"
  fi
else
  warn "앱이 아직 실행 중이 아닙니다. 터널만 먼저 설정합니다."
fi

# --------------------------------------------------------------------------
step "터널 토큰 확인"
# --------------------------------------------------------------------------
TOKEN="$(env_get TUNNEL_TOKEN)"

if [[ -z "${TOKEN}" ]]; then
  cat <<'GUIDE'

  터널 토큰이 .env 에 없습니다. 아래 순서로 발급받으세요.

  ── Cloudflare 준비 (최초 1회) ────────────────────────────────
  1) Cloudflare 계정 생성 (무료)     https://dash.cloudflare.com/sign-up
  2) 도메인을 Cloudflare 에 연결
     - 도메인이 없다면 아무 곳에서나 저렴한 것 하나 구입하면 됩니다.
     - 네임서버를 Cloudflare 가 알려주는 값으로 변경 (반영에 수십 분)

  ── 터널 생성 ─────────────────────────────────────────────────
  3) Zero Trust 대시보드 접속       https://one.dash.cloudflare.com
  4) Networks → Tunnels → Create a tunnel
  5) 커넥터로  Cloudflared  선택, 터널 이름 입력 (예: vmlab)
  6) 다음 화면에 설치 명령이 나오는데, **명령 전체가 아니라
     --token 뒤의 긴 문자열만** 복사합니다 (eyJhIjoi... 로 시작)

  ── 공개 호스트명 연결 (같은 화면 하단) ───────────────────────
  7) Public Hostnames 탭 → Add a public hostname
       Subdomain : vmlab            (원하는 이름)
       Domain    : example.com      (본인 도메인)
       Type      : HTTP
       URL       : nginx:8080       ★ 컨테이너 이름:포트
                   (localhost 가 아닙니다 — cloudflared 도 컨테이너 안입니다)
  8) Save

GUIDE
  read -rp "  터널 토큰 붙여넣기: " TOKEN
  echo
  [[ -n "${TOKEN}" ]] || die "토큰이 비었습니다."

  # .env 갱신 — 기존 줄을 지우고 새로 추가한다.
  # sed -i 로 치환하지 않는 이유: 토큰에 / 가 들어 있어 구분자가 깨진다.
  cp .env .env.bak
  grep -v '^TUNNEL_TOKEN=' .env.bak > .env
  printf 'TUNNEL_TOKEN=%s\n' "${TOKEN}" >> .env
  chmod 600 .env
  rm -f .env.bak
  ok ".env 에 토큰 저장 (권한 $(stat -c %a .env))"

  echo
  warn "GitHub Secrets 에도 같은 값을 등록하세요."
  warn "  등록하지 않으면 다음 배포 때 .env 가 덮어써지면서 토큰이 사라집니다."
  echo  "    gh secret set CLOUDFLARE_TUNNEL_TOKEN"
  echo  "  또는 Settings → Secrets and variables → Actions 에서 수동 등록"
  echo  "    이름: CLOUDFLARE_TUNNEL_TOKEN"
else
  ok "토큰이 이미 .env 에 있습니다"
fi

# --------------------------------------------------------------------------
step "터널 기동"
# --------------------------------------------------------------------------
# --profile tunnel 이 필요하다. 이 프로파일 없이는 cloudflared 가 뜨지 않는데,
# 그게 의도된 안전장치다 (docker-compose.yml 주석 참고).
docker compose --profile tunnel up -d cloudflared || die "터널 기동 실패"
ok "cloudflared 컨테이너 시작"

echo "  연결 수립 대기 중..."
CONNECTED=0
for _ in $(seq 1 20); do
  sleep 2
  if docker logs vmlab-tunnel 2>&1 | grep -qi "Registered tunnel connection\|Connection .* registered"; then
    CONNECTED=1
    break
  fi
  # 토큰이 틀리면 빨리 실패하므로 즉시 잡아낸다
  if docker logs vmlab-tunnel 2>&1 | grep -qi "Provided Tunnel token is not valid\|failed to parse token"; then
    echo
    docker logs --tail 20 vmlab-tunnel 2>&1 | sed 's/^/    /'
    die "터널 토큰이 유효하지 않습니다. .env 의 TUNNEL_TOKEN 을 다시 확인하세요."
  fi
done

if [[ ${CONNECTED} -eq 1 ]]; then
  ok "Cloudflare 엣지에 연결됨"
else
  warn "연결 확인 실패 — 로그를 확인하세요:  docker logs -f vmlab-tunnel"
fi

# --------------------------------------------------------------------------
step "결과"
# --------------------------------------------------------------------------
docker ps --filter name=vmlab-tunnel --format '  {{.Names}}  {{.Status}}'
echo
docker logs --tail 10 vmlab-tunnel 2>&1 | sed 's/^/    /'

cat <<EOF

──────────────────────────────────────────────────────────────
 ${C_BOLD}확인 방법${C_RESET}
──────────────────────────────────────────────────────────────
  Zero Trust → Networks → Tunnels 에서 상태가 ${C_GREEN}HEALTHY${C_RESET} 인지 확인
  그 다음 휴대폰(Wi-Fi 끄고 LTE)으로 접속해보세요:

      https://<설정한-호스트명>/

  LTE 로 확인하는 이유: 집 Wi-Fi 로 접속하면 내부망으로
  도는 것인지 진짜 외부에서 들어온 것인지 구분이 안 됩니다.

  접속 후 관리자 대시보드의 '접속 로그'에서
  방금 그 요청이 기록됐는지 보면 요구사항 #2 와 #3 이
  동시에 검증됩니다.

──────────────────────────────────────────────────────────────
 ${C_BOLD}관리 명령${C_RESET}
──────────────────────────────────────────────────────────────
  상태  : ./scripts/setup_tunnel.sh --status
  중지  : ./scripts/setup_tunnel.sh --down
  로그  : docker logs -f vmlab-tunnel

──────────────────────────────────────────────────────────────
 ${C_YELLOW}${C_BOLD}잊지 마세요${C_RESET}
──────────────────────────────────────────────────────────────
  vulnerable 모드로 실습하기 전에 반드시 터널을 내리세요:
      ./scripts/setup_tunnel.sh --down

EOF
