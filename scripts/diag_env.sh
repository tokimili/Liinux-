#!/usr/bin/env bash
# ==========================================================================
# 배포 환경 진단 — .env 가 제대로 만들어졌는지 확인한다
#
# 왜 필요한가:
#   배포는 사용자가 clone 한 ~/Liinux- 에서 돌지 않는다.
#   self-hosted 러너는 actions/checkout 으로 **자기 작업 디렉터리에**
#   소스를 새로 내려받고, .env 도 그곳에 만든다.
#   그래서 ~/Liinux- 에서 .env 를 찾으면 "No such file" 이 나오는 것이
#   정상이며, 이걸 모르면 엉뚱한 곳을 파게 된다.
#
# 안전성: 비밀값은 절대 출력하지 않는다. 키 이름과 값의 "길이"만 보여준다.
#
# 사용법:
#   ./scripts/diag_env.sh
# ==========================================================================
set -Eeuo pipefail

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
C_INFO=$'\033[36m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'

step() { printf '\n%s==> %s%s\n' "${C_INFO}" "$*" "${C_OFF}"; }
ok()   { printf '%s  [OK]%s %s\n'  "${C_OK}"   "${C_OFF}" "$*"; }
warn() { printf '%s  [!]%s %s\n'   "${C_WARN}" "${C_OFF}" "$*"; }
bad()  { printf '%s  [문제]%s %s\n' "${C_ERR}" "${C_OFF}" "$*"; }

# --------------------------------------------------------------------------
step "러너 작업 디렉터리 찾기"
# --------------------------------------------------------------------------
# 러너를 어디에 설치했든 찾아낸다. setup_runner.sh 는 /opt/actions-runner
# 를 쓰지만, 수동 설치했을 수도 있으므로 후보를 순회한다.
WORKDIR=""
for base in /opt/actions-runner "${HOME}/actions-runner" /home/*/actions-runner; do
    cand="${base}/_work/Liinux-/Liinux-"
    if [[ -d "${cand}" ]]; then
        WORKDIR="${cand}"
        break
    fi
done

if [[ -z "${WORKDIR}" ]]; then
    bad "러너 작업 디렉터리를 찾지 못했습니다."
    echo  "    러너가 아직 한 번도 작업을 실행하지 않았을 수 있습니다."
    echo  "    직접 찾아보려면:"
    echo  "      sudo find / -maxdepth 6 -type d -name '_work' 2>/dev/null"
    exit 1
fi
ok "작업 디렉터리: ${WORKDIR}"

# --------------------------------------------------------------------------
step ".env 파일 확인"
# --------------------------------------------------------------------------
ENVFILE="${WORKDIR}/.env"
if [[ ! -f "${ENVFILE}" ]]; then
    bad ".env 가 없습니다 — '환경변수 파일 생성' 단계가 실행되지 않았습니다."
    exit 1
fi
ok ".env 존재 (권한: $(stat -c %a "${ENVFILE}"), $(wc -l < "${ENVFILE}")줄)"

PERM="$(stat -c %a "${ENVFILE}")"
[[ "${PERM}" == "600" ]] \
    && ok "권한 600 — 다른 사용자가 읽을 수 없음" \
    || warn "권한이 ${PERM} 입니다 (600 이 안전)"

# --------------------------------------------------------------------------
step "파일 형식 점검"
# --------------------------------------------------------------------------
# 값이 전부 '1자' 처럼 비정상으로 나오는 경우가 있었다. 그때는 개별 값이
# 아니라 **파일 형식 자체**가 문제다. 값을 읽기 전에 형식을 먼저 본다.
# (비밀값을 찍지 않고 진단하려면 이 정보가 필수다)
BYTES="$(wc -c < "${ENVFILE}")"
LINES="$(wc -l < "${ENVFILE}")"
echo "  크기: ${BYTES} 바이트 / 줄 수: ${LINES}"

if [[ "${LINES}" -eq 0 && "${BYTES}" -gt 0 ]]; then
    bad "줄바꿈이 전혀 없습니다 — 파일 전체가 한 줄입니다"
fi

# CR(윈도우 줄바꿈) 검사
if LC_ALL=C grep -q $'\r' "${ENVFILE}" 2>/dev/null; then
    warn "CR(\\r) 문자가 있습니다 — 윈도우 줄바꿈(CRLF)"
    echo  "    값 끝에 보이지 않는 문자가 붙어 컨테이너가 오작동할 수 있습니다"
fi

# 널바이트 검사 (UTF-16 등으로 기록된 경우)
#   ★ `grep -qU $'\x00'` 를 쓰면 안 된다: bash 는 $'\x00' 을 인자로 전달할 수
#     없어서(C 문자열은 널로 끝남) 빈 패턴이 되고, 빈 패턴은 모든 줄에
#     매치되므로 **깨끗한 파일도 전부 오탐**한다. 실제로 오탐을 확인했다.
#   바이트 수를 비교하는 방식이 정확하다: 널을 지운 크기가 원본과 다르면
#   널이 있었다는 뜻이다.
NUL_STRIPPED="$(LC_ALL=C tr -d '\0' < "${ENVFILE}" | wc -c)"
if [[ "${NUL_STRIPPED}" -ne "${BYTES}" ]]; then
    bad "널바이트가 $((BYTES - NUL_STRIPPED))개 있습니다 — 인코딩 오류(UTF-16 등)"
fi

# 실제로 'KEY=' 형태인 줄이 몇 개인지 — 형식이 깨졌으면 여기서 드러난다
KV_LINES="$(LC_ALL=C grep -cE '^[A-Za-z_][A-Za-z0-9_]*=' "${ENVFILE}" 2>/dev/null || echo 0)"
echo "  'KEY=값' 형식의 줄: ${KV_LINES}개"
if [[ "${KV_LINES}" -lt 8 ]]; then
    bad "정상적인 KEY=값 줄이 너무 적습니다 (8개 이상이어야 정상)"
    echo  "    → 파일 구조가 깨졌습니다. 아래 '구조 미리보기' 를 확인하세요."
fi

# 구조 미리보기: 값은 가리고 키와 값 길이만 보여준다.
echo
echo "  구조 미리보기 (값은 X 로 가림):"
LC_ALL=C sed -e 's/\r/<CR>/g' "${ENVFILE}" 2>/dev/null \
  | head -40 \
  | awk -F= '
      /^[[:space:]]*$/ { print "    (빈 줄)"; next }
      /^[[:space:]]*#/ { print "    (주석)"; next }
      /^[A-Za-z_][A-Za-z0-9_]*=/ {
          key=$1
          val=substr($0, length(key)+2)
          n=length(val)
          mask=""
          for(i=0;i<(n>12?12:n);i++) mask=mask "X"
          if(n>12) mask=mask "..."
          printf "    %-24s = %-16s (%d자)\n", key, mask, n
          next
      }
      { printf "    [형식오류] %.50s\n", $0 }
  '

# --------------------------------------------------------------------------
step "키별 값 길이 (비밀값은 출력하지 않음)"
# --------------------------------------------------------------------------
# 반드시 값이 있어야 하는 키들. 비어 있으면 앱이 뜨지 않는다.
REQUIRED="SECRET_KEY DB_NAME DB_USER DB_PASSWORD MYSQL_ROOT_PASSWORD
          ADMIN_USERNAME ADMIN_INITIAL_PASSWORD SECURITY_MODE"

EMPTY_LIST=""
DASH_LIST=""
printf '  %-26s %8s  %s\n' "키" "길이" "상태"
printf '  %s\n' "──────────────────────────────────────────────────"

while read -r key; do
    [[ -z "${key}" ]] && continue
    # .env 에서 해당 키를 뽑는다. source 하지 않는 이유: 값에 특수문자가
    # 있으면 셸이 해석해버린다.
    val="$(grep -E "^${key}=" "${ENVFILE}" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    len="${#val}"

    if ! grep -qE "^${key}=" "${ENVFILE}" 2>/dev/null; then
        status="${C_ERR}키 자체가 없음${C_OFF}"
        EMPTY_LIST="${EMPTY_LIST} ${key}"
    elif [[ "${len}" -eq 0 ]]; then
        status="${C_ERR}비어 있음 ★${C_OFF}"
        EMPTY_LIST="${EMPTY_LIST} ${key}"
    elif [[ "${val}" == "-" ]]; then
        # gen_secrets.sh 의 `--body -` 버그로 등록된 값. 아래 판정부에서
        # 이 표식을 보고 정확한 원인을 안내한다.
        status="${C_ERR}값이 '-' — gh 버그 ◆${C_OFF}"
        DASH_LIST="${DASH_LIST} ${key}"
    elif [[ "${key}" == "ADMIN_INITIAL_PASSWORD" && "${len}" -lt 10 ]]; then
        status="${C_ERR}10자 미만 — 거부됨${C_OFF}"
        EMPTY_LIST="${EMPTY_LIST} ${key}"
    elif [[ "${key}" == "SECRET_KEY" && "${len}" -lt 16 ]]; then
        status="${C_ERR}너무 짧음 (48자여야 정상)${C_OFF}"
        EMPTY_LIST="${EMPTY_LIST} ${key}"
    else
        status="${C_OK}정상${C_OFF}"
    fi
    printf '  %-26s %8s  %b\n' "${key}" "${len}자" "${status}"
done <<< "$(echo "${REQUIRED}" | tr -s ' \n' '\n')"

# --------------------------------------------------------------------------
step "판정"
# --------------------------------------------------------------------------
# ── 원인이 확정된 케이스: 값이 전부 '-' 한 글자 ──────────────────────────
if [[ -n "${DASH_LIST// /}" ]]; then
    bad "값이 '-' 한 글자인 키:${DASH_LIST}"
    echo
    cat <<'GUIDE'
  원인이 확인되었습니다 — Secret 을 등록한 스크립트의 버그입니다.
  (Secret 이름이나 GitHub 설정 문제가 아닙니다)

  구버전 gen_secrets.sh 는 이렇게 등록했습니다:
      printf '%s' "$값" | gh secret set 이름 --body -

  gh 의 --body 는 "문자열 옵션" 이라서, '-' 를 표준입력 기호로 보지 않고
  **문자 '-' 그 자체를 값으로 저장**합니다. 파이프로 보낸 값은 버려집니다.
  그래서 Secrets 7개가 전부 '-' (1자) 로 등록되었습니다.
  (SECURITY_MODE 만 정상인 이유: 이건 Secret 이 아니라 워크플로 변수입니다)

  GitHub 목록에는 7개가 멀쩡히 등록된 것처럼 보입니다. GitHub 은 등록된
  값을 보여주지 않기 때문에, 길이를 재보지 않으면 알 수 없습니다.

  해결 — 최신 스크립트로 다시 등록하면 끝납니다:

      cd ~/Liinux- && git pull
      ./scripts/gen_secrets.sh --gh

    (7개 값이 새로 생성되어 덮어쓰기 됩니다. 등록 전에 값 전달 경로를
     자체 검증하므로 같은 문제가 다시 생기면 즉시 중단됩니다)

  그다음 배포 재실행:

      gh run rerun --failed        # 또는 웹에서 Re-run jobs
GUIDE
    exit 1
fi

if [[ -n "${EMPTY_LIST// /}" ]]; then
    bad "값이 비어 있거나 너무 짧은 키:${EMPTY_LIST}"
    echo
    cat <<'GUIDE'
  원인은 GitHub Secrets 쪽입니다. 배포는 Secrets 를 그대로 .env 에
  옮겨 적기 때문에, .env 가 비었다면 Secret 이 비었거나 이름이 다릅니다.

  확인 방법:
    https://github.com/tokimili/Liinux-/settings/secrets/actions

  주의할 점:
    - 이름은 대소문자까지 정확히 일치해야 합니다
      (ADMIN_INITIAL_PASSWORD — 앞뒤 공백이나 오타 확인)
    - 값을 붙여넣을 때 실수로 개행만 들어간 경우도 '비어 있음' 이 됩니다

  다시 등록하려면:
    cd ~/Liinux- && git pull
    ./scripts/gen_secrets.sh --gh
    (값이 새로 생성되며, 7개가 한 번에 덮어쓰기 됩니다)
GUIDE
    exit 1
fi

ok "필수 키 8개 모두 정상입니다"
echo
printf '  %s다음 단계 → GitHub Actions 에서 배포를 재실행하세요%s\n' "${C_INFO}" "${C_OFF}"
echo  "    gh run rerun --failed   또는 웹에서 Re-run jobs"
