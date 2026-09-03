"""
애플리케이션 동작 / 접근제어 회귀 테스트.

test_security.py 가 "방어 함수가 올바른가"를 보는 단위 테스트라면,
이 파일은 "라우트 레벨에서 실제로 막히는가"를 보는 통합 테스트다.

CI 가 여기서 실패하면 배포가 중단된다. 특히 다음 항목은
포트폴리오의 근거 자체이므로 절대 깨지면 안 된다.

  - 관리자 페이지가 비인증/일반사용자에게 열리지 않는다 (OWASP A01)
  - IDOR 이 secure 모드에서 차단되고 vulnerable 모드에서 재현된다
  - CSRF 토큰 없는 상태변경 요청이 거부된다
  - SQLi 인증우회가 secure 모드에서 실패한다
  - 접속 로그가 실제로 DB 에 적재된다 (대시보드의 데이터 원천)
"""
from __future__ import annotations

import time

import pytest

from app.core import db

# ==================================================================
# 헬퍼
# ==================================================================

def _login_via_form(cl, username: str, password: str, follow: bool = False):
    """
    임의의 test_client 로 로그인한다.

    conftest 의 login 픽스처는 secure `client` 에 묶여 있어서
    vuln_client 나 두 번째 세션에는 쓸 수 없다. 그래서 별도 헬퍼를 둔다.
    """
    page = cl.get("/auth/login")
    assert page.status_code == 200
    with cl.session_transaction() as sess:
        token = sess.get("csrf_token", "")
    return cl.post(
        "/auth/login",
        data={"username": username, "password": password, "csrf_token": token},
        follow_redirects=follow,
    )


def _csrf_after_login(cl, form_path: str = "/board/new") -> str:
    """
    로그인 후 사용할 CSRF 토큰을 얻는다.

    _rotate_session() 이 세션 고정 방어로 session.clear() 를 하기 때문에
    로그인 직전에 받은 토큰은 로그인 후 무효다. 실제 사용자도 마찬가지로
    로그인 후 렌더된 폼에서 새 토큰을 받는다 — 그 흐름을 그대로 재현한다.
    """
    page = cl.get(form_path)
    assert page.status_code == 200, f"{form_path} → {page.status_code}"
    with cl.session_transaction() as sess:
        token = sess.get("csrf_token", "")
    assert token, "폼 렌더 후에도 CSRF 토큰이 세션에 없다"
    return token


def _new_post(owner_id: int, title: str = "테스트 게시글") -> int:
    return db.insert(
        "INSERT INTO posts (user_id, title, content) VALUES (%s,%s,%s)",
        (owner_id, title, "본문 내용"),
    )


def _drop_post(post_id: int) -> None:
    db.execute("DELETE FROM posts WHERE id=%s", (post_id,))


# ==================================================================
# 1. 헬스체크 — CI/CD 배포 게이트가 의존하는 엔드포인트
# ==================================================================

def test_healthz_returns_ok(client):
    """
    /healthz 가 200 과 필수 필드를 돌려줘야 한다.
    deploy.sh 가 이 응답으로 배포 성공/롤백을 판단하므로,
    스키마가 바뀌면 배포 파이프라인이 조용히 망가진다.
    """
    res = client.get("/healthz")
    assert res.status_code == 200, res.data
    body = res.get_json()

    for key in ("status", "mode", "version", "commit", "db", "log_writer"):
        assert key in body, f"/healthz 응답에 {key} 누락 (배포 게이트가 깨진다)"

    assert body["status"] == "ok"
    assert body["mode"] == "secure"
    assert body["db"]["ok"] is True


def test_healthz_reports_version_metadata(client):
    """
    배포 이력 추적을 위해 버전/커밋이 응답에 실려야 한다.
    커밋은 short SHA(7자)로 노출된다 — deploy.sh 가 이 값으로
    "배포된 리비전이 방금 push 한 커밋인가"를 확인한다.
    """
    body = client.get("/healthz").get_json()
    assert body["version"] == "test"
    assert body["commit"] == "testcom", "short SHA(7자) 규약이 깨졌다"
    assert len(body["commit"]) <= 7


# ==================================================================
# 2. 공개 라우트 스모크
# ==================================================================

@pytest.mark.parametrize("path", [
    "/",
    "/about",
    "/board/",
    "/auth/login",
    "/auth/register",
    "/api/stats/summary",
])
def test_public_routes_ok(client, path):
    res = client.get(path)
    assert res.status_code == 200, f"{path} → {res.status_code}"


def test_unknown_route_is_404(client):
    assert client.get("/definitely-not-a-real-page").status_code == 404


def test_missing_post_is_404(client):
    assert client.get("/board/99999999").status_code == 404


def test_security_headers_present_in_secure_mode(client):
    """secure 모드는 방어 헤더를 반드시 내려야 한다."""
    res = client.get("/")
    for header in (
        "Content-Security-Policy",
        "X-Content-Type-Options",
        "X-Frame-Options",
        "Referrer-Policy",
    ):
        assert header in res.headers, f"{header} 헤더 누락"

    assert res.headers["X-Content-Type-Options"] == "nosniff"
    # CSP 가 느슨해지면 XSS 방어의 2차 방어선이 사라진다
    assert "script-src" in res.headers["Content-Security-Policy"]
    assert "unsafe-eval" not in res.headers["Content-Security-Policy"]


def test_server_header_does_not_leak_stack(client):
    """서버 배너로 프레임워크 버전이 노출되면 정보 수집에 이용된다."""
    server = client.get("/").headers.get("Server", "")
    assert "Werkzeug" not in server


# ==================================================================
# 3. 인증 — 로그인 / 세션
# ==================================================================

def test_login_success_creates_session(client, user_factory):
    name, pw, uid = user_factory()
    res = _login_via_form(client, name, pw)

    assert res.status_code in (302, 303), res.data[:300]
    with client.session_transaction() as sess:
        assert sess.get("user_id") == uid
        assert sess.get("role") == "user"


def test_login_with_wrong_password_creates_no_session(client, user_factory):
    name, _pw, _uid = user_factory()
    _login_via_form(client, name, "WrongPassword!999")

    with client.session_transaction() as sess:
        assert sess.get("user_id") is None


def test_login_rotates_session_id(client, user_factory):
    """
    세션 고정(Session Fixation) 방어 확인.
    로그인 전 세션에 심어둔 값이 로그인 후 남아있으면 세션 재발급이 안 된 것이다.
    """
    name, pw, _uid = user_factory()
    client.get("/auth/login")
    with client.session_transaction() as sess:
        sess["attacker_planted"] = "pwned"

    _login_via_form(client, name, pw)

    with client.session_transaction() as sess:
        assert "attacker_planted" not in sess, "세션이 재발급되지 않았다 (Session Fixation)"


def test_logout_clears_session(client, user_factory):
    name, pw, _uid = user_factory()
    _login_via_form(client, name, pw)
    client.get("/auth/logout")

    with client.session_transaction() as sess:
        assert sess.get("user_id") is None


def test_login_attempts_are_recorded(client, user_factory):
    """
    로그인 시도가 DB 에 남아야 한다 —
    대시보드의 브루트포스 추적 화면이 이 테이블을 읽는다.
    """
    name, pw, _uid = user_factory()
    _login_via_form(client, name, "Nope!1234")
    _login_via_form(client, name, pw)

    rows = db.query_all(
        "SELECT success FROM login_attempts WHERE username=%s ORDER BY id", (name,))
    assert len(rows) >= 2, "로그인 시도가 기록되지 않았다"
    assert {int(r["success"]) for r in rows} == {0, 1}


def test_bruteforce_lockout_engages(client, user_factory):
    """
    실패가 임계값을 넘으면 올바른 비밀번호로도 로그인되지 않아야 한다.
    """
    name, pw, _uid = user_factory()
    for _ in range(6):  # LOGIN_MAX_ATTEMPTS = 5
        _login_via_form(client, name, "Wrong!0000")

    _login_via_form(client, name, pw)
    with client.session_transaction() as sess:
        assert sess.get("user_id") is None, "브루트포스 잠금이 동작하지 않았다"

    db.execute("DELETE FROM login_attempts WHERE username=%s", (name,))


# ==================================================================
# 4. SQL Injection — 인증 우회
# ==================================================================

@pytest.mark.parametrize("payload", [
    "admin' --",
    "admin' OR '1'='1",
    "' OR 1=1 -- ",
    "admin'/**/OR/**/1=1#",
])
def test_sqli_login_bypass_blocked_in_secure_mode(client, payload):
    """
    secure 모드에서 SQLi 로 로그인 우회가 불가능해야 한다.
    이 테스트가 깨지면 파라미터 바인딩이 회귀한 것이다.
    """
    _login_via_form(client, payload, "anything")
    with client.session_transaction() as sess:
        assert sess.get("user_id") is None, f"SQLi 인증 우회 성공: {payload}"


def test_sqli_search_blocked_in_secure_mode(client):
    """검색 SQLi(UNION) 가 secure 모드에서 데이터를 유출하지 않아야 한다."""
    res = client.get(
        "/board/?q=' UNION SELECT 1,username,password_hash,1,1 FROM users -- ")
    assert res.status_code == 200
    body = res.data.decode("utf-8", "replace")
    assert "scrypt:" not in body, "검색 SQLi 로 비밀번호 해시가 유출됐다"


# ==================================================================
# 5. CSRF
# ==================================================================

def test_post_without_csrf_token_is_rejected(client, user_factory):
    name, pw, uid = user_factory()
    _login_via_form(client, name, pw)

    res = client.post("/board/new", data={"title": "무토큰", "content": "본문"})
    assert res.status_code == 400, "CSRF 토큰 없는 POST 가 통과했다"

    assert db.query_scalar(
        "SELECT COUNT(*) FROM posts WHERE user_id=%s AND title='무토큰'", (uid,)) == 0


def test_post_with_wrong_csrf_token_is_rejected(client, user_factory):
    name, pw, _uid = user_factory()
    _login_via_form(client, name, pw)

    res = client.post("/board/new", data={
        "title": "위조토큰", "content": "본문",
        "csrf_token": "0" * 43,
    })
    assert res.status_code == 400


def test_post_with_valid_csrf_token_succeeds(client, user_factory):
    name, pw, uid = user_factory()
    _login_via_form(client, name, pw)
    token = _csrf_after_login(client)

    res = client.post("/board/new", data={
        "title": "정상등록", "content": "본문", "csrf_token": token,
    })
    assert res.status_code in (302, 303), res.data[:300]

    post_id = db.query_scalar(
        "SELECT id FROM posts WHERE user_id=%s AND title='정상등록'", (uid,), default=0)
    assert post_id
    _drop_post(post_id)


def test_csrf_skipped_in_vulnerable_mode(vuln_client, user_factory):
    """vulnerable 모드에서는 CSRF 가 재현되어야 한다 (실습 시연용)."""
    name, pw, uid = user_factory()
    _login_via_form(vuln_client, name, pw)

    res = vuln_client.post("/board/new", data={"title": "CSRF취약", "content": "본문"})
    assert res.status_code in (302, 303), "vulnerable 모드인데 CSRF 가 막혔다"

    post_id = db.query_scalar(
        "SELECT id FROM posts WHERE user_id=%s AND title='CSRF취약'", (uid,), default=0)
    if post_id:
        _drop_post(post_id)


# ==================================================================
# 6. 접근 제어 — 관리자 페이지 (요구사항 3의 보호막)
# ==================================================================

ADMIN_PAGES = [
    "/admin/",
    "/admin/logs",
    "/admin/logs.csv",
    "/admin/threats",
    "/admin/logins",
    "/admin/ips",
    "/admin/deployments",
    "/admin/system",
]


@pytest.mark.parametrize("path", ADMIN_PAGES)
def test_admin_pages_reject_anonymous(client, path):
    res = client.get(path)
    assert res.status_code in (302, 303), f"{path} 가 비인증에게 열렸다 ({res.status_code})"
    assert "/auth/login" in res.headers.get("Location", "")


@pytest.mark.parametrize("path", ADMIN_PAGES)
def test_admin_pages_reject_normal_user(client, user_factory, path):
    """
    수직 권한 상승 차단.
    일반 사용자가 관리 화면에 접근하면 403 이어야 한다 (리다이렉트 아님).
    """
    name, pw, _uid = user_factory(role="user")
    _login_via_form(client, name, pw)

    res = client.get(path)
    assert res.status_code == 403, f"{path} 가 일반 사용자에게 열렸다 ({res.status_code})"


@pytest.mark.parametrize("path", ADMIN_PAGES)
def test_admin_pages_allow_admin(client, user_factory, path):
    name, pw, _uid = user_factory(role="admin", prefix="adm")
    _login_via_form(client, name, pw)

    res = client.get(path)
    assert res.status_code == 200, f"{path} → {res.status_code} (관리자인데 실패)"


@pytest.mark.parametrize("path", [
    "/api/admin/timeline",
    "/api/admin/status-dist",
    "/api/admin/threat-dist",
    "/api/admin/live",
])
def test_admin_apis_reject_anonymous(client, path):
    """
    대시보드 JSON API 도 화면과 동일한 권한을 요구해야 한다.
    화면만 막고 API 를 열어두는 것이 실무에서 가장 흔한 A01 사고다.
    """
    res = client.get(path)
    assert res.status_code == 403, f"{path} 가 비인증에게 열렸다 ({res.status_code})"


@pytest.mark.parametrize("path", [
    "/api/admin/timeline",
    "/api/admin/live",
])
def test_admin_apis_reject_normal_user(client, user_factory, path):
    name, pw, _uid = user_factory(role="user")
    _login_via_form(client, name, pw)
    assert client.get(path).status_code == 403


def test_admin_apis_allow_admin(client, user_factory):
    name, pw, _uid = user_factory(role="admin", prefix="adm")
    _login_via_form(client, name, pw)

    for path in ("/api/admin/timeline", "/api/admin/status-dist",
                 "/api/admin/threat-dist", "/api/admin/live"):
        res = client.get(path)
        assert res.status_code == 200, f"{path} → {res.status_code}"
        assert res.get_json() is not None


def test_admin_csv_export_has_bom(client, user_factory):
    """엑셀에서 한글이 깨지지 않도록 UTF-8 BOM 이 붙어야 한다."""
    name, pw, _uid = user_factory(role="admin", prefix="adm")
    _login_via_form(client, name, pw)

    res = client.get("/admin/logs.csv")
    assert res.status_code == 200
    assert res.data.startswith("\ufeff".encode()), "CSV BOM 누락"


# ==================================================================
# 7. IDOR — 수평 권한 상승
# ==================================================================

def test_idor_blocked_in_secure_mode(client, user_factory):
    """
    타인 게시글 수정 시도가 403 이어야 한다.
    """
    _owner, _opw, owner_id = user_factory(prefix="owner")
    attacker, apw, _aid = user_factory(prefix="attacker")

    post_id = _new_post(owner_id, "소유자의 글")
    try:
        _login_via_form(client, attacker, apw)
        res = client.get(f"/board/{post_id}/edit")
        assert res.status_code == 403, f"IDOR 차단 실패 ({res.status_code})"
    finally:
        _drop_post(post_id)


def test_idor_attempt_is_logged_as_security_event(client, user_factory):
    """
    IDOR 시도가 security_events 에 남아야 한다 —
    대시보드 "보안 이벤트" 화면이 이 근거로 채워진다.
    """
    _owner, _opw, owner_id = user_factory(prefix="owner")
    attacker, apw, _aid = user_factory(prefix="attacker")

    post_id = _new_post(owner_id)
    try:
        _login_via_form(client, attacker, apw)
        client.get(f"/board/{post_id}/edit")

        cnt = db.query_scalar(
            "SELECT COUNT(*) FROM security_events "
            "WHERE event_type='idor_attempt' AND path=%s",
            (f"/board/{post_id}/edit",),
        )
        assert int(cnt or 0) >= 1, "IDOR 시도가 보안 이벤트로 기록되지 않았다"
    finally:
        db.execute("DELETE FROM security_events WHERE path=%s",
                   (f"/board/{post_id}/edit",))
        _drop_post(post_id)


def test_idor_reproducible_in_vulnerable_mode(vuln_client, user_factory):
    """vulnerable 모드에서는 IDOR 이 성공해야 한다 (Before 증거)."""
    _owner, _opw, owner_id = user_factory(prefix="owner")
    attacker, apw, _aid = user_factory(prefix="attacker")

    post_id = _new_post(owner_id)
    try:
        _login_via_form(vuln_client, attacker, apw)
        res = vuln_client.get(f"/board/{post_id}/edit")
        assert res.status_code == 200, "vulnerable 모드인데 IDOR 이 막혔다"
    finally:
        _drop_post(post_id)


def test_owner_can_edit_own_post(client, user_factory):
    """차단 로직이 정상 사용자까지 막으면 안 된다 (오탐 방지)."""
    name, pw, uid = user_factory()
    post_id = _new_post(uid, "내 글")
    try:
        _login_via_form(client, name, pw)
        assert client.get(f"/board/{post_id}/edit").status_code == 200
    finally:
        _drop_post(post_id)


def test_admin_can_edit_any_post(client, user_factory):
    _owner, _opw, owner_id = user_factory(prefix="owner")
    adm, apw, _aid = user_factory(role="admin", prefix="adm")

    post_id = _new_post(owner_id)
    try:
        _login_via_form(client, adm, apw)
        assert client.get(f"/board/{post_id}/edit").status_code == 200
    finally:
        _drop_post(post_id)


# ==================================================================
# 8. XSS — 이중 모드 템플릿 분기
# ==================================================================

XSS_PAYLOAD = "<script>alert('xss-probe')</script>"


def test_stored_xss_escaped_in_secure_mode(client, user_factory):
    name, pw, uid = user_factory()
    post_id = db.insert(
        "INSERT INTO posts (user_id, title, content) VALUES (%s,%s,%s)",
        (uid, "XSS 테스트", XSS_PAYLOAD),
    )
    try:
        _login_via_form(client, name, pw)
        body = client.get(f"/board/{post_id}").data.decode("utf-8", "replace")
        assert XSS_PAYLOAD not in body, "저장형 XSS 가 이스케이프되지 않았다"
        assert "&lt;script&gt;" in body
    finally:
        _drop_post(post_id)


def test_stored_xss_reproducible_in_vulnerable_mode(vuln_client, user_factory):
    name, pw, uid = user_factory()
    post_id = db.insert(
        "INSERT INTO posts (user_id, title, content) VALUES (%s,%s,%s)",
        (uid, "XSS 테스트", XSS_PAYLOAD),
    )
    try:
        _login_via_form(vuln_client, name, pw)
        body = vuln_client.get(f"/board/{post_id}").data.decode("utf-8", "replace")
        assert XSS_PAYLOAD in body, "vulnerable 모드인데 XSS 가 재현되지 않았다"
    finally:
        _drop_post(post_id)


# ==================================================================
# 9. 접속 로깅 — 대시보드 데이터 원천
# ==================================================================

def _wait_for_log(path: str, timeout: float = 5.0) -> int:
    """
    로그 라이터는 백그라운드 스레드에서 배치 INSERT 하므로 폴링해서 기다린다.
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        cnt = db.query_scalar(
            "SELECT COUNT(*) FROM access_logs WHERE path=%s", (path,))
        if int(cnt or 0) > 0:
            return int(cnt)
        time.sleep(0.25)
    return 0


def test_access_log_is_persisted(client, unique):
    """
    요청이 access_logs 에 적재되어야 한다.
    이게 깨지면 관리자 대시보드가 빈 화면이 된다 (요구사항 3 붕괴).
    """
    probe = f"/board/?marker={unique}"
    client.get(probe)
    assert _wait_for_log("/board/") > 0, "접속 로그가 DB 에 적재되지 않았다"


def test_access_log_records_threat_score(client, unique):
    """공격 요청은 위협 점수와 태그를 함께 남겨야 한다."""
    marker = f"probe{unique}"
    client.get(f"/board/?q=' OR 1=1 -- &m={marker}")

    deadline = time.time() + 5.0
    row = None
    while time.time() < deadline:
        row = db.query_one(
            "SELECT threat_score, threat_tags FROM access_logs "
            "WHERE query_string LIKE %s ORDER BY id DESC LIMIT 1",
            (f"%{marker}%",),
        )
        if row:
            break
        time.sleep(0.25)

    assert row, "공격 요청 로그를 찾지 못했다"
    assert int(row["threat_score"]) > 0, "위협 점수가 0 이다"
    assert "sqli" in (row["threat_tags"] or ""), f"태그 누락: {row['threat_tags']}"


def test_sensitive_params_are_masked_in_logs(client, unique):
    """
    비밀번호/토큰이 로그에 평문으로 남으면 그 자체가 사고다.
    """
    marker = f"mask{unique}"
    client.get(f"/auth/login?password=SuperSecret123&m={marker}")

    deadline = time.time() + 5.0
    row = None
    while time.time() < deadline:
        row = db.query_one(
            "SELECT query_string FROM access_logs "
            "WHERE query_string LIKE %s ORDER BY id DESC LIMIT 1",
            (f"%{marker}%",),
        )
        if row:
            break
        time.sleep(0.25)

    assert row, "로그를 찾지 못했다"
    assert "SuperSecret123" not in row["query_string"], "비밀번호가 로그에 평문 저장됐다"


def test_admin_path_flag_is_set(client, user_factory):
    """관리 경로 접근은 별도로 표시되어야 한다 (감사 추적용)."""
    name, pw, _uid = user_factory(role="admin", prefix="adm")
    _login_via_form(client, name, pw)
    client.get("/admin/logs")

    deadline = time.time() + 5.0
    row = None
    while time.time() < deadline:
        row = db.query_one(
            "SELECT is_admin_path, username FROM access_logs "
            "WHERE path='/admin/logs' ORDER BY id DESC LIMIT 1")
        if row:
            break
        time.sleep(0.25)

    assert row, "관리 경로 로그를 찾지 못했다"
    assert int(row["is_admin_path"]) == 1


# ==================================================================
# 10. 파일 업로드 — 라우트 레벨
# ==================================================================

def test_webshell_upload_rejected_in_secure_mode(client, user_factory):
    """
    PHP 웹쉘 업로드가 라우트 레벨에서 거부되어야 한다.
    (단위 테스트는 test_security.py, 여기서는 실제 요청 경로 확인)
    """
    import io as _io

    name, pw, uid = user_factory()
    _login_via_form(client, name, pw)
    token = _csrf_after_login(client)

    res = client.post(
        "/board/new",
        data={
            "title": "웹쉘 업로드 시도",
            "content": "본문",
            "csrf_token": token,
            "attachment": (_io.BytesIO(b"<?php system($_GET['c']); ?>"), "shell.php"),
        },
        content_type="multipart/form-data",
    )
    assert res.status_code in (302, 303, 400)

    stored = db.query_all(
        "SELECT u.original_name FROM uploads u WHERE u.user_id=%s", (uid,))
    assert all(not r["original_name"].lower().endswith(".php") for r in stored), \
        "PHP 웹쉘이 업로드됐다"

    post_id = db.query_scalar(
        "SELECT id FROM posts WHERE user_id=%s ORDER BY id DESC LIMIT 1",
        (uid,), default=0)
    if post_id:
        db.execute("DELETE FROM uploads WHERE post_id=%s", (post_id,))
        _drop_post(post_id)


# ==================================================================
# 11. 모드 격리 — 운영 배포본 안전성
# ==================================================================

def test_secure_mode_does_not_advertise_vulnerable_banner(client):
    """
    운영(secure) 화면에 취약 모드 경고 배너가 뜨면 설정이 잘못 배포된 것이다.
    """
    body = client.get("/").data.decode("utf-8", "replace")
    assert "VULNERABLE" not in body.upper() or "vulnerable-banner" not in body


def test_app_config_mode_matches_fixture(app, vuln_app):
    assert app.config_obj.SECURITY_MODE == "secure"
    assert vuln_app.config_obj.SECURITY_MODE == "vulnerable"
