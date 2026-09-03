# VM 구축 가이드

아무것도 없는 상태에서 **CI/CD 자동 배포 + 외부 접속 + 관리자 대시보드**가
동작하는 VM 을 만드는 전체 순서입니다.

소요 시간: 약 60~90분 (도메인 네임서버 반영 대기 제외)

---

## 0. 전체 그림

```
   [개발자]  git push
       │
       ▼
   [GitHub]  ─ CI 실행 (lint / security / test / docker build)
       │        └ 실패하면 여기서 멈춤. 배포까지 못 감.
       │ CI 성공
       ▼
   ┌─────────────────────── 우리 집 VM ───────────────────────┐
   │  self-hosted 러너  ← 아웃바운드로 작업을 받아옴(pull)     │
   │       │                                                  │
   │       ▼ docker compose build & up                        │
   │  nginx :8080 ─→ web(gunicorn) :8000 ─→ MariaDB :3306     │
   │       ▲                                                  │
   │  cloudflared ── 아웃바운드 ──→ [Cloudflare 엣지]         │
   └──────────────────────────────────────────────────────────┘
                                          │
                                          ▼
                                   [인터넷 사용자]
                                   https://vmlab.example.com
```

**핵심: 인바운드 포트가 하나도 열리지 않습니다.**
러너도 터널도 VM 이 바깥으로 먼저 연결을 맺는 구조입니다.
공유기 포트포워딩이 필요 없고, 공인 IP 도 노출되지 않습니다.

---

## 1. VM 생성

### 사양

| 항목 | 최소 | 권장 | 이유 |
|---|---|---|---|
| CPU | 2 core | 4 core | Docker 빌드가 CPU 를 많이 씀 |
| RAM | 4 GB | 8 GB | MariaDB + 러너 + 빌드 동시 실행 |
| 디스크 | 40 GB | 60 GB | 이미지 레이어가 빠르게 쌓임 |
| OS | Ubuntu 22.04 LTS | Ubuntu 24.04 LTS | |

> 디스크를 20GB 로 잡으면 배포 몇 번 만에 가득 찹니다.
> Docker 는 이전 이미지를 자동으로 지우지 않습니다.

### 네트워크 어댑터 — 중요

VirtualBox / VMware 에서 어댑터를 **2개** 만듭니다.

| 어댑터 | 종류 | 용도 |
|---|---|---|
| 1 | **NAT** 또는 브리지 | 인터넷 연결 (러너·터널의 아웃바운드) |
| 2 | **호스트 전용(Host-only)** | Kali 공격 실습 전용, 인터넷 차단 |

어댑터 2 를 분리해두는 이유가 이 프로젝트의 안전선입니다.
`vulnerable` 모드 실습은 **호스트 전용 네트워크에서만** 하고,
인터넷에 노출되는 것은 `secure` 빌드뿐입니다.

### 설치 시 선택

- 사용자 계정 생성 (예: `vmlab`) — 이 계정으로 이후 작업을 합니다
- **OpenSSH server 설치 체크** — 이후 SSH 로 붙는 편이 편합니다
- 나머지 스냅 패키지는 전부 해제

---

## 2. 기본 세팅 — `vm_bootstrap.sh`

VM 에 로그인한 뒤:

```bash
sudo apt update && sudo apt install -y git
git clone https://github.com/tokimili/Liinux-.git
cd Liinux-
sudo ./scripts/vm_bootstrap.sh
```

이 스크립트가 하는 일:

| 작업 | 내용 |
|---|---|
| 패키지 | 시스템 업데이트 + 기본 도구 |
| Docker | **공식 저장소**에서 설치 (우분투 기본 `docker.io` 는 compose v2 플러그인이 없음) |
| 로그 회전 | `daemon.json` 으로 10MB × 3개 제한 — 없으면 컨테이너 로그가 디스크를 채움 |
| **방화벽** | 인바운드 **기본 차단**, SSH 만 허용. **8080 은 일부러 안 엽니다** |
| fail2ban | SSH 무차별 대입 차단. `jail.local` 에 작성 (`jail.conf` 는 업데이트 시 덮어써짐) |
| 자동 보안 업데이트 | `unattended-upgrades` |
| 커널 파라미터 | rp_filter, syncookies, redirect 차단, martian 로깅 |

마지막에 검증 6항목 + `hello-world` 실제 실행 결과가 나옵니다.

**끝나면 반드시 재로그인**하세요. `docker` 그룹 권한이 적용됩니다.

```bash
exit
# 다시 SSH 접속
docker ps      # sudo 없이 되면 성공
```

---

## 3. GitHub Secrets 등록 — `gen_secrets.sh`

> 이 단계를 건너뛰면 배포가 **"성공"으로 표시되지만 앱이 뜨지 않습니다.**
> `.env` 가 빈 값으로 만들어지기 때문입니다. 가장 찾기 어려운 종류의 실패입니다.

```bash
./scripts/gen_secrets.sh --gh      # gh CLI 로 자동 등록
# gh 가 없으면
./scripts/gen_secrets.sh           # 값만 출력 → 웹에서 수동 등록
```

등록해야 하는 시크릿 **8개**:

| 이름 | 값 | 출처 |
|---|---|---|
| `SECRET_KEY` | 48자 난수 | 스크립트 생성 |
| `DB_NAME` | `vmlab` | 고정 |
| `DB_USER` | `vmlab` | 고정 |
| `DB_PASSWORD` | 32자 난수 | 스크립트 생성 |
| `MYSQL_ROOT_PASSWORD` | 32자 난수 | 스크립트 생성 |
| `ADMIN_USERNAME` | `admin` | 고정 |
| `ADMIN_INITIAL_PASSWORD` | 20자 난수 | 스크립트 생성 |
| `CLOUDFLARE_TUNNEL_TOKEN` | Cloudflare 발급 | **5단계에서** |

앞의 7개를 먼저 등록하고, 터널 토큰은 5단계에서 추가하면 됩니다.

수동 등록 위치: `Settings → Secrets and variables → Actions → New repository secret`

> **`ADMIN_INITIAL_PASSWORD` 는 최초 로그인용입니다.** 로그인 후 즉시 변경하세요.

---

## 4. self-hosted 러너 설치 — `setup_runner.sh`

현재 GitHub 에서 `Deploy to VM` 워크플로가 **queued(대기)** 상태입니다.
`[self-hosted, linux, vmlab]` 라벨을 가진 러너가 없기 때문이며, 정상 동작입니다.
러너를 설치하는 순간 대기 중이던 배포가 **자동으로 실행**됩니다.

### 등록 토큰 발급 (유효기간 1시간)

```
https://github.com/tokimili/Liinux-/settings/actions/runners/new?arch=x64&os=linux
```

화면의 Configure 단계에서 이 줄을 찾습니다:

```
./config.sh --url https://github.com/tokimili/Liinux- --token AXXXXXXXXXXXXXXXX
```

**`--token` 뒤의 값만** 복사합니다.

### 설치

```bash
sudo ./scripts/setup_runner.sh
# 프롬프트에 토큰 붙여넣기
```

또는 한 줄로:

```bash
sudo ./scripts/setup_runner.sh --token AXXXXXXXXXXXXXXXX
```

스크립트가 하는 일:
- 러너 최신 버전을 API 로 조회해 다운로드 (버전 하드코딩 안 함)
- `self-hosted,linux,vmlab` 라벨로 등록 ← `deploy.yml` 과 일치해야 함
- **systemd 서비스**로 등록 → VM 재부팅해도 자동 시작
- 재설치 시 기존 러너를 먼저 정상 제거 (유령 러너 방지)

> 러너는 root 로 실행할 수 없습니다. GitHub 의 `config.sh` 자체가 거부합니다.
> 워크플로가 root 권한으로 임의 코드를 실행하게 되기 때문입니다.
> 그래서 `sudo` 로 실행하되 내부적으로 일반 계정으로 전환합니다.

### 확인

```
https://github.com/tokimili/Liinux-/settings/actions/runners
```
러너가 **Idle(초록)** 이면 정상입니다.

```
https://github.com/tokimili/Liinux-/actions
```
대기 중이던 배포가 돌기 시작합니다.

---

## 5. 외부 공개 — `setup_tunnel.sh`

### Cloudflare 준비 (최초 1회)

1. Cloudflare 계정 생성 (무료) — https://dash.cloudflare.com/sign-up
2. 도메인을 Cloudflare 에 연결
   - 네임서버를 Cloudflare 가 지정한 값으로 변경
   - 반영에 수십 분~수 시간

### 터널 생성

3. Zero Trust 대시보드 — https://one.dash.cloudflare.com
4. `Networks → Tunnels → Create a tunnel`
5. 커넥터 **Cloudflared** 선택 → 터널 이름 입력 (예: `vmlab`)
6. 설치 명령 화면에서 **`--token` 뒤 문자열만** 복사 (`eyJhIjoi...`)
7. `Public Hostnames` 탭 → `Add a public hostname`

   | 항목 | 값 |
   |---|---|
   | Subdomain | `vmlab` |
   | Domain | 본인 도메인 |
   | Type | `HTTP` |
   | URL | **`nginx:8080`** |

   > `localhost:8080` 이 아닙니다. cloudflared 도 컨테이너 안에서 돌기 때문에
   > 같은 Docker 네트워크의 **컨테이너 이름**으로 지정해야 합니다.

### 실행

```bash
./scripts/setup_tunnel.sh
```

스크립트가 켜기 전에 **두 번 확인**합니다:

1. `.env` 의 `SECURITY_MODE` 가 `secure` 인가
2. 실행 중인 앱의 `/healthz` 응답도 `secure` 인가
   (`.env` 는 secure 인데 컨테이너가 옛날 vulnerable 이미지일 수 있음)

하나라도 어긋나면 **터널을 켜지 않고 종료**합니다.

토큰은 `.env` 에 저장되지만, **GitHub Secrets 에도 등록**하세요.
등록하지 않으면 다음 배포 때 `.env` 가 새로 만들어지면서 토큰이 사라집니다.

```bash
gh secret set CLOUDFLARE_TUNNEL_TOKEN
```

### 관리

```bash
./scripts/setup_tunnel.sh --status   # 상태
./scripts/setup_tunnel.sh --down     # 내리기 (앱은 계속 동작)
```

---

## 6. 검증

### 배포 파이프라인

```bash
# 아무 파일이나 수정하고
git commit -am "test: 배포 확인" && git push
```

`https://github.com/tokimili/Liinux-/actions` 에서
CI 5개 job 통과 → Deploy 실행 순서로 진행되는지 확인합니다.

VM 에서:
```bash
docker compose ps            # 컨테이너 상태
curl -s localhost:8080/healthz | jq
```

`/healthz` 응답의 `commit` 이 방금 푸시한 커밋의 앞 7자리와 같으면
**CI/CD 가 실제로 그 코드를 배포한 것**입니다.

### 외부 접속 — 반드시 LTE 로

휴대폰에서 **Wi-Fi 를 끄고** 접속:

```
https://vmlab.본인도메인.com
```

> 집 Wi-Fi 로 접속하면 내부망으로 도는 것인지
> 진짜 외부에서 들어온 것인지 구분되지 않습니다.

### 관리자 대시보드

```
https://vmlab.본인도메인.com/admin
```

`ADMIN_USERNAME` / `ADMIN_INITIAL_PASSWORD` 로 로그인 →
**즉시 비밀번호 변경**.

접속 로그에 방금 휴대폰에서 들어온 요청이 기록돼 있으면
요구사항 #2(외부 접속)와 #3(대시보드)이 동시에 검증됩니다.

---

## 7. 문제 해결

### 배포가 계속 queued 상태

러너가 안 붙었거나 라벨이 다릅니다.

```bash
sudo systemctl status 'actions.runner.*'
sudo journalctl -u 'actions.runner.*' -n 50 --no-pager
```

`deploy.yml` 은 `[self-hosted, linux, vmlab]` 를 요구합니다.
러너 설정 화면에서 라벨 3개가 모두 있는지 확인하세요.

### 배포는 성공했는데 사이트가 안 뜸

거의 항상 **Secrets 미등록**입니다.

```bash
cd ~/Liinux- && cat .env | grep -E "^(SECRET_KEY|DB_PASSWORD)="
```

`=` 뒤가 비어 있으면 3단계를 다시 하고 재배포하세요.

### 로그인이 안 됨 (비밀번호는 맞는데)

`SESSION_COOKIE_SECURE=true` 인데 `http://` 로 접속한 경우입니다.
브라우저가 쿠키를 보내지 않습니다.

- 터널(HTTPS)로 접속하거나
- 로컬 테스트라면 `.env` 에서 `SESSION_COOKIE_SECURE=false`

### 터널이 HEALTHY 가 아님

```bash
docker logs -f vmlab-tunnel
```

- `Provided Tunnel token is not valid` → 토큰 재확인
- 연결은 되는데 502 → Public hostname 의 URL 이 `nginx:8080` 인지 확인

### 디스크가 가득 참

```bash
docker system df
docker image prune -a -f
docker builder prune -a -f
```

---

## 8. 안전 수칙

| 상황 | 규칙 |
|---|---|
| `vulnerable` 모드 실습 | **터널을 먼저 내린다** (`--down`), 호스트 전용 네트워크에서만 |
| 외부 공개 | `secure` 모드만. 스크립트가 강제하지만 습관으로도 확인 |
| 방화벽 | 8080 을 열지 않는다. 터널이 있으므로 불필요 |
| 공유기 | 포트포워딩 설정하지 않는다 |
| `.env` | 절대 커밋하지 않는다 (`.gitignore` 에 등록됨), 권한 600 |
| 최초 비밀번호 | 첫 로그인 후 즉시 변경 |

---

## 명령 요약

```bash
# 1) 기본 세팅
sudo ./scripts/vm_bootstrap.sh
exit && 재접속

# 2) 시크릿
./scripts/gen_secrets.sh --gh

# 3) 러너 (여기서 배포가 자동 시작됨)
sudo ./scripts/setup_runner.sh

# 4) 외부 공개
./scripts/setup_tunnel.sh

# 확인
docker compose ps
curl -s localhost:8080/healthz | jq
./scripts/setup_tunnel.sh --status
```
