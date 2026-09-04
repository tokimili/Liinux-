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
# ★ 두 가지 방식
#   --quick  : 도메인·계정 없이 즉시 공개. https://<랜덤>.trycloudflare.com
#              주소가 매번 바뀌고 재시작하면 사라진다. 시연·테스트용.
#   (기본)   : Named Tunnel. 계정+도메인 필요. 고정 주소.
#              포트폴리오 제출용 영구 주소가 필요할 때.
#
# 사용법:
#   ./scripts/setup_tunnel.sh --quick    # 도메인 없이 바로 외부 공개
#   ./scripts/setup_tunnel.sh            # 고정 주소 (토큰 입력)
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
QUICK=0
case "${1:-}" in
  --status) ACTION="status" ;;
  --down)   ACTION="down" ;;
  --quick)  QUICK=1 ;;
  -h|--help) sed -n '2,31p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  "") ;;
  *) die "알 수 없는 옵션: $1" ;;
esac

command -v docker >/dev/null 2>&1 || die "docker 가 없습니다. vm_bootstrap.sh 를 먼저 실행하세요."

# 실행 중인 터널 컨테이너 이름을 찾는다 (named 든 quick 이든)
# ★ `|| true` 필수: 터널이 안 떠 있으면 grep 이 1 을 반환하고,
#   호출부의 `NAME="$(running_tunnel)"` 대입문이 그 종료코드를 물려받아
#   set -e 가 스크립트를 죽인다. "아직 안 켜진 상태" 는 정상이지 에러가 아니다.
running_tunnel() {
  docker ps --format '{{.Names}}' 2>/dev/null \
    | grep -E '^vmlab-(tunnel|quicktunnel)$' | head -1 || true
}

# quick 터널이 발급한 주소를 로그에서 뽑아낸다
# `|| true` 필수: 주소 발급 전에는 로그에 URL 이 없어 grep 이 1 을 낸다.
# 발급 대기 루프가 바로 이 "아직 없음" 상태를 기대하고 도는 구조다.
quick_url() {
  docker logs vmlab-quicktunnel 2>&1 \
    | grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' | tail -1 || true
}

# --------------------------------------------------------------------------
if [[ "${ACTION}" == "status" ]]; then
  step "터널 상태"
  NAME="$(running_tunnel)"
  if [[ -n "${NAME}" ]]; then
    ok "터널 실행 중: ${NAME}"
    docker ps --filter "name=${NAME}" --format '  {{.Names}}  {{.Status}}'
    if [[ "${NAME}" == "vmlab-quicktunnel" ]]; then
      URL="$(quick_url)"
      echo
      if [[ -n "${URL}" ]]; then
        printf '%s\n' "  공개 주소: ${C_BOLD}${C_GREEN}${URL}${C_RESET}"
      else
        warn "공개 주소를 로그에서 찾지 못했습니다 (아직 발급 중일 수 있음)"
      fi
    fi
    echo
    echo "  최근 로그:"
    docker logs --tail 15 "${NAME}" 2>&1 | sed 's/^/    /'
  else
    warn "터널이 실행 중이 아닙니다."
  fi
  exit 0
fi

# --------------------------------------------------------------------------
if [[ "${ACTION}" == "down" ]]; then
  step "터널 내리기"
  # 두 방식 모두 내린다. 어느 쪽이 떠 있었는지 사용자가 기억하지 못해도
  # '--down 했으니 이제 외부 노출은 없다'가 보장되어야 한다.
  for svc in cloudflared quicktunnel; do
    docker compose --profile tunnel --profile quick stop "${svc}" 2>/dev/null || true
    docker compose --profile tunnel --profile quick rm -f "${svc}" 2>/dev/null || true
  done
  if [[ -n "$(running_tunnel)" ]]; then
    die "터널 컨테이너가 아직 살아 있습니다. 확인:  docker ps | grep vmlab-"
  fi
  ok "터널 중지됨 — 외부 노출 없음 (앱은 계속 127.0.0.1:8080 에서 동작)"
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
# `|| true` 필수: 해당 키가 .env 에 아직 없으면 grep 이 1 을 낸다.
# 호출부는 빈 문자열을 받아 안내 메시지를 띄우도록 설계돼 있는데,
# 그 안내에 도달하기 전에 스크립트가 죽어버린다 (TOKEN 미설정이 정확히 이 경우).
env_get() { grep -E "^${1}=" .env 2>/dev/null | tail -1 | cut -d= -f2- || true ; }

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

# ==========================================================================
# Quick Tunnel 경로 — 도메인/계정 없이 즉시 공개
#
# 이 분기를 secure 점검 **뒤에** 둔 것이 의도다.
# 간편한 경로라고 안전장치를 건너뛰게 하면, 정작 사고는
# "빠르게 한 번 보여주려고" 켤 때 난다.
# ==========================================================================
if [[ ${QUICK} -eq 1 ]]; then
  step "Quick Tunnel 기동 (도메인 불필요)"

  # 노출 경로를 하나로 유지한다 — named 터널이 떠 있으면 먼저 정리
  if docker ps --format '{{.Names}}' | grep -qx vmlab-tunnel; then
    warn "고정 주소 터널이 실행 중입니다. 공개 경로를 하나로 유지하기 위해 중지합니다."
    docker compose --profile tunnel stop cloudflared >/dev/null 2>&1 || true
    docker compose --profile tunnel rm -f cloudflared >/dev/null 2>&1 || true
  fi

  # 재실행 시 이전 주소가 로그에 남아 혼동되는 것을 막기 위해 컨테이너를 새로 만든다
  docker compose --profile quick rm -sf quicktunnel >/dev/null 2>&1 || true
  docker compose --profile quick up -d quicktunnel || die "Quick Tunnel 기동 실패"
  ok "quicktunnel 컨테이너 시작"

  echo "  주소 발급 대기 중..."
  URL=""
  for _ in $(seq 1 30); do
    sleep 2
    URL="$(quick_url)"
    [[ -n "${URL}" ]] && break
    if ! docker ps --format '{{.Names}}' | grep -qx vmlab-quicktunnel; then
      echo
      docker logs --tail 30 vmlab-quicktunnel 2>&1 | sed 's/^/    /'
      die "컨테이너가 종료되었습니다. 위 로그를 확인하세요."
    fi
  done

  if [[ -z "${URL}" ]]; then
    echo
    docker logs --tail 30 vmlab-quicktunnel 2>&1 | sed 's/^/    /'
    die "주소 발급 실패. 로그를 확인하세요:  docker logs -f vmlab-quicktunnel"
  fi

  echo
  printf '%s\n' "${C_GREEN}${C_BOLD}  ╔══════════════════════════════════════════════════════════╗${C_RESET}"
  printf '%s\n' "${C_GREEN}${C_BOLD}  ║  외부 접속 주소 (HTTPS 자동 적용)                        ║${C_RESET}"
  printf '%s\n' "${C_GREEN}${C_BOLD}  ╚══════════════════════════════════════════════════════════╝${C_RESET}"
  echo
  printf '      %s\n' "${C_BOLD}${URL}${C_RESET}"
  echo
  printf '      %s\n' "관리자 대시보드: ${URL}/admin"
  echo

  cat <<EOF
──────────────────────────────────────────────────────────────
 ${C_BOLD}확인 방법${C_RESET}
──────────────────────────────────────────────────────────────
  휴대폰에서 ${C_BOLD}Wi-Fi 를 끄고(LTE)${C_RESET} 위 주소로 접속하세요.
  집 Wi-Fi 로는 내부망인지 외부인지 구분되지 않습니다.

  접속 후 대시보드의 '접속 로그'에 그 요청이 찍혀 있으면
  요구사항 #2(외부 접속)와 #3(대시보드)이 함께 검증됩니다.
  앱이 CF-Connecting-IP 를 최우선으로 읽으므로
  Quick Tunnel 에서도 실제 접속자 IP 가 기록됩니다.

──────────────────────────────────────────────────────────────
 ${C_YELLOW}${C_BOLD}Quick Tunnel 의 한계${C_RESET}
──────────────────────────────────────────────────────────────
  • 주소가 ${C_BOLD}재시작할 때마다 바뀝니다${C_RESET} (영구 주소 아님)
  • 컨테이너를 내리면 주소가 사라집니다
  • Cloudflare 가 가용성을 보장하지 않습니다 (시연/테스트용)

  포트폴리오에 고정 주소를 싣고 싶어지면 그때 도메인을 연결하고
  ./scripts/setup_tunnel.sh (옵션 없이) 를 실행하면 됩니다.
  앱과 배포 구조는 전혀 바꾸지 않아도 됩니다.

──────────────────────────────────────────────────────────────
  주소 다시 보기 : ./scripts/setup_tunnel.sh --status
  내리기         : ./scripts/setup_tunnel.sh --down
──────────────────────────────────────────────────────────────

EOF
  exit 0
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
