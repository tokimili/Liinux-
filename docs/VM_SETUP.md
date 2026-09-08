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
| OS | Ubuntu 22.04 LTS | Ubuntu 24.04 / 26.04 LTS | 26.04(resolute) 확인됨 |

> 디스크를 20GB 로 잡으면 배포 몇 번 만에 가득 찹니다.
> Docker 는 이전 이미지를 자동으로 지우지 않습니다.

### 네트워크 어댑터 — NAT 하나로 충분합니다

**지금 단계에서는 기본 NAT 어댑터 1개만 있으면 됩니다.**
추가 설정 없이 VM 을 만드시면 됩니다.

이유는 이 구성의 모든 통신이 **아웃바운드**이기 때문입니다.

| 요구사항 | 통신 방향 | NAT 만으로 |
|---|---|---|
| #1 CI/CD 자동 배포 | 러너 → GitHub (아웃바운드) | ✅ |
| #2 외부 접속 | cloudflared → Cloudflare (아웃바운드) | ✅ |
| #3 관리자 대시보드 | 위 경로로 유입 | ✅ |

포트포워딩을 쓰는 구성이라면 브리지 어댑터가 필요했겠지만,
터널은 VM 이 바깥으로 먼저 연결을 맺으므로 NAT 뒤에서도 그대로 동작합니다.

#### 어댑터가 2개 필요해지는 시점 (Phase 3)

Kali 로 `vulnerable` 버전을 공격하는 실습을 할 때입니다.
VirtualBox NAT 는 **다른 VM 에서 접근이 안 되기** 때문에,
그때 호스트 전용(Host-only) 어댑터를 추가합니다.

```
VM 종료 → 설정 → 네트워크 → 어댑터 2 → 호스트 전용 활성화 → 시작
```

**1분이면 되고 재구축은 필요 없습니다.** 지금 미리 만들 이유가 없습니다.

> 실습 시 어댑터를 분리하는 이유는, 취약 버전을 인터넷에서 격리하기
> 위해서입니다. 호스트 전용 네트워크는 외부와 통신되지 않습니다.

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

마지막에 검증 9항목 + `hello-world` 실제 실행 결과가 나옵니다.

**끝나면 반드시 재로그인**하세요. `docker` 그룹 권한이 적용됩니다.

> **중간에 조용히 멈추면** — 스크립트에 ERR 트랩이 있어
> `[중단] N번째 줄에서 실패` 형태로 실패 지점을 반드시 출력합니다.
> 아무 메시지 없이 프롬프트로 돌아왔다면 그건 정상 종료입니다.
> (초기 버전은 이 트랩이 없어 ufw 단계에서 조용히 죽었고,
>  fail2ban 이 설정되지 않은 채 "설치 완료" 로 오해하게 만들었습니다.)

#### Ubuntu 24.04 이상에서 특히 중요한 부분

24.04 부터 `rsyslog` 가 기본 설치되지 않아 **`/var/log/auth.log` 파일이 없습니다.**
SSH 인증 로그가 systemd journal 에만 남기 때문에, fail2ban 이
journal 을 읽을 수 있어야 합니다(`backend = systemd` + `python3-systemd`).

이 조건이 빠지면 **fail2ban 서비스는 정상 실행되지만 sshd jail 만 조용히
죽어서, 무차별 대입이 전혀 차단되지 않는 상태**가 됩니다.
"방화벽은 켜져 있으니 안전하다"고 착각하기 가장 쉬운 지점입니다.

스크립트가 `python3-systemd` 를 설치하고, 검증 단계에서
서비스 상태가 아니라 **jail 활성 여부**를 직접 확인합니다.
직접 점검하려면:

```bash
sudo fail2ban-client status          # sshd 가 목록에 있어야 정상
sudo fail2ban-client status sshd     # 감시 중인 로그 경로 확인
```

```bash
exit
# 다시 SSH 접속
docker ps      # sudo 없이 되면 성공
```

---

## 2-1. VM 에 SSH 로 접속하기 (NAT 환경)

VirtualBox 콘솔 창은 한글이 `◆◆◆` 로 깨지고 복사·붙여넣기가 안 됩니다.
**이후 모든 작업은 SSH 로 하는 것을 권장합니다.**

### 왜 포트 포워딩이 필요한가

NAT 어댑터에서 VM 의 IP 는 `10.0.2.15` 인데, 이 주소는 **VM 내부에서만
유효한 사설 주소**입니다. 호스트에서 `ssh vboxuser@10.0.2.15` 를 하면
연결되지 않습니다. NAT 는 VM→외부(아웃바운드)만 통과시키기 때문입니다.

반대 방향(호스트→VM)을 열려면 VirtualBox 에 "이 포트로 들어온 접속은
VM 의 22번으로 넘겨라" 라고 규칙을 하나 등록해야 합니다.
이것이 **포트 포워딩**이며, 공유기 설정과는 무관합니다.
(호스트 안에서만 일어나는 일이라 외부에 열리는 구멍이 없습니다.)

### 설정 (VM 실행 중에도 가능)

VirtualBox → 해당 VM → **설정 → 네트워크 → 어댑터 1 →
고급 → 포트 포워딩 → `+`**

| 이름 | 프로토콜 | 호스트 IP | 호스트 포트 | 게스트 IP | 게스트 포트 |
|---|---|---|---|---|---|
| ssh | TCP | `127.0.0.1` | `2222` | *(비움)* | `22` |

- **호스트 IP 를 `127.0.0.1` 로 지정하는 이유**: 비우면 호스트의 모든
  인터페이스에 열려, 같은 공유기에 있는 다른 기기도 접속을 시도할 수
  있습니다. 내 PC 에서만 쓸 통로이므로 좁혀둡니다.
- 게스트 IP 는 비워두면 VM 을 자동으로 찾습니다.
- 호스트 포트 `2222` 는 임의입니다. 이미 쓰고 있다면 `2223` 등으로 바꾸세요.

### 접속

호스트(내 PC)의 터미널에서 — PowerShell / CMD / macOS 터미널 모두 동일:

```bash
ssh -p 2222 vboxuser@127.0.0.1
```

`-p 2222` 를 빼먹으면 VM 이 아니라 **내 PC 자신**에 접속을 시도해
`Connection refused` 가 납니다. 가장 흔한 실수입니다.

처음 접속 시 `Are you sure you want to continue connecting?` 는 `yes`.

### 붙여넣기 단축키

| 환경 | 붙여넣기 |
|---|---|
| **Windows Terminal / PowerShell / CMD** | `Ctrl` + `V` (또는 **마우스 우클릭**) |
| **VS Code 터미널** | `Ctrl` + `Shift` + `V` |
| **macOS 터미널 / iTerm2** | `Cmd` + `V` |
| **Linux (GNOME 터미널 등)** | `Ctrl` + `Shift` + `V` |
| PuTTY | **마우스 우클릭** (Ctrl+V 아님) |

> **주의 — 터미널에서 `Ctrl`+`C` 는 복사가 아닙니다.**
> 실행 중인 프로그램을 **강제 종료**하는 신호입니다.
> 복사는 `Ctrl`+`Shift`+`C`, 또는 마우스로 드래그 선택하세요.
> (Windows Terminal 은 선택하면 자동 복사됩니다.)

### 접속이 안 될 때

```bash
# VM 콘솔에서 — SSH 서버가 떠 있는지
sudo systemctl status ssh

# 방화벽이 SSH 를 허용하는지
sudo ufw status
```

`ssh` 서비스가 없다면 VM 콘솔에서 설치:

```bash
sudo apt install -y openssh-server
sudo systemctl enable --now ssh
```

> **호스트에서 오는 SSH 는 fail2ban 에 차단되지 않습니다.**
> NAT 환경에서 호스트는 VM 에게 `10.0.2.2` 로 보이고, `jail.local` 의
> `ignoreip` 에 `10.0.0.0/8` 이 들어 있어 제외 대상입니다.
> 비밀번호를 여러 번 틀려도 잠기지 않으니 안심하고 시도하세요.
>
> 만약 다른 대역에서 붙다가 차단됐다면 VM 콘솔에서 해제합니다:
> ```bash
> sudo fail2ban-client status sshd              # 차단된 IP 확인
> sudo fail2ban-client set sshd unbanip <IP>
> ```
>
> 이 `ignoreip` 는 **로컬 실습 편의를 위한 설정**입니다.
> Phase 3(취약 버전 공격 실습)에서 Kali VM 이 같은 사설 대역에 있으면
> 차단 동작을 관찰할 수 없으니, 그때는 해당 대역을 `ignoreip` 에서
> 빼야 합니다. 실습 시점에 다시 안내합니다.

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

### 등록이 잘 됐는지 확인하는 방법

GitHub 은 **등록된 Secret 값을 다시 보여주지 않습니다.** 목록에 이름 7개가
보이더라도 값이 올바른지는 알 수 없습니다. 그래서 배포가 한 번 돌고 나면
반드시 이걸로 확인하세요:

```bash
./scripts/diag_env.sh
```

배포가 만든 `.env` 의 **값 길이만** (비밀값은 출력하지 않음) 보여줍니다.
`SECRET_KEY` 가 48자, `ADMIN_INITIAL_PASSWORD` 가 20자면 정상입니다.

### 실제로 겪은 함정 — `gh secret set --body -`

값이 전부 **`-` 한 글자**로 등록되어 배포가 실패한 일이 있었습니다.
원인은 구버전 `gen_secrets.sh` 의 이 한 줄이었습니다:

```bash
printf '%s' "$값" | gh secret set 이름 --body -    # ← 틀림
```

`gh` 의 `--body` 는 **문자열 옵션**입니다. `curl`/`tar` 처럼 `-` 를
표준입력으로 해석하지 않고, **문자 `-` 자체를 값으로 저장**합니다.
`gh` 소스( `pkg/cmd/secret/set/set.go` 의 `getBody` )가 그 근거입니다:

```go
if opts.Body != "" { return []byte(opts.Body), nil }  // "-" 는 여기서 반환됨
...
body, err := io.ReadAll(opts.IO.In)                   // stdin 은 여기까지 와야 읽힘
```

올바른 방법은 **`--body` 를 생략하고 stdin 으로만 넘기는 것**입니다.
(값이 `ps` 에 노출되지 않는 장점도 있습니다.)

```bash
printf '%s' "$값" | gh secret set 이름               # ← 맞음
```

이 실패가 특히 고약했던 이유:

- `gh` 가 **종료코드 0(성공)** 을 반환하므로 스크립트는 이상을 감지 못 함
- GitHub 목록에도 7개가 정상 등록된 것처럼 보임
- 증상은 한참 뒤 배포 마지막 단계에서
  `ADMIN_INITIAL_PASSWORD 가 10자 미만입니다` 로 나타남

현재 스크립트는 등록 **전에** `--no-store` 로 값 전달 경로를 자체 검증하므로
같은 문제가 다시 생기면 즉시 중단됩니다.

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

두 가지 경로가 있습니다. **도메인이 없으면 A 를 쓰세요.**

| | A. Quick Tunnel | B. Named Tunnel |
|---|---|---|
| 도메인 | **불필요** | 필요 |
| Cloudflare 계정 | **불필요** | 필요 |
| 주소 | `https://랜덤.trycloudflare.com` | `https://vmlab.내도메인.com` |
| 주소 유지 | 재시작 시 **변경됨** | 고정 |
| 준비 시간 | **30초** | 1~2시간 (네임서버 반영) |
| HTTPS | 자동 | 자동 |
| 용도 | 개발·시연·검증 | 포트폴리오 제출 |

요구사항 #2("VM이 켜져 있는 동안 다른 곳에서도 접속 가능")는
**A 로 완전히 충족됩니다.** 앱·배포 구조는 A/B 가 완전히 동일해서,
나중에 도메인이 생기면 B 로 바꾸기만 하면 됩니다.

---

### A. Quick Tunnel — 도메인 없이 즉시 공개

```bash
./scripts/setup_tunnel.sh --quick
```

이게 전부입니다. 30초 정도 뒤에 주소가 출력됩니다:

> **참고 — 실행 위치는 신경쓰지 않아도 됩니다.**
> `git clone` 한 `~/Liinux-` 에는 `.env` 가 없습니다(배포는 러너의 작업
> 디렉터리에서 이뤄집니다). 스크립트가 `.env` 가 있는 작업 디렉터리를
> 스스로 찾아 이동하고, 아래처럼 알려줍니다:
>
> ```
>   ▲ 여기에는 .env 가 없습니다. 배포가 만든 작업 디렉터리로 이동합니다:
>       /opt/actions-runner/_work/Liinux-/Liinux-
> ```
>
> 만약 `그 디렉터리에 들어갈 권한이 없습니다` 가 나오면 안내대로
> `sudo` 를 붙여 다시 실행하세요.

```
  ╔══════════════════════════════════════════════════════════╗
  ║  외부 접속 주소 (HTTPS 자동 적용)                        ║
  ╚══════════════════════════════════════════════════════════╝

      https://brave-lion-tasty-mint.trycloudflare.com

      관리자 대시보드: https://brave-lion-tasty-mint.trycloudflare.com/admin
```

주소를 잊었으면:
```bash
./scripts/setup_tunnel.sh --status
```

**한계 — 알고 쓰셔야 합니다**

- 주소가 **재시작할 때마다 바뀝니다.** 컨테이너를 내리면 사라집니다
- Cloudflare 가 가용성을 보장하지 않습니다 (테스트용 무료 서비스)
- 그래서 포트폴리오 문서에 이 주소를 적어두면 나중에 깨집니다

접속자 IP 는 정상 기록됩니다. 앱이 `CF-Connecting-IP` 헤더를
최우선으로 읽기 때문에, Quick Tunnel 에서도 대시보드에
실제 접속자 IP 가 남습니다 (터널 서버 IP 가 아님).

---

### B. Named Tunnel — 고정 주소 (도메인 필요)

포트폴리오 제출용으로 안 바뀌는 주소가 필요할 때 진행하세요.
지금 당장은 건너뛰어도 됩니다.

#### Cloudflare 준비 (최초 1회)

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

#### 실행

```bash
./scripts/setup_tunnel.sh        # 옵션 없이 → Named Tunnel
```

토큰은 `.env` 에 자동 저장되지만, **GitHub Secrets 에도 등록**하세요.
등록하지 않으면 다음 배포 때 `.env` 가 새로 만들어지면서 토큰이 사라집니다.

```bash
gh secret set CLOUDFLARE_TUNNEL_TOKEN
```

---

### 공통 — 사고를 막는 장치

A/B 어느 경로든 터널을 켜기 전에 **두 번 확인**합니다:

1. `.env` 의 `SECURITY_MODE` 가 `secure` 인가
2. 실행 중인 앱의 `/healthz` 응답도 `secure` 인가

2번을 따로 보는 이유는, `.env` 는 secure 로 바꿨지만
컨테이너는 아직 이전 vulnerable 이미지로 돌고 있는 상태를
파일만 보면 놓치기 때문입니다.

하나라도 어긋나면 **터널을 켜지 않고 중단**합니다(exit 1).

### 공통 — 관리 명령

```bash
./scripts/setup_tunnel.sh --status   # 상태 + 현재 공개 주소
./scripts/setup_tunnel.sh --down     # 내리기 (앱은 계속 동작)
```

`--down` 은 A/B 둘 다 내리고, 정말 사라졌는지 확인합니다.
어느 방식을 켰었는지 기억하지 않아도 "노출 없음"이 보장됩니다.

---

## 5-1. 자기복구 자동화 (재부팅·터널 끊김 대비)

CI/CD 는 **push 가 있을 때만** 동작합니다. 그래서 아래 상황은 파이프라인이
정상이어도 자동으로 낫지 않고, VM 에 접속해 손으로 고쳐야 했습니다.

- VM 재부팅 → 컨테이너는 살아나지만 **Quick Tunnel 은 profile 밖**이라
  죽은 채 남습니다. 앱은 정상인데 외부 주소만 안 열립니다.
- 터널이 Cloudflare 쪽 사정으로 끊김 → 아무 트리거도 없어 방치됩니다.
- 배포 실패로 VM 이 옛 커밋에 머묾(드리프트).
- 러너 프로세스 사망 → 배포 자체가 시작되지 않습니다.

### 설치 (1회)

```bash
cd ~/Liinux-
sudo ./scripts/setup_autoheal.sh              # 기본 1분 주기
sudo ./scripts/setup_autoheal.sh --interval 5min
```

systemd timer 로 등록됩니다. cron 대신 timer 를 쓰는 이유는 ① 부팅 직후
실행(`OnBootSec=90s`)을 정확히 표현할 수 있고 ② 로그가 journald 로 모이며
③ 이전 실행이 안 끝났으면 겹쳐 돌지 않기 때문입니다(1분 주기에서 compose
명령이 겹치면 충돌합니다).

### 확인

```bash
systemctl status vmlab-autoheal.timer
journalctl -u vmlab-autoheal -f
sudo /usr/local/bin/vmlab-autoheal --dry-run   # 무엇을 할지 미리보기
cat /var/lib/vmlab/tunnel_url                  # 현재 외부 주소
```

### 무엇을 하는가

| 순서 | 점검 | 조치 |
|------|------|------|
| 1 | `SECURITY_MODE` | `vulnerable` 이면 **터널을 내린다** (노출 차단) |
| 2 | `/healthz` | 실패 시 db/web/nginx 기동, 최대 60초 대기 |
| 3 | 실행 중인 `mode` | secure 가 아니면 터널을 내리고 중단 |
| 4 | 터널 | 멈춰 있으면 재기동, 새 주소를 기록 |
| 5 | main 해시 vs 실행 커밋 | 드리프트 보고. 러너가 죽었으면 재시작 |

**직접 빌드·배포하지 않습니다.** 그렇게 하면 CI 의 테스트 게이트를
우회하게 됩니다. 러너만 되살려 GitHub Actions 가 정상 경로로 배포하게 합니다.

### 실습할 때 방해되지 않는가

되지 않습니다. `--down` 은 터널 컨테이너를 `stop` 이 아니라 `rm -f` 로
**삭제**하고, autoheal 은 "존재하는데 멈춘" 컨테이너만 되살립니다.
즉 사용자가 의도적으로 내린 터널은 그대로 둡니다.
`vulnerable` 모드에서는 이중으로, 오히려 노출을 차단합니다.

오래 멈춰두고 싶다면:

```bash
sudo systemctl stop vmlab-autoheal.timer      # 일시 중지
sudo ./scripts/setup_autoheal.sh --uninstall  # 완전 제거
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

공개 주소를 확인하고:
```bash
./scripts/setup_tunnel.sh --status
```

휴대폰에서 **Wi-Fi 를 끄고(LTE)** 그 주소로 접속합니다.

> 집 Wi-Fi 로 접속하면 내부망으로 도는 것인지
> 진짜 외부에서 들어온 것인지 구분되지 않습니다.

### 관리자 대시보드

공개 주소 끝에 `/admin` 을 붙입니다.

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

### 배포는 성공했는데 사이트가 안 뜸 / `.env` 를 확인하고 싶다

거의 항상 **Secrets 문제**(미등록 또는 값이 잘못 등록됨)입니다.

```bash
./scripts/diag_env.sh
```

> ⚠️ **`~/Liinux-/.env` 를 보면 안 됩니다.** 거기엔 파일이 없습니다.
>
> 배포는 여러분이 `git clone` 한 `~/Liinux-` 에서 돌지 않습니다.
> self-hosted 러너는 `actions/checkout` 으로 **자기 작업 디렉터리에**
> 소스를 새로 내려받고, `.env` 도 그곳에 만듭니다:
>
> ```
> /opt/actions-runner/_work/Liinux-/Liinux-/.env
> ```
>
> `diag_env.sh` 는 이 경로를 자동으로 찾아주고, 비밀값을 화면에 찍지 않고
> **길이만** 보여줍니다. 직접 찾고 싶다면:
>
> ```bash
> sudo find / -maxdepth 6 -type d -name '_work' 2>/dev/null
> ```

값이 비어 있거나 짧으면 3단계를 다시 하고 재배포하세요.

### 로그인이 안 됨 (비밀번호는 맞는데)

`SESSION_COOKIE_SECURE=true` 인데 `http://` 로 접속한 경우입니다.
브라우저가 쿠키를 보내지 않습니다.

- 터널(HTTPS)로 접속하거나
- 로컬 테스트라면 `.env` 에서 `SESSION_COOKIE_SECURE=false`

### `setup_tunnel.sh` 가 `.env 를 찾지 못했습니다` 로 멈춤

`.env` 는 **배포가 러너의 작업 디렉터리에 만듭니다.**
`git clone` 한 `~/Liinux-` 에는 없습니다 — 러너가 `actions/checkout` 으로
자기 작업 디렉터리에 소스를 새로 내려받아 거기서 배포하기 때문입니다.

```
/opt/actions-runner/_work/Liinux-/Liinux-/.env     ← 여기
~/Liinux-/.env                                     ← 없음
```

스크립트는 이 경로를 자동으로 찾습니다. 그래도 못 찾았다면 둘 중 하나입니다.

- **배포를 아직 한 번도 성공시키지 않았다** → Actions 에서 배포를 돌리세요.
- **수동으로 운영하려는 것이다** → `./scripts/gen_secrets.sh --env`

에러 메시지에 "찾아본 경로" 목록이 함께 출력되므로 그걸 먼저 보세요.
`./scripts/diag_env.sh` 로 현재 `.env` 상태를 점검할 수도 있습니다.

### `Conflict. The container name "/vmlab-db" is already in use`

compose 가 **다른 프로젝트 이름으로** 동작했다는 신호입니다.
프로젝트 이름 결정 우선순위는 이렇습니다:

```
-p 옵션  >  COMPOSE_PROJECT_NAME  >  파일의 name:  >  실행한 디렉터리 이름
```

배포 워크플로는 `COMPOSE_PROJECT_NAME=vmlab` 을 주지만, 터미널에서 직접
실행할 때는 그 환경변수가 없습니다. 그러면 디렉터리 `Liinux-` 에서
`liinux-` 를 유추해버립니다 → **실행 중인 `vmlab` 스택이 아예 안 보임**
→ `db`/`web`/`nginx` 를 새로 만들려 드는데 `container_name` 이
`vmlab-db` 로 고정돼 있어 이름이 충돌합니다.

`docker-compose.yml` 에 `name: vmlab` 을 넣어뒀지만 **그것만으로는
부족합니다.** 러너 작업 디렉터리에는 배포 시점의 옛 커밋이 체크아웃돼
있어서 그 파일에는 `name:` 이 없을 수 있습니다.

그래서 `setup_tunnel.sh` 는 `-p vmlab` 을 항상 명시하고,
`--no-deps` 로 터널 컨테이너만 띄웁니다(실행 중인 앱을 건드리지 않음).

직접 compose 를 쓸 때도 **항상 `-p vmlab` 을 붙이세요**:

```bash
sudo docker compose -p vmlab ps
sudo docker compose -p vmlab down -v
```

잘못된 이름으로 만들어진 잔여물(네트워크·빈 볼륨)은 이렇게 지웁니다:

```bash
sudo docker compose -p liinux- down -v
```

### 터널이 HEALTHY 가 아님

```bash
docker logs -f vmlab-tunnel
```

- `Provided Tunnel token is not valid` → 토큰 재확인
- 연결은 되는데 502 → Public hostname 의 URL 이 `nginx:8080` 인지 확인

### 배포가 `Access denied` / 마이그레이션에서 실패

`DB_PASSWORD` 를 바꾼 뒤에 발생합니다. **DB 볼륨에 옛 비밀번호가 남아 있습니다.**

MariaDB 는 `MARIADB_PASSWORD` 환경변수를 **볼륨이 빈 상태로 처음 초기화될
때만** 사용합니다. 볼륨이 이미 있으면 환경변수는 완전히 무시되고 볼륨 안에
저장된 옛 비밀번호가 계속 쓰입니다.

그래서 증상이 헷갈립니다 — **DB 컨테이너는 `healthy` 로 잘 뜨는데
마이그레이션만 실패**합니다. 기동은 비밀번호와 무관하기 때문입니다.

```bash
cd /opt/actions-runner/_work/Liinux-/Liinux-
sudo docker compose down -v          # -v 로 볼륨까지 삭제
sudo docker volume ls | grep vmlab   # 아무것도 안 나와야 정상
```

> ⚠️ `-v` 는 DB 데이터를 모두 지웁니다. 초기 구축 중이라면 문제없습니다.
> 보존할 데이터가 있으면 먼저 백업하세요:
> ```bash
> sudo docker compose exec db mariadb-dump -uroot \
>   -p"$MYSQL_ROOT_PASSWORD" --all-databases > backup.sql
> ```

그다음 배포를 다시 실행하면 볼륨이 새 비밀번호로 초기화됩니다.

### `down -v` 를 했는데 볼륨이 그대로 남아 있음

**compose 프로젝트 이름이 갈렸을 때** 생깁니다. 실제로 겪은 문제입니다.

compose 는 프로젝트 이름으로 리소스 이름을 만듭니다(`<프로젝트>_db_data`).
이름을 지정하지 않으면 **실행한 디렉터리 이름**에서 유추합니다.

| 실행 주체 | 프로젝트명 | 볼륨 이름 |
|---|---|---|
| 배포 워크플로 (`COMPOSE_PROJECT_NAME=vmlab`) | `vmlab` | `vmlab_db_data` |
| 사람이 터미널에서 직접 (`Liinux-` 디렉터리) | `liinux-` | `liinux-_db_data` |

즉 `down -v` 가 **존재하지 않는 `liinux-_db_data`** 를 대상으로 삼아
**아무것도 지우지 않고 조용히 성공**합니다. `down` 은 지울 게 없어도 오류를
내지 않으므로 알아채기 어렵습니다. (출력이 한 줄도 없으면 이 상황입니다)

지금은 `docker-compose.yml` 최상단에 `name: vmlab` 을 박아 해결했습니다.
어디서 실행하든 항상 `vmlab` 입니다. 확인:

```bash
sudo docker compose config | head -3     # name: vmlab 이 보여야 정상
```

구버전을 쓰고 있다면 프로젝트명을 명시하세요:

```bash
sudo docker compose -p vmlab down -v
# 또는 볼륨을 직접 지정
sudo docker volume rm vmlab_db_data
```

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
| Quick Tunnel 사용 시 | 주소가 재시작마다 바뀐다. 문서에 적어두지 않는다 |
| 외부 공개 | `secure` 모드만. 스크립트가 강제하지만 습관으로도 확인 |
| 방화벽 | 8080 을 열지 않는다. 터널이 있으므로 불필요 |
| 공유기 | 포트포워딩 설정하지 않는다 |
| `.env` | 절대 커밋하지 않는다 (`.gitignore` 에 등록됨), 권한 600 |
| 최초 비밀번호 | 첫 로그인 후 즉시 변경 |
| SSH 인증 | 공개키로 전환 후 `PasswordAuthentication no` 권장 |

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

# 4) 외부 공개 — 도메인 없으면 --quick
./scripts/setup_tunnel.sh --quick

# 5) 자기복구 — 재부팅/터널끊김을 사람 손 없이 되돌린다
sudo ./scripts/setup_autoheal.sh

# 확인
sudo docker compose -p vmlab ps       # ★ -p vmlab 필수 (없으면 스택이 안 보인다)
curl -s localhost:8080/healthz | jq
./scripts/setup_tunnel.sh --status    # 공개 주소 확인
journalctl -u vmlab-autoheal -n 20 --no-pager
```

요구사항 #1~#3 은 여기서 다 끝납니다.
도메인은 포트폴리오에 고정 주소를 싣고 싶어질 때 추가하면 되며,
그때 앱이나 배포 구조는 전혀 바꿀 필요가 없습니다.
