#!/usr/bin/env python3
"""
개발/시연용 시드 데이터 생성 (멱등).

대시보드가 빈 화면이면 기능을 검증할 수 없으므로,
실제 트래픽과 유사한 접속 로그·보안 이벤트·게시글을 생성한다.

주의: 운영 배포 파이프라인에서는 호출하지 않는다 (개발/시연 전용).

사용:
    python3 scripts/seed_data.py                # 기본 (로그 800건)
    python3 scripts/seed_data.py --logs 3000
    python3 scripts/seed_data.py --wipe-logs    # 기존 로그를 지우고 재생성
"""
from __future__ import annotations

import argparse
import os
import random
import sys
from datetime import datetime, timedelta

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app.config import get_config  # noqa: E402
from app.core import db  # noqa: E402
from app.core.security import (  # noqa: E402
    detect_threats,
    hash_password,
    severity_from_score,
)

DEMO_PASSWORD = "DemoPass!2026"  # noqa: S105  (데모 시드 계정용, 운영 미사용)

USERS = [
    ("alice", "alice@vmlab.local", "user"),
    ("bob", "bob@vmlab.local", "user"),
    ("charlie", "charlie@vmlab.local", "user"),
]

POSTS = [
    ("VM 실습 환경 구축 정리",
     "VirtualBox 에 Ubuntu Server 24.04 를 올리고 Docker Compose 로\n"
     "Nginx + Gunicorn + MariaDB 3계층을 구성했습니다.\n"
     "호스트 전용 어댑터와 NAT 를 함께 붙여 격리와 인터넷 접근을 모두 확보했습니다."),
    ("CI/CD 파이프라인 설계 메모",
     "GitHub Actions self-hosted runner 를 VM 안에 설치해\n"
     "pull 방식으로 배포합니다. NAT 뒤의 VM 에 인바운드 포트를 열지 않아도\n"
     "자동 배포가 가능한 것이 핵심입니다."),
    ("SQL Injection 대응 기록",
     "문자열 조립 쿼리를 파라미터 바인딩으로 교체했습니다.\n"
     "vulnerable 모드와 secure 모드를 같은 코드베이스에서 전환해\n"
     "Before/After 를 그대로 비교할 수 있게 했습니다."),
    ("접속 로그 수집 파이프라인",
     "after_request 훅에서 요청 메타데이터를 수집하고,\n"
     "위협 점수를 매긴 뒤 큐에 넣어 백그라운드 스레드가 배치 INSERT 합니다.\n"
     "로깅이 응답 지연으로 이어지지 않게 하는 것이 목표였습니다."),
    ("파일 업로드 취약점과 3중 검증",
     "확장자 블랙리스트만으로는 부족합니다.\n"
     "화이트리스트 + 매직바이트 + 이중확장자 차단을 함께 적용하고,\n"
     "저장 파일명을 서버가 UUID 로 재생성하도록 바꿨습니다."),
]

COMMENTS = [
    "정리 감사합니다. 저도 같은 구성으로 시도해 보겠습니다.",
    "self-hosted runner 방식이 확실히 깔끔하네요.",
    "매직바이트 검증 부분이 특히 참고가 됐습니다.",
    "롤백 시나리오도 같이 적어주시면 좋을 것 같아요.",
]

# 정상 트래픽 경로 (가중치 포함)
NORMAL_PATHS = [
    ("GET", "/", 200, 30),
    ("GET", "/board/", 200, 22),
    ("GET", "/board/1", 200, 12),
    ("GET", "/board/2", 200, 8),
    ("GET", "/board/3", 200, 6),
    ("GET", "/about", 200, 7),
    ("GET", "/auth/login", 200, 9),
    ("POST", "/auth/login", 302, 5),
    ("GET", "/auth/register", 200, 3),
    ("GET", "/admin", 200, 4),
    ("GET", "/admin/logs", 200, 3),
    ("GET", "/nonexistent-page", 404, 3),
]

# 공격 시뮬레이션 (위협 탐지 로직이 실제로 점수를 매기는지 확인용)
ATTACK_PATTERNS = [
    ("GET",  "/board/", "q=' OR 1=1 --", 200),
    ("GET",  "/board/", "q=' UNION SELECT username,password_hash FROM users --", 500),
    ("POST", "/auth/login", "", 401),
    ("GET",  "/board/", "q=<script>alert(1)</script>", 200),
    ("GET",  "/../../etc/passwd", "", 404),
    ("GET",  "/board/", "file=../../../../etc/shadow", 404),
    ("GET",  "/index.php", "cmd=cat /etc/passwd;id", 404),
    ("GET",  "/wp-login.php", "", 404),
    ("GET",  "/.env", "", 404),
    ("GET",  "/admin/config.php", "", 404),
    ("GET",  "/board/", "url=http://169.254.169.254/latest/meta-data/", 200),
]

NORMAL_UA = [
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/128.0 Safari/537.36",
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.5 Safari/605.1.15",
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
    "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0",
]

SCANNER_UA = [
    "sqlmap/1.8.4#stable (https://sqlmap.org)",
    "Nikto/2.5.0",
    "Mozilla/5.0 zgrab/0.x",
    "curl/8.5.0",
    "python-requests/2.32.3",
    "Nmap Scripting Engine",
]

NORMAL_IPS = [
    "192.168.56.1", "192.168.56.10", "192.168.0.15", "192.168.0.22",
    "10.0.2.2", "172.20.10.4", "203.0.113.42", "198.51.100.17",
]
ATTACK_IPS = ["45.155.205.233", "185.220.101.7", "89.248.165.12", "104.244.79.100"]

COUNTRIES = ["KR", "KR", "KR", "US", "JP", "DE", "NL", "RU", "CN"]


# ------------------------------------------------------------------ 사용자/게시글

def seed_users() -> dict[str, int]:
    ids: dict[str, int] = {}
    pw = hash_password(DEMO_PASSWORD)
    for username, email, role in USERS:
        row = db.query_one("SELECT id FROM users WHERE username=%s", (username,))
        if row:
            ids[username] = row["id"]
            continue
        ids[username] = db.insert(
            "INSERT INTO users (username, email, password_hash, role) VALUES (%s,%s,%s,%s)",
            (username, email, pw, role),
        )
    print(f"[+] 사용자 {len(ids)}명 준비 완료 (비밀번호: {DEMO_PASSWORD})")
    return ids


def seed_posts(user_ids: dict[str, int]) -> list[int]:
    names = list(user_ids.keys())
    post_ids: list[int] = []
    for idx, (title, content) in enumerate(POSTS):
        row = db.query_one("SELECT id FROM posts WHERE title=%s", (title,))
        if row:
            post_ids.append(row["id"])
            continue
        uid = user_ids[names[idx % len(names)]]
        pid = db.insert(
            "INSERT INTO posts (user_id, title, content, view_count, created_at) "
            "VALUES (%s,%s,%s,%s,%s)",
            (uid, title, content, random.randint(12, 240),
             datetime.now() - timedelta(days=len(POSTS) - idx, hours=random.randint(0, 20))),
        )
        post_ids.append(pid)

        for c_idx, text in enumerate(random.sample(COMMENTS, k=random.randint(1, 3))):
            db.insert(
                "INSERT INTO comments (post_id, user_id, content, created_at) "
                "VALUES (%s,%s,%s,%s)",
                (pid, user_ids[names[(idx + c_idx + 1) % len(names)]], text,
                 datetime.now() - timedelta(days=len(POSTS) - idx, hours=random.randint(0, 12))),
            )
    print(f"[+] 게시글 {len(post_ids)}건 준비 완료")
    return post_ids


# ------------------------------------------------------------------ 접속 로그

def _weighted_normal():
    total = sum(w for *_, w in NORMAL_PATHS)
    pick = random.uniform(0, total)
    acc = 0.0
    for method, path, status, weight in NORMAL_PATHS:
        acc += weight
        if pick <= acc:
            return method, path, status
    return "GET", "/", 200


def seed_access_logs(count: int, hours_span: int = 72) -> None:
    rows = []
    now = datetime.now()

    for _ in range(count):
        # 최근 시간대에 트래픽이 몰리도록 가중 (제곱 분포)
        offset_h = (random.random() ** 2) * hours_span
        ts = now - timedelta(hours=offset_h)

        is_attack = random.random() < 0.13

        if is_attack:
            method, path, qs, status = random.choice(ATTACK_PATTERNS)
            ip = random.choice(ATTACK_IPS)
            ua = random.choice(SCANNER_UA)
            username = None
            user_id = None
            duration = random.randint(3, 90)
        else:
            method, path, status = _weighted_normal()
            qs = ""
            ip = random.choice(NORMAL_IPS)
            ua = random.choice(NORMAL_UA)
            if random.random() < 0.35:
                username = random.choice([u[0] for u in USERS])
                user_id = None
            else:
                username = None
                user_id = None
            duration = random.randint(4, 180)

        # 실제 서비스와 동일한 탐지 로직을 통과시킨다.
        # detect_threats 는 (점수, 태그리스트)를 반환하므로
        # 미들웨어와 같은 방식으로 콤마 문자열로 직렬화한다.
        score, tags = detect_threats(path, qs, "", ua)
        tag_str = ",".join(tags)[:255] if tags else None

        rows.append((
            ts, ip, method, path[:512], qs[:1024], status, duration,
            random.randint(400, 42000), user_id, username, ua[:512],
            None, random.choice(COUNTRIES),
            1 if path.startswith("/admin") else 0,
            score, tag_str,
        ))

    db.execute_many(
        "INSERT INTO access_logs (ts, ip, method, path, query_string, status_code, "
        "duration_ms, bytes_sent, user_id, username, user_agent, referer, country, "
        "is_admin_path, threat_score, threat_tags) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
        rows,
    )
    threats = sum(1 for r in rows if (r[14] or 0) >= 35)
    print(f"[+] 접속 로그 {len(rows)}건 생성 (위협 탐지 {threats}건)")


# ------------------------------------------------------------------ 보안 이벤트 / 로그인 시도

def seed_security_events() -> None:
    """access_logs 의 고위험 요청에서 보안 이벤트를 파생시킨다."""
    high = db.query_all(
        "SELECT ts, ip, path, query_string, threat_score, threat_tags "
        "FROM access_logs WHERE threat_score >= 50 ORDER BY ts DESC LIMIT 40"
    )
    if not high:
        print("[=] 파생할 고위험 로그가 없습니다.")
        return

    rows = []
    for r in high:
        tag = (r["threat_tags"] or "unknown").split(",")[0]
        rows.append((
            r["ts"], severity_from_score(int(r["threat_score"])), tag,
            r["ip"], r["path"],
            f"위협 점수 {r['threat_score']} · 태그 {r['threat_tags']} · "
            f"쿼리 {(r['query_string'] or '')[:120]}",
            0,
        ))

    db.execute_many(
        "INSERT INTO security_events (ts, severity, event_type, ip, path, detail, is_resolved) "
        "VALUES (%s,%s,%s,%s,%s,%s,%s)",
        rows,
    )
    print(f"[+] 보안 이벤트 {len(rows)}건 생성")


def seed_login_attempts() -> None:
    rows = []
    now = datetime.now()

    # 정상 로그인
    for _ in range(30):
        rows.append((
            now - timedelta(hours=random.uniform(0, 72)),
            random.choice(NORMAL_IPS), random.choice([u[0] for u in USERS]),
            1, random.choice(NORMAL_UA)[:512], None,
        ))

    # 브루트포스 시뮬레이션: 한 IP 가 admin 계정을 반복 시도
    attacker = ATTACK_IPS[0]
    base = now - timedelta(hours=2)
    for i in range(24):
        rows.append((
            base + timedelta(seconds=i * 7),
            attacker, "admin", 0,
            "Mozilla/5.0 (compatible; Hydra)", "bad_password",
        ))

    # 계정 열거 시도
    for name in ["root", "administrator", "test", "guest", "oracle", "postgres"]:
        rows.append((
            now - timedelta(minutes=random.randint(5, 300)),
            ATTACK_IPS[1], name, 0, "python-requests/2.32.3", "no_such_user",
        ))

    db.execute_many(
        "INSERT INTO login_attempts (ts, ip, username, success, user_agent, reason) "
        "VALUES (%s,%s,%s,%s,%s,%s)",
        rows,
    )
    print(f"[+] 로그인 시도 {len(rows)}건 생성 (브루트포스 시나리오 포함)")


def seed_deployments() -> None:
    if db.query_scalar("SELECT COUNT(*) FROM deployments"):
        print("[=] 배포 이력이 이미 있습니다.")
        return

    rows = []
    now = datetime.now()
    for i in range(5):
        rows.append((
            now - timedelta(days=4 - i, hours=random.randint(0, 8)),
            f"{random.getrandbits(80):020x}"[:40],
            "refs/heads/main", f"1.0.{i}",
            "github-actions[bot]", "secure",
            f"CI/CD 자동 배포 성공 (소요 {random.randint(38, 95)}초)",
        ))
    db.execute_many(
        "INSERT INTO deployments (deployed_at, git_commit, git_ref, app_version, "
        "actor, mode, note) VALUES (%s,%s,%s,%s,%s,%s,%s)",
        rows,
    )
    print(f"[+] 배포 이력 {len(rows)}건 생성")


# ------------------------------------------------------------------ main

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--logs", type=int, default=800, help="생성할 접속 로그 건수")
    parser.add_argument("--wipe-logs", action="store_true",
                        help="기존 로그/이벤트/시도 기록을 삭제하고 재생성")
    args = parser.parse_args()

    cfg = get_config()
    if cfg.SECURITY_MODE == "vulnerable":
        print("[!] 경고: vulnerable 모드에서 시드를 실행합니다.")

    db.init_db(cfg)

    if args.wipe_logs:
        for table in ("access_logs", "security_events", "login_attempts"):
            db.execute(f"DELETE FROM {table}")
        print("[-] 기존 로그 데이터 삭제 완료")

    user_ids = seed_users()
    seed_posts(user_ids)

    existing_logs = db.query_scalar("SELECT COUNT(*) FROM access_logs")
    if existing_logs and not args.wipe_logs:
        print(f"[=] 접속 로그가 이미 {existing_logs}건 있습니다. "
              f"재생성하려면 --wipe-logs 를 사용하세요.")
    else:
        seed_access_logs(args.logs)
        seed_security_events()
        seed_login_attempts()

    seed_deployments()

    print("\n[✓] 시드 완료")
    print(f"    일반 계정 : alice / bob / charlie  (비밀번호 {DEMO_PASSWORD})")
    print(f"    관리자    : {cfg.ADMIN_USERNAME}  (scripts/bootstrap_admin.py 로 생성)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
