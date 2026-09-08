# VM Security Lab — 로컬 VM 보안 실습 & CI/CD 배포 플랫폼

보안 포트폴리오 로드맵의 Phase 1~2 배포 대상 웹 서비스입니다.
**하나의 코드베이스**를 `SECURITY_MODE` 환경변수로 전환해
"취약 → 방어" Before/After 를 증명하는 구조입니다.

## 프로젝트 목표 (사용자 요구사항)

| # | 요구사항 | 현재 상태 |
|---|---------|----------|
| 1 | CI/CD 로 VM 에 자동 배포 | ✅ **완료 (실제 배포 성공)** |
| 2 | 로컬 VM 에서 확인 + 외부 접속 가능 | ✅ **완료 (외부망에서 접속 검증)** |
| 3 | 관리자 대시보드에서 접속 기록 확인 | ✅ **완료 (3개 망 접속을 IP로 구분 기록)** |

세 가지 요구사항이 **한 번에 교차 검증**되었습니다 — 외부 네트워크에서
터널 주소로 접속해 대시보드를 열었고, 그 접속이 **접속자의 실제 IP로**
접속 로그에 기록된 것을 같은 대시보드에서 확인했습니다(아래 §검증 결과).

## 아키텍처 결정 (중요)

1. **CI/CD 는 pull 방식** — GitHub Actions **self-hosted runner 를 VM 안에** 설치합니다.
   GitHub 이 NAT 뒤의 가정용 VM 으로 접속(push)할 수 없기 때문입니다.
   VM 이 GitHub 을 폴링하므로 **인바운드 포트를 열지 않아도** 자동 배포됩니다.
2. **외부 노출은 Cloudflare Tunnel** — 공유기 포트포워딩을 쓰지 않습니다.
   `cloudflared` 가 아웃바운드로만 연결하므로 방화벽에 구멍이 생기지 않고,
   로드맵 §2 윤리 규칙(공유기 설정 변경 금지)에도 부합합니다.
3. 🔴 **외부에 노출하는 것은 `secure` 모드뿐입니다.**
   `vulnerable` 모드는 호스트 전용 네트워크에서 Kali VM 으로만 접근합니다.
   의도적 취약점을 인터넷에 노출하면 실제로 가정 네트워크가 침해됩니다.
4. **Cloudflare Pages 는 사용하지 않습니다.** ufw / fail2ban / WAF / 로그 분석이
   불가능해 포트폴리오의 핵심 증거가 사라지기 때문입니다.
   샌드박스는 **개발·검증 환경**, VM 이 **런타임**입니다.

## 완료된 기능

### 관리자 대시보드 (요구사항 #3)
- **KPI 8종**: 총요청 / 고유IP / 위협탐지 / 오류응답 / 평균응답 / 로그인실패 / 미처리경보 / 차단IP
- **차트 2종**: 시간대별 트래픽 추이(line), 상태코드 분포(doughnut) — Chart.js, 15초 자동 갱신
- **접속 로그 검색**: IP / 경로 / 메서드 / 상태(2xx~5xx) / 사용자 / 위협만 / 최소점수 / 기간 — 전부 파라미터 바인딩
- **CSV 내보내기**: UTF-8 BOM, 한글 헤더, 1만건 상한
- **보안 이벤트**: 심각도별 집계 + 상세 + 처리완료 표시
- **로그인 시도**: 브루트포스 용의자 자동 추출(24시간 내 5회 이상 실패)
- **IP 분석**: IP별 통계 + 수동 차단/해제
- **배포 이력**: CI/CD 배포 기록 (커밋·버전·실행자·모드)
- **시스템**: DB/로그writer 상태, 테이블 용량, 로그 파기

### 접속 로그 수집 파이프라인
`after_request` 훅 → 민감값 마스킹 → 위협 스코어링 → 큐 적재 → 백그라운드 스레드 배치 INSERT.
큐 상한(2000)·드롭 카운터·예외 전면 흡수로 **로깅이 응답 지연이나 장애로 번지지 않습니다.**

### 위협 탐지 (IDS)
경로·쿼리·본문을 **2단 URL 디코딩** 후 정규식 매칭 + 스캐너 UA 지문.
점수 0~100, 태그 `sqli/xss/traversal/cmdi/ssrf/ssti/deser/scanner_ua`.
35점 이상은 `security_events` 에 즉시 경보 기록.

### 보안 통제 (secure 모드)
scrypt 해싱 · 타이밍공격 대비 더미해시 · 브루트포스 잠금(IP+계정) · 세션 재발급(고정공격 방어)
· CSRF 토큰(constant-time 비교) · CSP/HSTS/X-Frame-Options/nosniff/Referrer-Policy
· 파라미터 바인딩 · 소유권 검증(IDOR) · 업로드 3중 검증(화이트리스트+매직바이트+이중확장자)
· 오픈리다이렉트 차단 · 계정열거 방지 · 스택트레이스 미노출(OWASP A10)

### 의도적 취약점 (vulnerable 모드)
| ID | 취약점 | 위치 |
|----|-------|------|
| VULN-01 | 로그인 SQLi (인증 우회) | `auth.py` |
| VULN-02 | 검색 SQLi (UNION) | `board.py` |
| VULN-03 | 저장형 XSS | `board/view.html` (`\|safe` 분기) |
| VULN-04 | IDOR | `board.py` edit_post |
| VULN-05 | 무제한 업로드 (웹셸) | `board.py` _handle_upload |

## 검증 결과

### 요구사항 #1 — CI/CD 자동 배포

`git push` → VM 의 self-hosted runner 가 배포 → 15단계 전원 통과:

```
✓ 소스 체크아웃       ✓ 이미지 빌드        ✓ 관리자 계정 보장
✓ 배포 대상 커밋 확인  ✓ DB 컨테이너 기동    ✓ 배포 실행 (헬스체크 게이트)
✓ 환경변수 파일 생성   ✓ 스키마 마이그레이션  ✓ 배포 이력 기록
✓ 배포 전 상태 저장   ✓ 배포 후 검증       ✓ 외부 공개 터널 기동

[deploy] 헬스체크 통과 (2초)
[deploy] 배포 성공 (mode=secure)
✅ 리비전 확인: <커밋해시>     ✅ 보안 모드 확인: secure
```

푸시 후 `/healthz` 의 `commit`/`version` 이 새 커밋으로 바뀌어
**배포가 실제로 일어난 것을 외부에서 원격으로 확인**했습니다.

### 요구사항 #2 — 외부 접속 (다른 네트워크에서 실증)

Cloudflare Quick Tunnel 주소로 **VM 과 무관한 외부 네트워크**에서 접속:

```
GET /healthz → {"status":"ok","mode":"secure","db":{"ok":true,"latency_ms":0.43}}
GET /        → HTTP/2 200   0.377s   4240 bytes

응답 헤더 실측:
  strict-transport-security: max-age=31536000; includeSubDomains
  content-security-policy: default-src 'self'; script-src 'self' ... object-src 'none'
  x-frame-options: DENY      x-content-type-options: nosniff
  referrer-policy: strict-origin-when-cross-origin
  permissions-policy: geolocation=(), microphone=(), camera=(), payment=()
```

HTTPS 는 터널이 자동 적용합니다. **공유기 포트를 하나도 열지 않았습니다.**

### 요구사항 #3 — 접속 기록 (서로 다른 망을 IP로 구분)

터널로 로그인한 뒤 `/admin/logs` 에서 집계된 접속자 IP:

```
 24건  170.106.xxx.xxx   ← 외부 네트워크 (해외, 터널 경유)
  2건  59.5.xxx.x        ← 사용자 가정망 (한국)
  2건  172.19.0.1        ← VM 내부 (docker 네트워크)
```

터널 서버 IP 가 아니라 **진짜 클라이언트 IP** 가 남습니다.
nginx 가 `CF-Connecting-IP` 를 전달하고 앱이 그것을 우선 읽기 때문입니다.
이게 없다면 대시보드에 모든 접속이 Cloudflare IP 하나로 보여 무용해집니다.

**IPv6 도 정상 처리됩니다.** 휴대폰 LTE 접속이 실제로 IPv6 로 들어왔고,
IPv4 전제로 깨지기 쉬운 지점을 전부 실측했습니다.

```
저장    ip VARCHAR(45)  ← IPv6 최대 표기 길이가 정확히 45자
        (ffff:ffff:ffff:ffff:ffff:ffff:255.255.255.255)
        휴대폰 IPv6 는 37자 → 절단 없이 그대로 저장됨
검증    _is_valid_ip() 가 ipaddress.ip_address() 사용 → v4/v6 무관
로그검색 /admin/logs?ip=<IPv6>          → 200, 해당 행만 정확히 필터
집계    /admin/ips                      → IPv6 별로 정상 집계
차단    POST /admin/ips/block  ip[:45]  → 302, 목록 등록 확인
해제    POST /admin/ips/unblock         → 302, 목록에서 제거 확인
```

차단/해제 테스트는 RFC3849 문서용 예약 대역(`2001:db8::/32`)으로 수행하고
검증 후 원상복구했습니다. 사용자 실제 IP 는 건드리지 않았습니다.

### 방어 동작 (터널 경유 실측, secure 모드)

```
/admin/          비로그인  → 302 /auth/login?next=/admin/   (게이트 정상)
SQLi  ?ip=' OR 1=1--         → 200, DB 오류/스택트레이스 노출 없음
XSS   ?ip=<script>alert(1)   → 200, 이스케이프됨 (반사 없음)
CSRF  토큰 없는 POST         → 400 (차단)
로그인 → 대시보드 렌더링     → 200, 23,885 bytes (KPI/차트 정상)
```

### 로컬 실측 (개발 환경)

```
공개 라우트   / /about /board/ /board/1 /auth/login /auth/register
             /healthz /static/* → 전부 200,  /nope → 404
관리자(비로그인) /admin → 308,  /admin/logs → 302,  /api/admin/live → 403  (차단 정상)
관리자(로그인)   7개 화면 + logs.csv + API 3종 → 전부 200
위협 탐지 실측   /board/?q=' OR 1=1 --  →  score=100  tags=scanner_ua,sqli
테스트            pytest 109 passed  /  ruff All checks passed
```

## 데이터 모델 (MariaDB 10개 테이블)

`users` `posts` `comments` `uploads` `access_logs` `login_attempts`
`security_events` `blocked_ips` `deployments` `schema_migrations`

`access_logs` 가 대시보드의 데이터 소스이며, 시각·IP·상태·위협점수에
복합 인덱스를 걸어 대량 로그에서도 필터 조회가 빠르게 동작합니다.

## 로컬 실행 방법

```bash
# 1) 환경변수 준비
cp .env.example .env        # 값 수정 (SECRET_KEY, DB_PASSWORD, ADMIN_INITIAL_PASSWORD)

# 2) 스키마 적용 (멱등 — 여러 번 실행해도 안전)
python3 scripts/migrate.py

# 3) 관리자 계정 생성 (멱등 — 기존 비밀번호를 덮어쓰지 않음)
python3 scripts/bootstrap_admin.py

# 4) 시연용 데이터 (선택 — 대시보드가 비어 있으면 기능 검증이 안 되므로 권장)
python3 scripts/seed_data.py --logs 900

# 5) 실행
python3 wsgi.py                                    # 개발
gunicorn --config deploy/gunicorn.conf.py wsgi:app # 운영
```

시연 계정: `alice` / `bob` / `charlie` (비밀번호 `DemoPass!2026`)

## CI/CD 파이프라인 (요구사항 #1)

### 왜 self-hosted runner 인가

GitHub 은 NAT 뒤의 가정용 VM 으로 **접속할 수 없습니다.** 그래서 방향을
뒤집어, VM 안의 runner 가 GitHub 을 폴링(pull)합니다. 인바운드 포트 0개로
자동 배포가 성립합니다.

### 흐름

```
git push
   ↓
ci.yml        ruff · bandit · pytest(109) · 이중모드 전환 검증   [GitHub 호스팅]
   ↓
deploy.yml    VM 내부 self-hosted runner                        [VM]
   ├ .env 생성 (GitHub Secrets → 파일, chmod 600)
   ├ 이미지 빌드 (APP_VERSION = v<run_number>)
   ├ DB 기동 대기 → 스키마 마이그레이션(멱등) → 관리자 계정 보장(멱등)
   ├ 배포 전 이미지를 rollback 태그로 보존
   ├ web/nginx 재생성 → /healthz 폴링 (최대 90초)
   │     실패 시 → 보존 이미지로 자동 롤백
   ├ 배포 후 검증: 커밋 해시 일치 + mode=secure 이중 확인
   └ deployments 테이블에 기록 (커밋·버전·실행자·모드)
```

**헬스체크 게이트**가 핵심입니다. 컨테이너가 떴다는 것과 앱이 정상이라는
것은 다릅니다. `/healthz` 가 `{"status":"ok"}` + DB 연결을 응답할 때만
배포를 성공으로 인정하고, 아니면 이전 이미지로 되돌립니다.

### 자기복구 (self-healing) — push 가 없어도 유지된다

CI/CD 는 **push 라는 이벤트가 있을 때만** 동작합니다. 그래서 아래 상황은
파이프라인이 아무리 잘 돌아도 자동으로 낫지 않고, VM 에 직접 접속해서
손으로 고쳐야 했습니다.

| 상황 | 왜 CI/CD 로 안 고쳐지나 |
|------|------------------------|
| VM 재부팅·정전 | 컨테이너는 `restart: unless-stopped` 로 살아나지만 **Quick Tunnel 은 profile 밖**이라 죽은 채 남음 → 외부 접속만 끊김 |
| 터널이 조용히 끊김 | push 가 없으니 아무 트리거도 없음. 앱은 멀쩡해서 알아채기 어려움 |
| 배포 실패로 옛 커밋에 머묾 | main 과 실제 서비스가 어긋난 채 방치 (드리프트) |
| 러너 프로세스 사망 | 배포 자체가 트리거되지 않음 |

`scripts/autoheal.sh` 를 systemd timer 로 돌려 **main 브랜치를 기준으로**
VM 상태를 계속 맞춥니다.

```bash
sudo ./scripts/setup_autoheal.sh          # 설치 (기본 1분 주기)
sudo ./scripts/setup_autoheal.sh --interval 5min
journalctl -u vmlab-autoheal -f           # 동작 로그
sudo /usr/local/bin/vmlab-autoheal --dry-run   # 무엇을 할지 미리보기
```

점검·복구 항목:

```
1. 보안 게이트   SECURITY_MODE=vulnerable 이면 오히려 터널을 '내린다'
2. 앱 스택       /healthz 실패 시 db/web/nginx 기동 후 최대 60초 확인
3. 외부 터널     끊겨 있으면 재기동, 새 주소를 /var/lib/vmlab/tunnel_url 에 기록
4. 드리프트      main 해시 vs 실행 커밋 비교. 러너가 죽었으면 재시작
```

설계상 지킨 두 가지:

- **멱등** — 이미 정상이면 아무것도 하지 않습니다. 1분마다 도는 물건이라
  매번 뭔가를 재기동하면 그 자체가 장애가 됩니다.
- **빌드는 하지 않는다** — 드리프트를 감지해도 여기서 직접 빌드·배포하지
  않습니다. 그렇게 하면 CI 의 테스트 게이트를 우회하는 셈입니다. 대신
  러너를 되살려 GitHub Actions 가 정상 경로로 배포하게 합니다.
- **한 번도 켠 적 없는 터널은 켜지 않습니다** — 의도하지 않은 외부 노출을
  만들지 않기 위해, 과거에 존재했던 터널만 되살립니다.

부팅 후 90초 뒤 첫 실행됩니다(도커가 컨테이너를 올릴 시간).

### 운영 명령

```bash
# 배포 상태 진단 (.env 위치를 자동으로 찾아 길이만 표시 — 값은 안 찍음)
./scripts/diag_env.sh

# 외부 공개 (도메인 불필요, 30초)
./scripts/setup_tunnel.sh --quick
./scripts/setup_tunnel.sh --status    # 현재 공개 주소 확인
./scripts/setup_tunnel.sh --down      # 외부 노출 차단 (앱은 계속 동작)

# 자기복구
sudo ./scripts/setup_autoheal.sh              # 설치 (1회)
systemctl status vmlab-autoheal.timer         # 타이머 상태
journalctl -u vmlab-autoheal -n 30 --no-pager # 최근 동작
cat /var/lib/vmlab/tunnel_url                 # 현재 외부 주소
```

> ℹ️ **`--down` 과 자기복구는 충돌하지 않습니다.**
> `--down` 은 터널 컨테이너를 `stop` 이 아니라 `rm -f` 로 **삭제**합니다.
> autoheal 은 "컨테이너가 존재하는데 멈춰 있는 경우"만 되살리므로,
> 삭제된 상태는 "사용자가 의도적으로 내렸다"로 보고 건드리지 않습니다.
> (`stop` 이었다면 1분 뒤 되살아나 실습을 방해했을 것입니다.)
> 취약 모드에서는 이중으로 안전합니다 — autoheal 이 `vulnerable` 을
> 감지하면 오히려 터널을 내립니다.

> ⚠️ **compose 를 직접 쓸 때는 반드시 `-p vmlab`** 을 붙이세요.
> 안 붙이면 디렉터리 이름에서 프로젝트명을 유추해(`liinux-`) 실행 중인
> 스택이 안 보이고, 컨테이너 이름 충돌이 납니다.
> ```bash
> sudo docker compose -p vmlab ps
> ```

> ⚠️ **`.env` 는 `git clone` 한 디렉터리에 없습니다.** 배포가 러너의
> 작업 디렉터리(`/opt/actions-runner/_work/<repo>/<repo>/`)에 만듭니다.
> 위 스크립트들은 이 경로를 자동으로 찾습니다.

## 남은 작업

1. **Named Tunnel 로 고정 주소** — 도메인이 생기면 `./scripts/setup_tunnel.sh`
   (옵션 없이). Quick Tunnel 은 재시작마다 주소가 바뀝니다.
   앱·배포 구조는 그대로 두면 됩니다.
2. **`deploy.yml` 에 DB 자격증명 사전 검사 단계 추가** — 볼륨에 남은 옛
   비밀번호를 마이그레이션 실패 전에 잡아냅니다 (작성 완료, 적용 대기).
3. **Kali VM 연동 실습** — `vulnerable` 모드를 호스트 전용 네트워크에서
   공격하고, `secure` 모드에서 차단되는 것을 대시보드로 대조.
4. **문서 분리** — CI-CD / 외부노출 가이드를 `docs/` 로 독립.

## 기술 스택

Python 3.12 · Flask 3.0.3 · Jinja2 · Gunicorn 22 · MariaDB · PyMySQL + DBUtils PooledDB
· Nginx · Docker Compose · GitHub Actions(self-hosted) · Cloudflare Tunnel · Chart.js 4.4.4

프런트엔드는 **CDN 프레임워크 없이 순수 CSS**로 작성했습니다.
CSP `script-src 'self'` 를 엄격히 유지하고, 오프라인 VM 에서도 화면이 깨지지 않게 하기 위함입니다.

## 트러블슈팅 기록 (실제로 겪은 함정)

포트폴리오에서 설명하기 좋은 지점들입니다. 상세는 `docs/VM_SETUP.md`.

| 증상 | 진짜 원인 |
|------|----------|
| `.env` 의 모든 값이 1자 | `gh secret set --body -` 는 stdin 을 **안 읽는다**. `--body` 는 문자열 옵션이라 `-` 가 값으로 저장됨 (`curl`/`tar` 관례와 다름) |
| DB 컨테이너는 healthy 인데 마이그레이션만 실패 | MariaDB 는 `MARIADB_PASSWORD` 를 **볼륨 첫 초기화 때만** 쓴다. 기존 볼륨이면 옛 비밀번호가 유지됨 |
| `down -v` 했는데 볼륨이 남음 | compose 프로젝트명이 **디렉터리 이름**에서 유추됨(`liinux-`). 없는 볼륨을 지우려 해 조용히 exit 0 |
| `Conflict. container name "/vmlab-db"` | 같은 원인. 실행 중인 `vmlab` 스택이 안 보여 새로 만들려 듦 |
| 브라우저에서 `127.0.0.1:8080` 거부 | `127.0.0.1` 은 **머신마다 다르다**. `BIND_ADDR=127.0.0.1` 은 VM 내부 전용 (의도된 설정) |
| 비밀번호는 맞는데 로그인이 안 됨 | `SESSION_COOKIE_SECURE=true` + `http://` → 브라우저가 쿠키를 안 보냄. HTTPS(터널)로 접속 |
| `setup_tunnel.sh` 가 `.env` 를 못 찾음 | `.env` 는 `git clone` 한 `~/Liinux-` 가 아니라 **러너 작업 디렉터리**(`/opt/actions-runner/_work/...`)에 생성됨. 이제 스크립트가 자동 탐색 |
| `quicktunnel` 하나만 띄우려는데 스택 전체를 재생성 | `depends_on: nginx` 때문. `--no-deps` 로 격리 |

각 항목은 **재발 방지 장치**까지 넣어두었습니다 — 예: Secrets 등록 전
`--no-store` 로 전달 길이를 측정하는 카나리 검사, 마이그레이션의 인증
오류 즉시 중단(1044/1045/1049 은 재시도해도 소용없음).

---
**최종 갱신**: 2026-09-04 · **모드**: secure
**상태**: ✅ 요구사항 #1·#2·#3 전부 완료 및 실측 검증
(CI/CD 자동 배포 성공 · 외부망 접속 확인 · 대시보드에 실제 IP 기록 확인)
