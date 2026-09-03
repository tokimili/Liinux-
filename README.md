# VM Security Lab — 로컬 VM 보안 실습 & CI/CD 배포 플랫폼

보안 포트폴리오 로드맵의 Phase 1~2 배포 대상 웹 서비스입니다.
**하나의 코드베이스**를 `SECURITY_MODE` 환경변수로 전환해
"취약 → 방어" Before/After 를 증명하는 구조입니다.

## 프로젝트 목표 (사용자 요구사항)

| # | 요구사항 | 현재 상태 |
|---|---------|----------|
| 1 | CI/CD 로 VM 에 자동 배포 | ⬜ 미착수 (다음 단계) |
| 2 | 로컬 VM 에서 확인 + 외부 접속 가능 | ⬜ 미착수 (Cloudflare Tunnel 예정) |
| 3 | 관리자 대시보드에서 접속 기록 확인 | ✅ **완료 (검증됨)** |

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

## 검증 결과 (로컬 실측)

```
공개 라우트   / /about /board/ /board/1 /auth/login /auth/register
             /healthz /static/* → 전부 200,  /nope → 404
관리자(비로그인) /admin → 308,  /admin/logs → 302,  /api/admin/live → 403  (차단 정상)
관리자(로그인)   7개 화면 + logs.csv + API 3종 → 전부 200
대시보드 렌더   kpi-total=528  kpi-ips=15  kpi-threats=83  kpi-errors=64
위협 탐지 실측   /board/?q=' OR 1=1 --  →  score=100  tags=scanner_ua,sqli
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

## 남은 작업 (다음 세션)

1. **Docker + Nginx + Gunicorn 구성** — `Dockerfile`, `docker-compose.yml`,
   `deploy/nginx/*.conf`, `deploy/gunicorn.conf.py`
2. **GitHub Actions CI/CD** ⭐요구사항 #1 — `.github/workflows/ci.yml`(lint·bandit·pytest),
   `deploy.yml`(self-hosted runner → 마이그레이션 → 헬스체크 게이트 → 실패 시 자동 롤백 →
   `deployments` 테이블 기록)
3. **VM 부트스트랩 + Cloudflare Tunnel** ⭐요구사항 #2 — `scripts/vm_bootstrap.sh`,
   `scripts/setup_tunnel.sh`, ufw/fail2ban 설정
4. **pytest 테스트** — 이중모드 전환, 위협탐지, 권한 검증
5. **문서** — VM 구축 / CI-CD / 외부노출 가이드

## 기술 스택

Python 3.12 · Flask 3.0.3 · Jinja2 · Gunicorn 22 · MariaDB · PyMySQL + DBUtils PooledDB
· Nginx · Docker Compose · GitHub Actions(self-hosted) · Cloudflare Tunnel · Chart.js 4.4.4

프런트엔드는 **CDN 프레임워크 없이 순수 CSS**로 작성했습니다.
CSP `script-src 'self'` 를 엄격히 유지하고, 오프라인 VM 에서도 화면이 깨지지 않게 하기 위함입니다.

---
**최종 갱신**: 2026-09-03 · **모드**: secure · **상태**: 애플리케이션 계층 완료, 배포 계층 진행 예정
