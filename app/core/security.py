"""
보안 유틸리티: 비밀번호 해싱, 클라이언트 IP 판별, 위협 패턴 탐지.

위협 탐지는 "로그를 분석해 공격을 찾아냈다"는 포트폴리오 증거를 만들기 위한
애플리케이션 레벨 IDS 역할이다. WAF(mod_security)를 대체하지 않고 보완한다.
"""
from __future__ import annotations

import hashlib
import hmac
import ipaddress
import logging
import re
import secrets
from datetime import datetime, timedelta
from urllib.parse import unquote_plus

from flask import request
from werkzeug.security import check_password_hash, generate_password_hash

log = logging.getLogger(__name__)

# ===================================================== 비밀번호

def hash_password(plain: str) -> str:
    """
    scrypt 기반 해싱 (Werkzeug 기본).
    bcrypt/argon2 로 바꾸려면 이 함수만 교체하면 된다 —
    호출부가 알고리즘을 모르게 캡슐화한 것이 포인트.
    """
    return generate_password_hash(plain, method="scrypt")


def verify_password(stored_hash: str, plain: str) -> bool:
    """
    타이밍 공격 대비:
    - 사용자가 없을 때도 더미 해시로 검증을 수행해 응답 시간을 맞춘다
      (호출부에서 DUMMY_HASH 를 넘길 것)
    """
    if not stored_hash:
        return False
    try:
        return check_password_hash(stored_hash, plain)
    except Exception:
        return False


# 존재하지 않는 사용자에게도 동일한 연산 비용을 지불하기 위한 더미
DUMMY_PASSWORD_HASH = hash_password(secrets.token_urlsafe(24))


def generate_csrf_token() -> str:
    return secrets.token_urlsafe(32)


def constant_time_compare(a: str, b: str) -> bool:
    return hmac.compare_digest(str(a or ""), str(b or ""))


# ===================================================== 클라이언트 IP

def _is_valid_ip(value: str) -> bool:
    try:
        ipaddress.ip_address(value)
        return True
    except ValueError:
        return False


def get_client_ip(trusted_proxy_count: int = 1) -> str:
    """
    Nginx / cloudflared 뒤에서 실제 클라이언트 IP를 얻는다.

    ⚠️ X-Forwarded-For 는 클라이언트가 위조할 수 있다.
       따라서 "신뢰하는 프록시 홉 수"만큼 뒤에서부터 세어 읽는다.
       무조건 맨 앞을 믿으면 로그 위조(Log Spoofing) 취약점이 된다.
    """
    # Cloudflare Tunnel 사용 시 가장 신뢰할 수 있는 헤더
    cf_ip = request.headers.get("CF-Connecting-IP", "").strip()
    if cf_ip and _is_valid_ip(cf_ip):
        return cf_ip

    xff = request.headers.get("X-Forwarded-For", "")
    if xff:
        parts = [p.strip() for p in xff.split(",") if p.strip()]
        if parts:
            idx = max(0, len(parts) - max(1, trusted_proxy_count))
            candidate = parts[idx]
            if _is_valid_ip(candidate):
                return candidate

    real_ip = request.headers.get("X-Real-IP", "").strip()
    if real_ip and _is_valid_ip(real_ip):
        return real_ip

    return request.remote_addr or "0.0.0.0"


# ===================================================== 위협 패턴 탐지

# (태그, 정규식, 가중치)
_THREAT_PATTERNS: list[tuple[str, re.Pattern, int]] = [
    # --- SQL Injection ---
    ("sqli", re.compile(r"(\bunion\b[\s\S]{0,20}\bselect\b)", re.I), 60),
    ("sqli", re.compile(r"(\bor\b|\band\b)\s*['\"]?\s*\d+\s*=\s*\d+", re.I), 50),
    ("sqli", re.compile(r"'\s*(or|and)\s+'?1'?\s*=\s*'?1", re.I), 55),
    ("sqli", re.compile(r"\b(sleep|benchmark|pg_sleep)\s*\(", re.I), 55),
    ("sqli", re.compile(r"(information_schema|table_schema|@@version)", re.I), 45),
    ("sqli", re.compile(r"(--\s|#|;)\s*(drop|delete|update|insert)\b", re.I), 60),
    ("sqli", re.compile(r"\bselect\b[\s\S]{0,40}\bfrom\b", re.I), 35),

    # --- XSS ---
    ("xss", re.compile(r"<\s*script", re.I), 55),
    ("xss", re.compile(r"javascript\s*:", re.I), 40),
    ("xss", re.compile(r"\bon(error|load|click|mouseover|focus)\s*=", re.I), 45),
    ("xss", re.compile(r"<\s*(iframe|svg|img|object|embed)[^>]*(on\w+|src\s*=)", re.I), 45),
    ("xss", re.compile(r"(document\.cookie|window\.location|eval\s*\()", re.I), 40),

    # --- 경로 탐색 / 파일 노출 ---
    ("traversal", re.compile(r"(\.\./|\.\.\\){2,}"), 55),
    ("traversal", re.compile(r"/etc/(passwd|shadow|hosts)\b", re.I), 65),
    ("traversal", re.compile(r"(boot\.ini|win\.ini|/proc/self/environ)", re.I), 60),

    # --- 명령 주입 ---
    ("cmdi", re.compile(r"[;|`]\s*(cat|ls|whoami|id|uname|curl|wget|nc)\b", re.I), 65),
    ("cmdi", re.compile(r"\$\(|\$\{.*\}", re.I), 30),

    # --- SSRF ---
    ("ssrf", re.compile(r"(169\.254\.169\.254|metadata\.google|127\.0\.0\.1|localhost)", re.I), 35),
    ("ssrf", re.compile(r"\b(file|gopher|dict)://", re.I), 45),

    # --- 스캐너 / 민감 경로 탐색 ---
    ("scanner", re.compile(r"/(wp-admin|wp-login|xmlrpc\.php|phpmyadmin|\.env|\.git/config)", re.I), 50),
    ("scanner", re.compile(r"/(admin\.php|shell\.php|config\.php\.bak|backup\.(zip|sql|tar\.gz))", re.I), 45),
    ("scanner", re.compile(r"\.(php|asp|aspx|jsp|cgi)$", re.I), 20),

    # --- 템플릿/역직렬화 ---
    ("ssti", re.compile(r"\{\{.*(config|self|__class__|__globals__).*\}\}", re.I), 60),
    ("deser", re.compile(r"(__reduce__|pickle\.loads|rO0AB)", re.I), 50),
]

# 알려진 스캐너 도구의 User-Agent
_SCANNER_UA = re.compile(
    r"(sqlmap|nikto|nmap|masscan|zgrab|dirbuster|gobuster|ffuf|wfuzz|"
    r"acunetix|nessus|openvas|metasploit|hydra|zaproxy|burp|whatweb|"
    r"curl/|wget/|python-requests|go-http-client|libwww-perl)",
    re.I,
)


def detect_threats(
    path: str,
    query_string: str = "",
    body: str = "",
    user_agent: str = "",
) -> tuple[int, list[str]]:
    """
    요청에서 공격 시도 패턴을 찾아 (위협점수 0~100, 태그목록)을 반환.

    URL 인코딩을 풀어서 검사한다 — 인코딩만으로 우회되면 탐지 의미가 없다.
    """
    haystacks = []
    for raw in (path, query_string, body):
        if not raw:
            continue
        text = str(raw)
        haystacks.append(text)
        try:
            decoded = unquote_plus(text)
            if decoded != text:
                haystacks.append(decoded)
            # 이중 인코딩 대응
            twice = unquote_plus(decoded)
            if twice != decoded:
                haystacks.append(twice)
        except (UnicodeDecodeError, ValueError):
            # 디코딩 실패 자체가 비정상 입력이다.
            # 원본(text)은 이미 haystacks 에 들어있으므로 탐지는 계속되고,
            # 여기서는 "조작된 인코딩" 신호로 남긴다.
            log.debug("URL 디코딩 실패 — 조작된 인코딩 가능성: %r", text[:120])

    blob = "\n".join(haystacks)

    score = 0
    tags: set[str] = set()

    if blob:
        for tag, pattern, weight in _THREAT_PATTERNS:
            if pattern.search(blob):
                tags.add(tag)
                score += weight

    if user_agent:
        if _SCANNER_UA.search(user_agent):
            tags.add("scanner_ua")
            score += 35
        if len(user_agent) > 400:
            tags.add("anomalous_ua")
            score += 15
    else:
        # UA 없음 = 브라우저가 아님 (봇/스크립트)
        tags.add("no_ua")
        score += 10

    return min(score, 100), sorted(tags)


def severity_from_score(score: int) -> str:
    if score >= 80:
        return "critical"
    if score >= 60:
        return "high"
    if score >= 35:
        return "medium"
    if score >= 15:
        return "low"
    return "info"


# ===================================================== 파일 업로드 검증

_SAFE_NAME = re.compile(r"[^A-Za-z0-9가-힣._-]")

# 확장자만 믿으면 안 되므로 매직 바이트도 검사한다
_MAGIC_SIGNATURES = {
    b"\x89PNG\r\n\x1a\n": "image/png",
    b"\xff\xd8\xff": "image/jpeg",
    b"GIF87a": "image/gif",
    b"GIF89a": "image/gif",
    b"%PDF-": "application/pdf",
}

# 업로드 파일에 절대 허용하지 않는 실행 가능 확장자
_DANGEROUS_EXT = {
    "php", "php3", "php4", "php5", "php7", "phtml", "phar",
    "jsp", "jspx", "asp", "aspx", "cer", "asa",
    "py", "pl", "rb", "sh", "bash", "cgi",
    "exe", "dll", "so", "bat", "cmd", "com", "scr",
    "htaccess", "htpasswd", "svg", "html", "htm", "xhtml",
}


def sanitize_filename(name: str, max_len: int = 100) -> str:
    """경로 구분자와 특수문자를 제거해 경로 탐색을 막는다."""
    base = (name or "file").replace("\\", "/").split("/")[-1]
    base = base.replace("\x00", "")
    cleaned = _SAFE_NAME.sub("_", base).strip("._") or "file"
    return cleaned[:max_len]


def get_extension(name: str) -> str:
    if "." not in (name or ""):
        return ""
    return name.rsplit(".", 1)[-1].lower().strip()


def is_safe_upload(filename: str, head_bytes: bytes, allowed_ext: set[str]) -> tuple[bool, str]:
    """
    업로드 파일 검증. (통과여부, 사유)

    3중 검사:
      1) 위험 확장자 블랙리스트 (웹셸 차단)
      2) 허용 확장자 화이트리스트
      3) 매직 바이트와 확장자 일치 여부 (확장자 위조 차단)
    """
    ext = get_extension(filename)
    if not ext:
        return False, "확장자가 없는 파일은 허용되지 않습니다."
    if ext in _DANGEROUS_EXT:
        return False, f"실행 가능한 확장자(.{ext})는 차단됩니다."
    if ext not in allowed_ext:
        return False, f"허용되지 않은 확장자입니다(.{ext})."

    # 이중 확장자 차단: shell.php.png
    parts = (filename or "").lower().split(".")
    if len(parts) > 2:
        for mid in parts[1:-1]:
            if mid in _DANGEROUS_EXT:
                return False, "이중 확장자(예: .php.png)는 차단됩니다."

    if ext in ("png", "jpg", "jpeg", "gif", "pdf") and head_bytes:
        matched = any(head_bytes.startswith(sig) for sig in _MAGIC_SIGNATURES)
        if not matched:
            return False, "파일 내용이 확장자와 일치하지 않습니다(확장자 위조 의심)."

    return True, "ok"


def file_sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# ===================================================== 시간 유틸

def utc_now() -> datetime:
    return datetime.now()


def minutes_ago(n: int) -> datetime:
    return datetime.now() - timedelta(minutes=n)
