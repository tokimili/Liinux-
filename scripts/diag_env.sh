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
step "키별 값 길이 (비밀값은 출력하지 않음)"
# --------------------------------------------------------------------------
# 반드시 값이 있어야 하는 키들. 비어 있으면 앱이 뜨지 않는다.
REQUIRED="SECRET_KEY DB_NAME DB_USER DB_PASSWORD MYSQL_ROOT_PASSWORD
          ADMIN_USERNAME ADMIN_INITIAL_PASSWORD SECURITY_MODE"

EMPTY_LIST=""
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
    elif [[ "${key}" == "ADMIN_INITIAL_PASSWORD" && "${len}" -lt 10 ]]; then
        status="${C_ERR}10자 미만 — 거부됨${C_OFF}"
        EMPTY_LIST="${EMPTY_LIST} ${key}"
    else
        status="${C_OK}정상${C_OFF}"
    fi
    printf '  %-26s %8s  %b\n' "${key}" "${len}자" "${status}"
done <<< "$(echo "${REQUIRED}" | tr -s ' \n' '\n')"

# --------------------------------------------------------------------------
step "판정"
# --------------------------------------------------------------------------
if [[ -n "${EMPTY_LIST// /}" ]]; then
    bad "값이 비어 있는 키:${EMPTY_LIST}"
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
    ./scripts/gen_secrets.sh --gh
    (값이 새로 생성되며, 7개가 한 번에 덮어쓰기 됩니다)
GUIDE
    exit 1
fi

ok "필수 키 8개 모두 정상입니다"
echo
printf '  %s다음 단계 → GitHub Actions 에서 배포를 재실행하세요%s\n' "${C_INFO}" "${C_OFF}"
echo  "    gh run rerun --failed   또는 웹에서 Re-run jobs"
