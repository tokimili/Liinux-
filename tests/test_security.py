"""
보안 통제 검증.

이 파일이 CI 의 핵심 게이트다.
"secure 모드에서 방어가 실제로 동작하는가"를 코드로 증명한다.
방어가 깨지면 배포가 차단된다.
"""
from __future__ import annotations

import pytest

from app.core import db
from app.core.security import (
    detect_threats,
    get_extension,
    hash_password,
    is_safe_upload,
    sanitize_filename,
    severity_from_score,
    verify_password,
)

# ==================================================== 비밀번호 해싱

def test_password_hash_is_not_plaintext():
    h = hash_password("MySecret!2026")
    assert "MySecret!2026" not in h
    assert h.startswith("scrypt:")


def test_password_hash_is_salted():
    """같은 비밀번호라도 해시가 달라야 한다 (레인보우 테이블 방어)."""
    a = hash_password("SamePassword!1")
    b = hash_password("SamePassword!1")
    assert a != b
    assert verify_password(a, "SamePassword!1")
    assert verify_password(b, "SamePassword!1")


def test_password_verify_rejects_wrong():
    h = hash_password("Correct!2026")
    assert verify_password(h, "Correct!2026") is True
    assert verify_password(h, "Wrong!2026") is False
    assert verify_password(h, "") is False


def test_password_verify_survives_garbage_hash():
    """손상된 해시가 들어와도 예외로 500을 내지 않아야 한다."""
    assert verify_password("not-a-real-hash", "anything") is False
    assert verify_password("", "anything") is False


# ==================================================== 위협 탐지

@pytest.mark.parametrize("qs,expected_tag", [
    ("q=' OR 1=1 --", "sqli"),
    ("q=1 UNION SELECT username,password FROM users", "sqli"),
    ("q=<script>alert(1)</script>", "xss"),
    ("q=<img src=x onerror=alert(1)>", "xss"),
    ("file=../../../../etc/passwd", "traversal"),
    ("cmd=;cat /etc/passwd", "cmdi"),
    ("url=http://169.254.169.254/latest/meta-data/", "ssrf"),
])
def test_detect_threats_flags_attacks(qs, expected_tag):
    score, tags = detect_threats("/board/", qs, "", "Mozilla/5.0")
    assert expected_tag in tags, f"{qs!r} 에서 {expected_tag} 미탐지 (tags={tags})"
    assert score >= 35, f"{qs!r} 점수 부족: {score}"


def test_detect_threats_survives_url_encoding():
    """인코딩만으로 탐지를 우회할 수 있으면 IDS 로서 무의미하다."""
    plain, _ = detect_threats("/board/", "q=' OR 1=1 --", "", "Mozilla/5.0")
    encoded, tags = detect_threats(
        "/board/", "q=%27%20OR%201%3D1%20--", "", "Mozilla/5.0")
    assert "sqli" in tags
    assert encoded >= 35
    assert encoded == plain


def test_detect_threats_survives_double_encoding():
    score, tags = detect_threats(
        "/board/", "q=%2527%2520OR%25201%253D1", "", "Mozilla/5.0")
    assert "sqli" in tags, f"이중 인코딩 우회 발생 (tags={tags})"


def test_detect_threats_flags_scanner_ua():
    score, tags = detect_threats("/", "", "", "sqlmap/1.8.4#stable")
    assert "scanner_ua" in tags
    assert score >= 35


def test_detect_threats_clean_request_is_low():
    """정상 요청이 오탐되면 대시보드가 쓸모없어진다."""
    ua = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
          "(KHTML, like Gecko) Chrome/128.0 Safari/537.36")
    score, tags = detect_threats("/board/", "q=보안 스터디 정리", "", ua)
    assert score < 35, f"정상 요청 오탐 (score={score}, tags={tags})"
    assert "sqli" not in tags
    assert "xss" not in tags


def test_detect_threats_score_capped():
    score, _ = detect_threats(
        "/../../etc/passwd",
        "q=' UNION SELECT 1 --&cmd=;id&x=<script>alert(1)</script>"
        "&url=http://169.254.169.254/",
        "", "sqlmap/1.8",
    )
    assert score <= 100


def test_severity_thresholds():
    assert severity_from_score(100) == "critical"
    assert severity_from_score(80) == "critical"
    assert severity_from_score(60) == "high"
    assert severity_from_score(35) == "medium"
    assert severity_from_score(15) == "low"
    assert severity_from_score(0) == "info"


# ==================================================== 업로드 검증

PNG_MAGIC = b"\x89PNG\r\n\x1a\n" + b"\x00" * 32
ALLOWED = {"png", "jpg", "jpeg", "gif", "pdf", "txt", "md"}


def test_upload_accepts_valid_png():
    ok, msg = is_safe_upload("photo.png", PNG_MAGIC, ALLOWED)
    assert ok is True, msg


@pytest.mark.parametrize("name", [
    "shell.php",
    "shell.PHP",
    "webshell.phtml",
    "backdoor.jsp",
    "evil.asp",
    "payload.exe",
    "script.sh",
    "hack.py",
    "inject.svg",
    "xss.html",
])
def test_upload_blocks_executable_extensions(name):
    """웹셸 업로드(VULN-05)의 1차 방어선."""
    ok, msg = is_safe_upload(name, PNG_MAGIC, ALLOWED)
    assert ok is False, f"{name} 이 통과됨 — 웹셸 업로드 가능"


@pytest.mark.parametrize("name", [
    "shell.php.png",
    "shell.png.php",
    "evil.php.jpg",
])
def test_upload_blocks_double_extension(name):
    """Apache/Nginx 설정 실수 시 .php.png 가 실행될 수 있으므로 차단한다."""
    ok, msg = is_safe_upload(name, PNG_MAGIC, ALLOWED)
    assert ok is False, f"이중 확장자 {name} 통과됨"


def test_upload_blocks_extension_spoofing():
    """확장자만 png 로 바꾼 PHP 웹셸 — 매직바이트로 걸러야 한다."""
    php_shell = b"<?php system($_GET['c']); ?>"
    ok, msg = is_safe_upload("innocent.png", php_shell, ALLOWED)
    assert ok is False, "매직바이트 검증 실패 — 확장자 위조 통과"


def test_sanitize_filename_blocks_traversal():
    assert "/" not in sanitize_filename("../../etc/passwd")
    assert "\\" not in sanitize_filename("..\\..\\windows\\system32")
    assert ".." not in sanitize_filename("../../../evil.txt").replace("..", "")


def test_get_extension_lowercases():
    assert get_extension("Photo.PNG") == "png"
    assert get_extension("archive.tar.gz") == "gz"


# ==================================================== execute_raw 격리

def test_execute_raw_blocked_in_secure_mode(app):
    """
    취약 경로가 secure 모드에서 절대 열리지 않아야 한다.
    이 테스트가 깨지면 운영 배포본에 SQLi 경로가 살아있다는 뜻이다.
    """
    with app.app_context(), pytest.raises(PermissionError):
        db.execute_raw("SELECT 1")


def test_execute_raw_allowed_in_vulnerable_mode(vuln_app):
    """vulnerable 모드에서는 실습을 위해 열려 있어야 한다."""
    with vuln_app.app_context():
        rows = db.execute_raw("SELECT 1 AS one")
        assert rows[0]["one"] == 1
